/**
 * /api/kakao — 카카오 알림톡 발송 (Vercel Serverless Function, Node 18+)
 *
 * 호출 경로 1) Supabase Database Webhook (notifications INSERT) → POST 이 함수
 * 호출 경로 2) 수동 재발송: GET /api/kakao?flush=1  (pending·failed 건 일괄 처리)
 *
 * 환경변수 (Vercel > Settings > Environment Variables)
 *   SOLAPI_API_KEY, SOLAPI_API_SECRET   Solapi 콘솔
 *   SOLAPI_PFID                          카카오 채널 pfId
 *   SOLAPI_SENDER                        발신번호 (등록된 번호, 예 01090628804)
 *   TEMPLATE_APPLIED                     신청 접수 안내 템플릿 ID (신청자 전원)
 *   TEMPLATE_PAID                        입금 확인 안내 템플릿 ID (담당자·신청자)
 *   SUPABASE_URL, SUPABASE_SERVICE_KEY   service_role 키 (서버 전용)
 *   WEBHOOK_SECRET                       Webhook 헤더 x-webhook-secret 과 동일한 값
 */
import { SolapiMessageService } from 'solapi';

const env = (k, required = true) => {
  const v = process.env[k];
  if (required && !v) throw new Error(`환경변수 누락: ${k}`);
  return v;
};

const TEMPLATES = () => ({
  applied: env('TEMPLATE_APPLIED'),
  paid:    env('TEMPLATE_PAID'),
});

// ── Supabase (service_role) ──
async function sb(path, init = {}) {
  const r = await fetch(env('SUPABASE_URL') + path, {
    ...init,
    headers: {
      apikey: env('SUPABASE_SERVICE_KEY'),
      Authorization: 'Bearer ' + env('SUPABASE_SERVICE_KEY'),
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}
const markNotification = (id, status, providerId, error) =>
  sb('/rest/v1/rpc/mark_notification', {
    method: 'POST',
    body: JSON.stringify({ p_id: id, p_status: status, p_provider_id: providerId || null, p_error: error || null }),
  });

// ── Solapi ──
let _svc;
const solapi = () => (_svc ||= new SolapiMessageService(env('SOLAPI_API_KEY'), env('SOLAPI_API_SECRET')));

const normPhone = p => String(p || '').replace(/\D/g, '');

async function sendOne(n) {
  const templateId = TEMPLATES()[n.kind];
  if (!templateId) {
    await markNotification(n.id, 'failed', null, `템플릿 미설정: ${n.kind}`);
    return { id: n.id, skipped: true };
  }
  const to = normPhone(n.to_phone);
  if (to.length < 10) {
    await markNotification(n.id, 'failed', null, `전화번호 형식 오류: ${n.to_phone}`);
    return { id: n.id, failed: true };
  }
  try {
    const res = await solapi().send({
      to,
      from: env('SOLAPI_SENDER'),
      kakaoOptions: {
        pfId: env('SOLAPI_PFID'),
        templateId,
        variables: n.variables || {},
        disableSms: false,        // 알림톡 실패 시 SMS 대체 발송 (원치 않으면 true)
      },
    });
    const providerId = res?.groupInfo?.groupId || res?.groupId || null;
    await markNotification(n.id, 'sent', providerId, null);
    return { id: n.id, sent: true };
  } catch (e) {
    const msg = e?.message || String(e);
    await markNotification(n.id, 'failed', null, msg.slice(0, 500));
    return { id: n.id, failed: true, error: msg };
  }
}

export default async function handler(req, res) {
  try {
    // 인증: Webhook 헤더 또는 ?secret=
    const secret = req.headers['x-webhook-secret'] || req.query?.secret;
    if (secret !== env('WEBHOOK_SECRET')) return res.status(401).json({ error: 'unauthorized' });

    // 경로 2: 미발송 건 일괄 처리
    if (req.method === 'GET' && req.query?.flush) {
      const pending = await sb('/rest/v1/notifications?status=in.(pending,failed)&attempts=lt.3&order=id.asc&limit=100');
      const results = [];
      for (const n of pending) results.push(await sendOne(n));
      return res.status(200).json({ processed: results.length, results });
    }

    // 경로 1: Supabase Database Webhook
    if (req.method === 'POST') {
      const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
      const rec = body?.record;
      if (!rec || body?.type !== 'INSERT' || body?.table !== 'notifications') {
        return res.status(200).json({ ignored: true });
      }
      if (rec.status !== 'pending') return res.status(200).json({ ignored: 'not pending' });
      const r = await sendOne(rec);
      return res.status(200).json(r);
    }

    return res.status(405).json({ error: 'method not allowed' });
  } catch (e) {
    console.error(e);
    return res.status(500).json({ error: e.message });
  }
}
