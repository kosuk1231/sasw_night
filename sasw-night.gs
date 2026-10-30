/**
 * 2026 서울사회복지사의 밤 — 운영 자동화 (Google Apps Script)
 *
 *  1) 시트 자동동기화  : Supabase → 구글시트 (5분마다)
 *  2) 입금내역 자동매칭 : 「입금내역」 시트 → Supabase → 신청 건과 연결
 *  3) 입금 영수증 발송  : 매칭된 건에 PDF 영수증 메일 (중복 발송 방지)
 *
 *  설치
 *   - 스프레드시트 > 확장 프로그램 > Apps Script 에 붙여넣기
 *   - 스크립트 속성에 SUPABASE_URL / SUPABASE_SERVICE_KEY / RECEIPT_TEMPLATE_ID 저장
 *   - setupTriggers() 1회 실행
 */

// ───────────────────────────── 설정 ─────────────────────────────
const PROP = PropertiesService.getScriptProperties();
const SB_URL = () => PROP.getProperty('SUPABASE_URL');          // https://xxxx.supabase.co
const SB_KEY = () => PROP.getProperty('SUPABASE_SERVICE_KEY');  // service_role 키 (절대 웹에 넣지 말 것)
const TEMPLATE_ID = () => PROP.getProperty('RECEIPT_TEMPLATE_ID');

const SHEET_APPS      = '신청현황';
const SHEET_ATTENDEES = '참가자명단';
const SHEET_BANK      = '입금내역';
const SHEET_LOG       = '발송기록';

// ───────────────────────── Supabase 통신 ─────────────────────────
function sbFetch_(path, options) {
  const res = UrlFetchApp.fetch(SB_URL() + path, Object.assign({
    muteHttpExceptions: true,
    headers: {
      'apikey': SB_KEY(),
      'Authorization': 'Bearer ' + SB_KEY(),
      'Content-Type': 'application/json'
    }
  }, options || {}));
  const code = res.getResponseCode();
  const text = res.getContentText();
  if (code >= 300) throw new Error('Supabase ' + code + ' : ' + text);
  return text ? JSON.parse(text) : null;
}
const sbSelect_ = (view, query) => sbFetch_('/rest/v1/' + view + (query ? '?' + query : '?select=*'));
const sbRpc_    = (fn, body)    => sbFetch_('/rest/v1/rpc/' + fn, { method:'post', payload: JSON.stringify(body || {}) });

// ─────────────────────── 1. 시트 자동동기화 ───────────────────────
function syncToSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();

  const apps = sbSelect_('v_applications', 'select=*&order=created_at.asc');
  writeSheet_(ss, SHEET_APPS,
    ['신청시각','구분','기관·단체명','담당자','연락처','이메일','입금자명','인원','청구액','입금액','입금상태','입금시각','영수증발송','비고','ID'],
    apps.map(a => [
      toKst_(a.created_at), a.kind_label, a.org_name || '', a.contact_name, a.contact_phone,
      a.contact_email, a.payer_name, a.headcount, a.amount_due, a.paid_amount,
      a.pay_status, toKst_(a.paid_at), toKst_(a.receipt_sent_at), a.memo || '', a.id
    ]));

  const people = sbSelect_('v_attendees', 'select=*&order=created_at.asc');
  writeSheet_(ss, SHEET_ATTENDEES,
    ['번호','구분','기관·단체명','성함','직급','연락처','생년월일','입금상태','등록시각'],
    people.map((p, i) => [
      i + 1, p.kind_label, p.org_name || '', p.name, p.position || '',
      p.phone, p.birth6 || '', p.pay_status, toKst_(p.created_at)
    ]));

  const st = sbRpc_('public_status');
  ss.toast('신청 ' + apps.length + '건 · 참가자 ' + people.length + '명 · 잔여 ' + st.remaining + '석', '동기화 완료', 5);
}

function writeSheet_(ss, name, header, rows) {
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  sh.clearContents();
  sh.getRange(1, 1, 1, header.length).setValues([header])
    .setFontWeight('bold').setBackground('#10332f').setFontColor('#f0dbab');
  if (rows.length) sh.getRange(2, 1, rows.length, header.length).setValues(rows);
  sh.setFrozenRows(1);
  sh.autoResizeColumns(1, header.length);
}

const toKst_ = iso => iso
  ? Utilities.formatDate(new Date(iso), 'Asia/Seoul', 'yyyy-MM-dd HH:mm')
  : '';

// ────────────────── 2. 입금내역 업로드 + 자동매칭 ──────────────────
/**
 * 「입금내역」 시트에 은행에서 받은 거래내역을 붙여넣고 실행합니다.
 *   A열 거래일시 | B열 입금자명 | C열 입금액   (1행은 헤더)
 * 은행 양식이 달라도 이 세 칸만 맞춰 두면 됩니다.
 */
function importBankStatement() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sh = ss.getSheetByName(SHEET_BANK);
  if (!sh) { ss.insertSheet(SHEET_BANK).getRange(1,1,1,3)
    .setValues([['거래일시','입금자명','입금액']]); 
    SpreadsheetApp.getUi().alert('「입금내역」 시트를 만들었습니다. 거래내역을 붙여넣고 다시 실행해 주세요.'); return; }

  const last = sh.getLastRow();
  if (last < 2) { SpreadsheetApp.getUi().alert('입금내역이 비어 있습니다.'); return; }

  const values = sh.getRange(2, 1, last - 1, 3).getValues();
  const rows = values
    .filter(r => r[1] && r[2])
    .map(r => ({
      paid_at:    r[0] instanceof Date ? r[0].toISOString() : String(r[0] || ''),
      payer_name: String(r[1]).trim(),
      amount:     Number(String(r[2]).replace(/[^0-9]/g, '')),
      raw:        r.join('|')
    }))
    .filter(r => r.amount > 0);

  if (!rows.length) { SpreadsheetApp.getUi().alert('읽을 수 있는 입금 건이 없습니다.'); return; }

  const r = sbRpc_('import_payments', { p_rows: rows });
  syncToSheet();
  SpreadsheetApp.getUi().alert(
    '입금내역 처리 완료\n\n' +
    '신규 등록 : ' + r.inserted + '건\n' +
    '중복 제외 : ' + r.skipped  + '건\n' +
    '자동 매칭 : ' + r.matched  + '건\n\n' +
    '매칭되지 않은 건은 「신청현황」에서 미입금으로 남습니다.\n' +
    '입금자명이나 금액이 다른 경우이니 확인 후 수기 매칭해 주세요.');
}

/** 자동으로 못 잡은 건을 수기로 연결 (입금 payments.id ↔ 신청 applications.id) */
function matchManually(paymentId, applicationId) {
  sbRpc_('match_payment_manual', { p_payment_id: paymentId, p_application_id: applicationId });
  syncToSheet();
}

// ─────────────────── 3. 입금 영수증 PDF 메일 발송 ───────────────────
function sendReceipts() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const pending = sbSelect_('v_pending_receipts', 'select=*&order=paid_at.asc');
  if (!pending.length) { ss.toast('보낼 영수증이 없습니다.', '', 4); return; }

  let log = ss.getSheetByName(SHEET_LOG);
  if (!log) { log = ss.insertSheet(SHEET_LOG); log.appendRow(['발송시각','수신','대상','금액','신청ID']); }

  const today = new Date();
  const dateStr = Utilities.formatDate(today, 'Asia/Seoul', 'yyyy. M. d.');
  const folder = getOutFolder_();
  let sent = 0;

  pending.forEach(a => {
    const title = a.kind === 'group' ? a.org_name : a.contact_name;
    try {
      // 템플릿 복사 → 치환 → PDF
      const copyId = DriveApp.getFileById(TEMPLATE_ID())
        .makeCopy(title + ' 영수증', folder).getId();
      const doc = DocumentApp.openById(copyId);
      const body = doc.getBody();
      body.replaceText('{기관명}',   title);
      body.replaceText('{금액}',     '₩' + Number(a.paid_amount).toLocaleString('ko-KR') + '원');
      body.replaceText('{한글변환}', toKoreanAmount_(a.paid_amount));
      body.replaceText('{인원}',     a.headcount + '명');
      body.replaceText('{발행일}',   dateStr);
      doc.saveAndClose();

      const pdf = DriveApp.getFileById(copyId).getAs(MimeType.PDF)
        .copyBlob().setName(title + ' 영수증.pdf');

      GmailApp.sendEmail(a.contact_email, '[2026 서울사회복지사의 밤] 참가비 입금 영수증', '', {
        name: '서울특별시사회복지사협회',
        htmlBody: receiptHtml_(title, a.headcount, a.paid_amount),
        attachments: [pdf]
      });

      sbRpc_('mark_receipt_sent', { p_application_id: a.id });
      log.appendRow([new Date(), a.contact_email, title, a.paid_amount, a.id]);
      DriveApp.getFileById(copyId).setTrashed(true);   // 중간 문서 정리
      sent++;
    } catch (e) {
      Logger.log('영수증 실패 [' + title + '] ' + e.message);
    }
  });

  ss.toast(sent + '건 발송했습니다.', '영수증', 5);
}

function receiptHtml_(title, headcount, amount) {
  return '' +
  '<div style="font-family:Apple SD Gothic Neo,Malgun Gothic,sans-serif;font-size:14px;line-height:1.75;color:#333">' +
  '<p><b>' + title + '</b> 귀하</p>' +
  '<p>「2026 서울사회복지사의 밤」 참가 신청과 입금을 확인했습니다.<br>' +
  '참가 인원 <b>' + headcount + '명</b>, 입금액 <b>₩' + Number(amount).toLocaleString('ko-KR') + '원</b>에 대한 영수증을 첨부합니다.</p>' +
  '<p style="margin:18px 0;padding:14px 16px;background:#f3f6f2;border-left:3px solid #2f8a66">' +
  '<b>일시</b> 2026. 12. 4.(금) 17:00<br>' +
  '<b>장소</b> 그랜드컨벤션센터</p>' +
  '<p>한 해 동안 수고하신 사회복지사 여러분과 함께하는 자리로 정성껏 준비하겠습니다.<br>' +
  '행사 당일 자세한 안내는 별도로 보내드립니다.</p>' +
  '<p style="color:#777;font-size:13px">서울특별시사회복지사협회 회원조직팀 · 02-786-2962</p>' +
  '</div>';
}

function getOutFolder_() {
  const name = '서울사회복지사의밤_영수증';
  const it = DriveApp.getFoldersByName(name);
  return it.hasNext() ? it.next() : DriveApp.createFolder(name);
}

/** 숫자 → 금○○○원정 (회비 영수증 스크립트와 동일 로직) */
function toKoreanAmount_(number) {
  const units = ['', '만', '억', '조'];
  const digits = ['', '일', '이', '삼', '사', '오', '육', '칠', '팔', '구'];
  const small = ['', '십', '백', '천'];
  const s = String(number).replace(/[^\d]/g, '');
  let result = '';
  for (let i = 0; i < s.length; i++) {
    const d = parseInt(s.charAt(i), 10);
    const ui = Math.floor((s.length - i - 1) / 4);
    const si = (s.length - i - 1) % 4;
    if (d !== 0) result += digits[d] + small[si];
    if (si === 0 && result !== '') result += units[ui];
  }
  return result ? '금' + result + '원정' : '영';
}

// ───────────────────────── 메뉴 / 트리거 ─────────────────────────
function onOpen() {
  SpreadsheetApp.getUi().createMenu('사회복지사의 밤')
    .addItem('① 신청현황 동기화', 'syncToSheet')
    .addItem('② 입금내역 매칭',   'importBankStatement')
    .addItem('③ 영수증 발송',     'sendReceipts')
    .addToUi();
}

function setupTriggers() {
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('syncToSheet').timeBased().everyMinutes(5).create();
  ScriptApp.newTrigger('onOpen').forSpreadsheet(SpreadsheetApp.getActive()).onOpen().create();
  Logger.log('트리거 설정 완료 — 5분마다 동기화');
}
