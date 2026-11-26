/**
 * 2026 서울사회복지사의 밤 — 운영 자동화 (Google Apps Script)
 *
 *  1) 시트 자동동기화  : Supabase → 구글시트 (5분마다)
 *  2) 입금내역 자동매칭 : 「입금내역」 시트 → Supabase → 신청 건과 연결
 *  3) 입금 영수증 발송  : 매칭된 건에 PDF 영수증 메일 (중복 발송 방지)
 *  4) 수기 입금확인     : 자동 매칭이 못 잡은 입금을 사람이 신청 건에 연결 (「수기입금처리」 시트)
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

const SHEET_IND       = '개인신청';
const SHEET_GRP       = '단체신청';
const SHEET_ORG       = '기관별집계';
const SHEET_ATTENDEES = '참가자명단';
const SHEET_OLD_APPS  = '신청현황';   // 예전 버전 시트 (자동 정리)
const SHEET_BANK      = '입금내역';
const SHEET_LOG       = '발송기록';
const SHEET_MANUAL    = '수기입금처리';
const SHEET_MANUAL_LOG = '수기입금기록';
const SHEET_SURVEY    = '사전설문';
const SHEET_SONGS     = '신청곡';
const SHEET_CHEER     = '축하메시지';
// 은행 내역에서 '접수 시작 전 입금'을 거르는 기준일 = 1차 사전신청 오픈일.
// (추가 접수를 켜면 서버의 접수 시작일이 추가 접수일로 바뀌므로, 1차 입금이 걸러지지 않게 고정해 둔다)
const FIRST_OPEN_DAY  = '2026-11-10';

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
  const apps   = sbSelect_('v_applications', 'select=*&order=created_at.asc');
  const people = sbSelect_('v_attendees',    'select=*&order=created_at.asc');
  const st     = sbRpc_('public_status');

  const S = buildSheets_(apps, people, st.group_max || 10);
  writeSheet_(ss, SHEET_IND,       S.ind,  0);
  writeSheet_(ss, SHEET_GRP,       S.grp,  1);
  writeSheet_(ss, SHEET_ORG,       S.org,  2);
  writeSheet_(ss, SHEET_ATTENDEES, S.all,  3);

  // 예전 「신청현황」 시트는 내용이 더 이상 갱신되지 않으므로 정리 (자동 생성 시트일 때만)
  const old = ss.getSheetByName(SHEET_OLD_APPS);
  if (old && old.getRange('A1').getValue() === '신청시각' && old.getRange('B1').getValue() === '구분') ss.deleteSheet(old);

  // 사전 설문 (사전설문_패치.sql 적용 전이면 조용히 건너뜀)
  let sv = '';
  try { const r = syncSurvey_(ss); sv = ' · 설문 ' + r.total + '명(수어 ' + r.sign + ')'; }
  catch (e) { Logger.log('사전설문 동기화 건너뜀: ' + e.message); }

  ss.toast('개인 ' + S.ind.rows.length + '명 · 단체 ' + S.grpCount + '곳 ' + S.grp.rows.length + '명 · 잔여 ' + st.remaining + '석' + sv,
           '동기화 완료', 5);
}

// ────────────────── 1-1. 사전 설문 → 「사전설문」·「신청곡」 시트 ──────────────────
function syncSurvey() {   // 메뉴 ⑥
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const r = syncSurvey_(ss);
  ss.toast('응답 ' + r.total + '명 · 수어통역 필요 ' + r.sign + '명 · 신청곡 ' + r.songs + '곡 · 축하 한마디 ' + r.cheers + '건', '사전 설문', 6);
}

function syncSurvey_(ss) {
  const list = sbSelect_('v_surveys', 'select=*&order=updated_at.asc');

  // 「사전설문」 : 수어통역 필요자를 맨 위로, 그다음 응답 순
  //   명단확인 = 입금 확인된 참석자 중 같은 성함 수 (O / 동명이인 n명 / 명단에 없음 → 확인 필요)
  const signFirst = list.slice().sort((a, b) => (a.sign_need === '필요' ? 0 : 1) - (b.sign_need === '필요' ? 0 : 1));
  const T = {
    header: ['응답시각', '성함', '소속', '명단확인', '수어 연락처', '수어통역', '수어 요청사항', '현장 소개',
             '한 단어', '다시 태어나도', '이유', '힘들었던 순간', '보람 있던 순간',
             '위로가 된 노래', '동료에게 들려주고 싶은 노래', '출퇴근길 노래', '노래 사연', '수상자께 한마디'],
    rows: signFirst.map(v => [toKst_(v.updated_at), v.name, v.org_name || '', v.roster, v.sign_phone || '',
             v.sign_need, v.sign_note || '', v.share_ok,
             v.one_word, v.again_sw, v.again_reason || '', v.hard_moment || '', v.proud_moment || '',
             v.song_comfort || '', v.song_colleague || '', v.song_commute || '', v.song_story || '', v.cheer_msg || '']),
    text: [5],
  };
  writeSheet_(ss, SHEET_SURVEY, T, 4);
  const sh = ss.getSheetByName(SHEET_SURVEY);
  if (T.rows.length) {
    const bg = signFirst.map(v => new Array(T.header.length).fill(v.sign_need === '필요' ? '#e3f4ea' : '#ffffff'));
    sh.getRange(2, 1, T.rows.length, T.header.length).setBackgrounds(bg);
    [12, 13, 17, 18].forEach(c => sh.setColumnWidth(c, 320));
    sh.getRange(2, 1, T.rows.length, T.header.length).setWrap(true).setVerticalAlignment('top');
  }

  // 「신청곡」 : 곡 1개 = 1행. 소개 방법에 맞춰 신청자 표시
  const who = v => v.share_ok === '이름·소속 공개' ? v.name + (v.org_name ? ' (' + v.org_name + ')' : '')
                 : v.share_ok === '익명으로만'    ? '익명'
                 : '비공개 (BGM만 · 사연 소개 안 함)';
  const songs = [];
  list.forEach(v => {
    [['올해 위로가 된 노래', v.song_comfort], ['동료에게 들려주고 싶은 노래', v.song_colleague], ['출퇴근길 노래', v.song_commute]]
      .forEach(([k, song]) => { if (song) songs.push([k, song, who(v), v.share_ok === '소개하지 않음' ? '' : (v.song_story || '')]); });
  });
  songs.sort((a, b) => a[0].localeCompare(b[0], 'ko') || a[1].localeCompare(b[1], 'ko'));
  writeSheet_(ss, SHEET_SONGS, { header: ['구분', '곡 (가수 - 곡명)', '신청자 (소개 방법 반영)', '사연'], rows: songs }, 5);
  if (songs.length) ss.getSheetByName(SHEET_SONGS).setColumnWidth(4, 420);

  // 「축하메시지」 : 아름다운사회복지사상 수상자(이정미 사회복지사, 한국여성의집)께 한마디
  //   영상·축하 이미지에는 '영상 사용' 이 O 인 줄만 쓰고, 표시 이름 칸을 그대로 사용
  const cheers = list.filter(v => v.cheer_msg).map(v => [
    toKst_(v.updated_at), v.cheer_msg,
    v.share_ok === '이름·소속 공개' ? v.name + (v.org_name ? ' (' + v.org_name + ')' : '') : v.share_ok === '익명으로만' ? '익명' : '-',
    v.share_ok === '소개하지 않음' ? 'X (수상자께만 전달)' : 'O']);
  writeSheet_(ss, SHEET_CHEER, { header: ['응답시각', '한마디', '표시 이름', '영상 사용'], rows: cheers }, 6);
  if (cheers.length) { const c = ss.getSheetByName(SHEET_CHEER); c.setColumnWidth(2, 480); c.getRange(2, 2, cheers.length, 1).setWrap(true); }

  return { total: list.length, sign: list.filter(v => v.sign_need === '필요').length, songs: songs.length, cheers: cheers.length };
}

/**
 * 순수 변환 함수 — 시트에 쓸 표 4개를 만든다 (테스트하기 쉽도록 시트 API를 쓰지 않음)
 * 각 표: { header, rows, text:[텍스트 열 번호], money:[금액 열 번호], band:[기관 구분용 그룹 키] }
 */
function buildSheets_(apps, people, groupMax) {
  const byApp = {};
  apps.forEach(a => byApp[a.id] = a);
  const won = n => Number(n || 0);

  // ① 개인신청 — 한 사람 = 한 줄
  const indApps = apps.filter(a => a.kind === 'individual');
  const indPeople = {};
  people.forEach(p => { if (byApp[p.application_id] && byApp[p.application_id].kind === 'individual') indPeople[p.application_id] = p; });
  const ind = {
    header: ['신청시각','성함','생년월일','평생회원','연락처','이메일','소속','입금자명','청구액','입금액','입금상태','입금시각','영수증발송','비고','신청ID'],
    text: [3, 5], money: [9, 10],
    rows: indApps.map(a => {
      const p = indPeople[a.id] || {};
      return [toKst_(a.created_at), a.contact_name, p.birth6 || '', p.lifetime ? 'O' : '', a.contact_phone, a.contact_email,
              a.org_name || '', a.payer_name, won(a.amount_due), won(a.paid_amount), a.pay_status,
              toKst_(a.paid_at), toKst_(a.receipt_sent_at), a.memo || '', a.id];
    })
  };

  // ② 단체신청 — 참가자 한 명 = 한 줄, 기관끼리 묶어서. 금액은 기관 첫 줄에만 (합계가 부풀지 않도록)
  const grpApps = apps.filter(a => a.kind === 'group');
  const grpRows = [], grpBand = [];
  grpApps.forEach(a => {
    const members = people.filter(p => p.application_id === a.id).sort((x, y) => x.seq - y.seq);
    members.forEach((p, i) => {
      const first = i === 0;
      grpRows.push([
        a.org_name, i + 1, p.name, p.position || '', p.phone, p.birth6 || '', p.lifetime ? 'O' : '',
        first ? a.contact_name : '', first ? a.contact_phone : '', first ? a.contact_email : '',
        first ? a.payer_name : '', first ? won(a.headcount) : '',
        first ? won(a.amount_due) : '', first ? won(a.paid_amount) : '',
        p.pay_status, first ? toKst_(a.receipt_sent_at) : '', first ? toKst_(a.created_at) : '',
        first ? (a.memo || '') : '', a.id
      ]);
      grpBand.push(a.id);
    });
  });
  const grp = {
    header: ['기관명','번호','성함','직급','연락처','생년월일','평생회원','담당자','담당자 연락처','담당자 이메일','입금자명',
             '기관 인원','청구액','입금액','입금상태','영수증발송','신청시각','비고','신청ID'],
    text: [5, 6, 9], money: [13, 14], band: grpBand, rows: grpRows
  };

  // ③ 기관별집계 — 같은 기관(org_key)의 단체 + 개인 소속 합산, 10명 한도 대비
  const orgs = {};
  apps.forEach(a => {
    if (!a.org_key) return;
    const o = orgs[a.org_key] || (orgs[a.org_key] = { name: '', grp: 0, ind: 0, status: '', contact: '', phone: '' });
    if (a.kind === 'group') {
      o.name = a.org_name; o.grp += won(a.headcount); o.status = a.pay_status;
      o.contact = a.contact_name; o.phone = a.contact_phone;
    } else {
      o.ind += won(a.headcount);
      if (!o.name) o.name = a.org_name;
    }
  });
  const orgRows = Object.values(orgs)
    .map(o => [o.name, o.grp, o.ind, o.grp + o.ind, Math.max(groupMax - o.grp - o.ind, 0),
               o.grp ? o.status : '-', o.contact, o.phone])
    .sort((x, y) => y[3] - x[3] || String(x[0]).localeCompare(String(y[0]), 'ko'));
  const org = {
    header: ['기관명','단체 신청','개인 신청(소속)','합계','추가 가능','단체 입금상태','단체 담당자','담당자 연락처'],
    text: [8], money: [], rows: orgRows, full: orgRows.map(r => r[4] === 0)
  };

  // ④ 참가자명단(전체) — 현장 접수용
  const all = {
    header: ['번호','구분','기관·소속','성함','직급','연락처','생년월일','평생회원','입금상태','등록시각'],
    text: [6, 7], money: [],
    rows: people.map((p, i) => [i + 1, p.kind_label, p.org_name || '', p.name, p.position || '',
                                p.phone, p.birth6 || '', p.lifetime ? 'O' : '', p.pay_status, toKst_(p.created_at)])
  };

  return { ind, grp, org, all, grpCount: grpApps.length };
}

function writeSheet_(ss, name, T, index) {
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name, index);
  sh.clear();
  const W = T.header.length, H = T.rows.length;
  sh.getRange(1, 1, 1, W).setValues([T.header])
    .setFontWeight('bold').setBackground('#10332f').setFontColor('#f0dbab');
  if (H) {
    // 연락처·생년월일은 텍스트로 (050315 → 50315, 01012345678 → 1012345678 로 앞자리 0이 사라지는 것 방지)
    (T.text || []).forEach(c => sh.getRange(2, c, H, 1).setNumberFormat('@'));
    sh.getRange(2, 1, H, W).setValues(T.rows);
    (T.money || []).forEach(c => sh.getRange(2, c, H, 1).setNumberFormat('#,##0'));

    // 단체신청: 기관이 바뀔 때마다 배경색을 번갈아 → 어디까지가 한 기관인지 한눈에
    if (T.band) {
      const bg = []; let k = null, on = false;
      T.band.forEach(id => { if (id !== k) { on = !on; k = id; } bg.push(new Array(W).fill(on ? '#ffffff' : '#eef4f0')); });
      sh.getRange(2, 1, H, W).setBackgrounds(bg);
    }
    // 기관별집계: 10명 다 찬 기관은 붉게
    if (T.full) {
      const bg = T.full.map(f => new Array(W).fill(f ? '#fbe3df' : '#ffffff'));
      sh.getRange(2, 1, H, W).setBackgrounds(bg);
    }
  }
  sh.setFrozenRows(1);
  sh.autoResizeColumns(1, W);
}

const toKst_ = iso => iso
  ? Utilities.formatDate(new Date(iso), 'Asia/Seoul', 'yyyy-MM-dd HH:mm')
  : '';

// ────────────────── 2. 입금내역 업로드 + 자동매칭 ──────────────────
/**
 * 「입금내역」 시트에 은행에서 내려받은 거래내역을 **머리글 포함 그대로** A1에 붙여넣고 실행합니다.
 *   신한은행 양식 : 일자 | 시간 | 적요 | 출금(원) | 입금(원) | 내용 | 잔액(원) | 거래점 | CMS코드
 *   간단 양식     : 거래일시 | 입금자명 | 입금액
 * 열 순서가 달라도 머리글 이름으로 찾습니다.
 *
 * 같은 통장에 회비 등 다른 입금이 섞여 있으므로, 행사와 무관한 거래는 Supabase로 보내지 않습니다.
 *   ① 출금 / 0원           ② 접수 시작일 이전 거래   ③ 참가비(1인 금액)의 배수가 아닌 금액
 */
function importBankStatement() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const ui = SpreadsheetApp.getUi();
  let sh = ss.getSheetByName(SHEET_BANK);
  if (!sh) {
    sh = ss.insertSheet(SHEET_BANK);
    sh.getRange(1, 1, 1, 9).setValues([['일자','시간','적요','출금(원)','입금(원)','내용','잔액(원)','거래점','CMS코드']])
      .setFontWeight('bold');
    ui.alert('「입금내역」 시트를 만들었습니다.\n은행에서 내려받은 거래내역을 머리글까지 그대로 A1에 붙여넣고 다시 실행해 주세요.');
    return;
  }

  // 날짜·시간은 화면에 보이는 그대로 읽는다 (시간 칸의 1899년 날짜 변환 오차 방지)
  const grid = sh.getDataRange().getDisplayValues();
  const st = sbRpc_('public_status');
  const openDay = FIRST_OPEN_DAY;
  const parsed = parseBankRows_(grid, { fee: Number(st.fee) || 0, openDay });

  if (parsed.error) { ui.alert(parsed.error); return; }
  if (!parsed.rows.length) {
    ui.alert('행사 참가비로 보이는 입금이 없습니다.\n\n' + parsed.summary);
    return;
  }

  const r = sbRpc_('import_payments', { p_rows: parsed.rows });
  syncToSheet();
  ui.alert(
    '입금내역 처리 완료\n\n' +
    parsed.summary + '\n\n' +
    '── 참가비 후보 ' + parsed.rows.length + '건 처리 결과 ──\n' +
    '신규 등록 : ' + r.inserted + '건\n' +
    '중복 제외 : ' + r.skipped  + '건 (이미 올린 거래)\n' +
    '자동 매칭 : ' + r.matched  + '건\n' +
    (r.ambiguous ? '매칭 보류 : ' + r.ambiguous + '건 (같은 이름·금액의 신청이 여러 건)\n' : '') +
    '\n매칭되지 않은 건은 「개인신청」·「단체신청」에서 미입금으로 남습니다.\n' +
    '입금자명·금액이 다르거나 보류된 건이니 확인 후 수기 매칭해 주세요.');
}

/**
 * 순수 함수 — 시트 값(2차원 문자열 배열)을 Supabase로 보낼 입금 목록으로 바꾼다.
 */
function parseBankRows_(grid, opt) {
  const clean = v => String(v == null ? '' : v).replace(/\s+/g, '');
  // 머리글 찾기 (앞 10줄 안에서)
  let h = -1, col = {};
  for (let i = 0; i < Math.min(grid.length, 10); i++) {
    const row = grid[i].map(clean);
    const find = re => row.findIndex(c => re.test(c));
    const amt  = find(/^(입금(\(원\))?|입금액|입금금액|맡기신금액)$/);
    const name = [/^내용$/, /^입금자명?$/, /^기재내용$/, /^보낸분$/, /^의뢰인$/].map(find).find(x => x >= 0);
    if (amt >= 0 && name !== undefined) {
      h = i;
      col = { amt, name,
              date: find(/^(일자|거래일자?|거래일시|날짜)$/),
              time: find(/^(시간|거래시간)$/),
              out:  find(/^(출금(\(원\))?|출금액|찾으신금액)$/) };
      break;
    }
  }
  if (h < 0) return { error: '머리글을 찾지 못했습니다.\n\n은행 거래내역을 「일자 · 입금(원) · 내용」 머리글이 포함된 채로 A1에 붙여넣어 주세요.' };

  const num = v => Number(String(v || '').replace(/[^0-9]/g, '')) || 0;
  const toIso = (d, t) => {
    d = String(d || '').trim().replace(/[./]/g, '-').replace(/\s+/g, ' ');
    let m = d.match(/^(\d{4})-(\d{1,2})-(\d{1,2})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?/);
    if (!m) return { iso: '', day: '' };
    let [, Y, M, D, hh, mm, ss] = m;
    if (!hh && t) { const tm = String(t).trim().match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?/); if (tm) [, hh, mm, ss] = tm; }
    const p2 = x => String(x || 0).padStart(2, '0');
    const day = `${Y}-${p2(M)}-${p2(D)}`;
    return { iso: `${day}T${p2(hh)}:${p2(mm)}:${p2(ss)}+09:00`, day };
  };

  let total = 0, outOrZero = 0, beforeOpen = 0, notFee = 0;
  const rows = [], notFeeList = [];
  for (let i = h + 1; i < grid.length; i++) {
    const r = grid[i];
    if (!r || r.every(c => String(c).trim() === '')) continue;
    total++;
    const amount = num(r[col.amt]);
    if (!amount) { outOrZero++; continue; }   // 출금 거래는 입금 칸이 비어 있음
    const when = toIso(col.date >= 0 ? r[col.date] : '', col.time >= 0 ? r[col.time] : '');
    if (opt.openDay && when.day && when.day < opt.openDay) { beforeOpen++; continue; }
    if (opt.fee && amount % opt.fee !== 0) {
      notFee++; notFeeList.push(`${when.day} ${String(r[col.name] || '').trim()} ${amount.toLocaleString('ko-KR')}원`);
      continue;
    }
    const payer = String(r[col.name] || '').trim();
    if (!payer) { outOrZero++; continue; }
    rows.push({ paid_at: when.iso, payer_name: payer, amount, raw: r.map(c => String(c).trim()).join('|') });
  }

  const summary =
    '전체 ' + total + '건 중\n' +
    '· 출금·0원 제외 : ' + outOrZero + '건\n' +
    '· 접수 시작(' + opt.openDay + ') 이전 제외 : ' + beforeOpen + '건\n' +
    '· 참가비(' + Number(opt.fee).toLocaleString('ko-KR') + '원) 배수 아님 제외 : ' + notFee + '건';
  // 접수 시작 이후인데 금액이 참가비 단위가 아닌 입금 = 회비일 수도, 잘못 보낸 참가비일 수도 → 눈으로 확인
  const check = notFeeList.length
    ? '\n\n※ 접수 시작 이후 입금 중 참가비 단위가 아니어서 제외한 건 (금액을 잘못 보낸 참가비인지 확인):\n' +
      notFeeList.slice(0, 15).map(x => '  - ' + x).join('\n') +
      (notFeeList.length > 15 ? '\n  … 외 ' + (notFeeList.length - 15) + '건' : '')
    : '';
  return { rows, summary: summary + check };
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
  '<b>장소</b> 당산 그랜드컨벤션센터 (서울 영등포구 양평로 58 · 당산역 1번·13번 출구 1분)</p>' +
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
    .addItem('① 신청 내역 동기화', 'syncToSheet')
    .addItem('② 입금내역 매칭',   'importBankStatement')
    .addItem('③ 영수증 발송',     'sendReceipts')
    .addSeparator()
    .addItem('④ 미연결 입금 불러오기', 'loadUnmatched')
    .addItem('⑤ 수기 입금확인 반영',   'applyManual')
    .addSeparator()
    .addItem('⑥ 사전 설문 불러오기',   'syncSurvey')
    .addToUi();
}

function setupTriggers() {
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('syncToSheet').timeBased().everyMinutes(5).create();
  ScriptApp.newTrigger('onOpen').forSpreadsheet(SpreadsheetApp.getActive()).onOpen().create();
  Logger.log('트리거 설정 완료 — 5분마다 동기화');
}


// ─────────────── 4. 수기 입금확인 (자동 매칭이 못 잡은 입금) ───────────────
/**
 * 사용 순서
 *  ④ 미연결 입금 불러오기 → 「수기입금처리」 시트에 아직 어느 신청에도 연결 안 된 입금이 나온다.
 *  E열 「연결 대상」에 신청ID(개인신청·단체신청 시트 맨 끝 열) 또는 기관명(단체)·성함(개인)을 적는다.
 *    · 한 입금을 여러 신청에 나눌 때(예: 6만 원 = 단체 4만 + 개인 2만) : E열에 대상을 쉼표로 함께 적는다
 *      (예: 희망하우스, 남유선 / 신청ID와 기관명을 섞어도 됨). F열을 비우면 각 신청의 남은 청구액대로 나누고,
 *      다르게 나누려면 F열에 「40000 / 20000」처럼 대상 순서대로 적는다.
 *    · 나눠 낸 입금 2건(예: 12만 + 8만)을 한 신청에 : 두 줄 모두 같은 연결 대상을 적는다.
 *    · 통장에 없는 입금(현금 등) : 맨 아래 빈 줄에 A~D는 비우고 E·F·G만 적는다.
 *  ⑤ 수기 입금확인 반영 → 확인 창에서 내용을 보고 [확인]
 *    → 신청 건이 '입금확인'으로 바뀌고, 알림톡 ② 참석 확정 1회, 「③ 영수증 발송」 대상이 된다.
 */
const MANUAL_HEADER = ['입금ID', '거래일시', '입금자명(통장)', '입금액',
                       '연결 대상 (신청ID 또는 기관명·성함)', '연결 금액 (비우면 입금액 전부)', '메모', '처리결과'];

function loadUnmatched() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(SHEET_MANUAL);

  // 이미 적어 둔 입력은 살린다 (✅ 처리된 줄은 「수기입금기록」에 남아 있으므로 뺀다)
  const keep = {}, extra = [];
  if (sh && sh.getLastRow() > 1) {
    sh.getRange(2, 1, sh.getLastRow() - 1, 8).getDisplayValues().forEach(r => {
      if (String(r[7]).indexOf('✅') === 0) return;
      if (!r[4] && !r[5] && !r[6]) return;
      if (r[0]) (keep[r[0]] = keep[r[0]] || []).push([r[4], r[5], r[6], r[7]]);
      else extra.push(['', '', '', '', r[4], r[5], r[6], r[7]]);
    });
  }

  const list = sbSelect_('v_unmatched_payments', 'select=*&order=paid_at.asc');
  const rows = [];
  list.forEach(p => {
    const base = [String(p.id), toKst_(p.paid_at), p.payer_name, Number(p.amount)];
    const ins = keep[String(p.id)];
    if (ins && ins.length) ins.forEach(x => rows.push(base.concat(x)));
    else rows.push(base.concat(['', '', '', '']));
  });
  extra.forEach(r => rows.push(r));

  if (!sh) sh = ss.insertSheet(SHEET_MANUAL);
  sh.clear();
  sh.getRange(1, 1, 1, 8).setValues([MANUAL_HEADER])
    .setFontWeight('bold').setBackground('#10332f').setFontColor('#f0dbab').setWrap(true);
  const H = Math.max(rows.length, 1) + 10;              // 수기 줄을 적을 빈 줄 여유
  sh.getRange(2, 1, H, 1).setNumberFormat('@');
  sh.getRange(2, 5, H, 1).setNumberFormat('@');
  if (rows.length) sh.getRange(2, 1, rows.length, 8).setValues(rows);
  sh.getRange(2, 4, H, 1).setNumberFormat('#,##0');
  sh.getRange(2, 6, H, 1).setNumberFormat('#,##0');
  sh.getRange(2, 5, H, 3).setBackground('#fff8e1');     // 직원이 적는 칸
  sh.setFrozenRows(1);
  sh.setColumnWidths(1, 4, 110); sh.setColumnWidth(3, 200);
  sh.setColumnWidth(5, 280); sh.setColumnWidth(6, 150); sh.setColumnWidth(7, 220); sh.setColumnWidth(8, 360);
  ss.setActiveSheet(sh);
  ss.toast('미연결 입금 ' + list.length + '건을 불러왔습니다. 노란 칸에 연결 대상을 적고 「⑤ 수기 입금확인 반영」을 누르세요.',
           '수기 입금확인', 8);
}

function applyManual() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const ui = SpreadsheetApp.getUi();
  const sh = ss.getSheetByName(SHEET_MANUAL);
  if (!sh || sh.getLastRow() < 2) { ui.alert('먼저 「④ 미연결 입금 불러오기」를 실행해 주세요.'); return; }

  const n = sh.getLastRow() - 1;
  const vals = sh.getRange(2, 1, n, 8).getDisplayValues();
  const apps = sbSelect_('v_applications', 'select=id,kind,org_name,contact_name,amount_due,paid_amount,pay_status');

  // 처리할 줄: E열이 있고, 아직 처리 안 됐거나(빈칸) 전부 실패(❌)한 줄
  const todo = [];
  vals.forEach((r, i) => {
    const h = String(r[7]);
    if (!String(r[4]).trim() || h.indexOf('✅') === 0 || h.indexOf('⚠') === 0) return;
    todo.push(planRow_(r, i + 2, apps));
  });
  if (!todo.length) { ui.alert('노란 「연결 대상」 칸이 채워진 줄이 없습니다.'); return; }

  const lines = [];
  todo.forEach(x => {
    if (x.error) { lines.push('✕ ' + x.r[4] + ' — ' + x.error); return; }
    const src = (x.r[2] || '통장 외 입금') + (toInt_(x.r[3]) ? ' ' + won_(toInt_(x.r[3])) + '원' : '');
    if (x.items.length > 1) lines.push('• ' + src + ' 을(를) 나눠서');
    x.items.forEach(it => {
      const due = Math.max(Number(it.app.amount_due) - Number(it.app.paid_amount), 0);
      const tag = it.amt > due ? '  ⚠ 남은 청구 ' + won_(due) + ' → 초과 ' + won_(it.amt - due)
                : it.amt < due ? '  (남은 청구 ' + won_(due) + ' → 부족 ' + won_(due - it.amt) + ')' : '';
      lines.push((x.items.length > 1 ? '   – ' : '• ') + appLabel_(it.app) + ' ← ' +
                 (x.items.length > 1 ? '' : src + ' 중 ') + won_(it.amt) + '원' + tag);
    });
  });
  const okRows = todo.filter(x => !x.error);
  if (!okRows.length) { ui.alert('처리할 수 있는 줄이 없습니다.\n\n' + lines.join('\n')); return; }
  const go = ui.alert('수기 입금확인',
    lines.join('\n') + '\n\n위 내용대로 입금확인 처리할까요?\n' +
    '처음 입금확인되는 신청에는 알림톡 ② 참석 확정이 나가고, 「③ 영수증 발송」 대상이 됩니다.',
    ui.ButtonSet.OK_CANCEL);
  if (go !== ui.Button.OK) return;

  let log = ss.getSheetByName(SHEET_MANUAL_LOG);
  if (!log) {
    log = ss.insertSheet(SHEET_MANUAL_LOG);
    log.appendRow(['처리시각', '처리자', '입금ID', '입금자명(통장)', '연결 금액', '연결 신청', '신청ID', '메모', '결과']);
    log.getRange(1, 1, 1, 9).setFontWeight('bold').setBackground('#10332f').setFontColor('#f0dbab');
  }
  const who = Session.getActiveUser().getEmail() || '';
  let done = 0, fail = 0;

  todo.forEach(x => {
    if (x.error) { fail++; sh.getRange(x.row, 8).setValue('❌ ' + x.error); return; }
    const parts = [];
    let ok = 0;
    x.items.forEach(it => {
      try {
        const res = sbRpc_('manual_confirm', {
          p_application_id: it.app.id, p_amount: it.amt, p_payment_id: x.pid, p_note: x.r[6] || null
        });
        const due = Number(res.amount_due), paid = Number(res.paid_amount);
        const m = appLabel_(it.app) + ' ' + won_(it.amt) + ' · 청구 ' + won_(due) + ' / 입금 ' + won_(paid) +
                  (paid < due ? ' (부족 ' + won_(due - paid) + ')' : paid > due ? ' (초과 ' + won_(paid - due) + ')' : '');
        parts.push('✅ ' + m);
        log.appendRow([new Date(), who, x.pid || '', x.r[2], it.amt, appLabel_(it.app), it.app.id, x.r[6], '✅ ' + m]);
        ok++; done++;
      } catch (e) {
        parts.push('❌ ' + appLabel_(it.app) + ' — ' + friendlyError_(e.message));
        fail++;
      }
    });
    // 일부만 성공하면 ⚠ 로 시작 → 다시 실행해도 이 줄은 건너뛴다(남은 금액은 ④를 다시 누르면 새 줄로 나옴)
    const head = ok === x.items.length ? '' : ok ? '⚠ 일부만 반영 — ' : '';
    sh.getRange(x.row, 8).setValue(head + parts.join('  /  '));
  });

  syncToSheet();
  ui.alert('수기 입금확인 완료\n\n반영 ' + done + '건' + (fail ? ' · 실패 ' + fail + '건 (H열 사유 확인)' : '') +
           '\n\n이제 「③ 영수증 발송」을 누르면 이번에 확인된 건에도 영수증이 나갑니다.');
}

/**
 * 한 줄을 처리 계획으로 바꾼다.
 *  E열 : 신청ID·기관명·성함을 하나 또는 여러 개 (쉼표 · / · 줄바꿈 으로 구분, 신청ID는 붙여 써도 인식)
 *  F열 : 비우면 → 대상 1개는 입금액 전부, 여러 개는 각 신청의 '남은 청구액'대로 나눔
 *        숫자 1개 → 대상 1개는 그 금액, 여러 개는 그 합계를 남은 청구액대로 나눔
 *        숫자 여러 개(40000 / 20000) → 적은 순서대로 대상에 연결
 */
function planRow_(r, row, apps) {
  const x = { r, row, pid: r[0] ? Number(r[0]) : null, items: [] };
  const targets = splitTargets_(r[4], apps);
  const bad = targets.filter(t => !t.app);
  if (bad.length) { x.error = bad.map(t => t.error).join(' / '); return x; }
  if (!targets.length) { x.error = '연결 대상이 비어 있습니다'; return x; }
  const ids = targets.map(t => t.app.id);
  if (new Set(ids).size !== ids.length) { x.error = '같은 신청이 두 번 적혀 있습니다'; return x; }

  const amts = splitAmounts_(r[5]);
  const payAmt = toInt_(r[3]);
  if (targets.length === 1) {
    if (amts.length > 1) { x.error = '대상은 1개인데 금액이 여러 개입니다'; return x; }
    const a = amts[0] || payAmt;
    if (!a) { x.error = '금액이 없습니다(F열에 적어 주세요)'; return x; }
    x.items = [{ app: targets[0].app, amt: a }];
    return x;
  }
  if (amts.length === targets.length) {
    x.items = targets.map((t, i) => ({ app: t.app, amt: amts[i] }));
  } else if (amts.length <= 1) {
    const total = amts[0] || payAmt;
    const dues = targets.map(t => Math.max(Number(t.app.amount_due) - Number(t.app.paid_amount), 0));
    const sum = dues.reduce((s, v) => s + v, 0);
    if (!total) { x.error = '금액이 없습니다(F열에 적어 주세요)'; return x; }
    if (sum !== total) {
      x.error = won_(total) + '원을 나눌 수 없습니다 — 남은 청구액 합계가 ' + won_(sum) + '원(' +
                targets.map((t, i) => appLabel_(t.app) + ' ' + won_(dues[i])).join(', ') +
                ')입니다. F열에 「40000 / 20000」처럼 대상 순서대로 금액을 적어 주세요';
      return x;
    }
    x.items = targets.map((t, i) => ({ app: t.app, amt: dues[i] }));
  } else {
    x.error = '대상 ' + targets.length + '개와 금액 ' + amts.length + '개의 수가 다릅니다'; return x;
  }
  if (x.items.some(it => !(it.amt > 0))) { x.error = '0원인 대상이 있습니다 — 이미 다 낸 신청인지 확인해 주세요'; return x; }
  if (payAmt && x.items.reduce((s, it) => s + it.amt, 0) > payAmt) {
    x.error = '나눈 금액 합계가 입금액(' + won_(payAmt) + '원)보다 큽니다'; return x;
  }
  return x;
}

/** E열 → 대상 목록(적은 순서 유지). 쉼표·/·줄바꿈·세미콜론으로 나누고, 신청ID는 붙여 써도 따로 인식한다.
 *  구분 기호 없이 띄어쓰기로만 적었으면(예: '희망하우스 남유선') 단어별로 다시 찾아본다. */
function splitTargets_(input, apps) {
  const uuidRe = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ig;
  const parts = [];                                   // 적은 순서 그대로
  String(input || '').split(/[,，;；\/\n]+/).forEach(chunk => {
    let last = 0;
    chunk.replace(uuidRe, (m, off) => {
      const pre = chunk.slice(last, off).trim();
      if (pre) parts.push(pre);
      parts.push(m);
      last = off + m.length;
      return m;
    });
    const rest = chunk.slice(last).trim();
    if (rest) parts.push(rest);
  });
  const out = [];
  parts.forEach(part => {
    const t = resolveTarget_(part, apps);
    if (t.app || !/\s/.test(part)) { out.push(t); return; }
    const words = part.split(/\s+/).filter(Boolean).map(w => resolveTarget_(w, apps));
    if (words.every(w => w.app)) words.forEach(w => out.push(w)); else out.push(t);
  });
  return out;
}

/** F열 → 금액 목록. '60,000' 은 하나, '40000 / 20000' · '40,000, 20,000' · '40000,20000' 은 둘 */
function splitAmounts_(v) {
  const s = String(v || '').trim();
  if (!s) return [];
  return s.split(/\s*[\/;\n+]\s*|,\s+|\s+|,(?=\d{4,})/).map(toInt_).filter(n => n > 0);
}
const won_ = n => Number(n || 0).toLocaleString('ko-KR');

/** 연결 대상 찾기: 신청ID(앞 8자리 이상) → 기관명(단체) → 성함(개인) 순. 여러 건이면 신청ID를 요구한다. */
function resolveTarget_(input, apps) {
  const s = String(input || '').trim();
  if (!s) return { error: '연결 대상이 비어 있습니다' };
  if (/^[0-9a-f]{8}(-[0-9a-f-]*)?$/i.test(s)) {
    const hit = apps.filter(a => a.id.toLowerCase().indexOf(s.toLowerCase()) === 0);
    if (hit.length === 1) return { app: hit[0] };
    return { error: hit.length ? '신청ID가 여러 건과 겹칩니다 — 전체 ID를 넣어 주세요' : '그런 신청ID가 없습니다' };
  }
  const k = normName_(s);
  const hit = apps.filter(a => normName_(a.kind === 'group' ? a.org_name : a.contact_name) === k);
  if (hit.length === 1) return { app: hit[0] };
  if (hit.length > 1) return { error: '「' + s + '」 신청이 ' + hit.length + '건입니다 — 신청ID를 넣어 주세요' };
  return { error: '「' + s + '」 신청을 찾지 못했습니다 — 신청ID를 넣어 주세요' };
}
const normName_ = v => String(v || '').toLowerCase().replace(/[\s()（）\[\]·.,\-_"'“”]/g, '');
const toInt_ = v => { const n = parseInt(String(v || '').replace(/[^0-9]/g, ''), 10); return isNaN(n) ? 0 : n; };
const appLabel_ = a => a.kind === 'group' ? a.org_name + '(단체)' : a.contact_name + '(개인)';
function friendlyError_(m) {
  const t = String(m || '');
  const i = t.indexOf('|');
  if (i >= 0) return t.slice(i + 1).replace(/["}\]].*$/, '');
  return t.slice(0, 200);
}
