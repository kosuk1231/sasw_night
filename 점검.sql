-- ============================================================
-- 2026 서울사회복지사의 밤 · 시스템 점검
-- Supabase SQL Editor에 통째로 붙여넣고 RUN → 결과 표 확인
--
-- 실제 신청·입금·매칭까지 시험하지만, 시험한 내용은 전부 자동으로 되돌립니다.
-- (알림톡도 발송되지 않습니다 — 발송 요청까지 함께 취소됨)
-- ============================================================

create or replace function health_check()
returns table(번호 int, 영역 text, 항목 text, 결과 text, 상세 text)
language plpgsql as $$
declare
  n int := 0;
  s settings%rowtype;
  r jsonb; v jsonb; x text; cnt int; ok boolean;
  a1 uuid; a2 uuid;
begin
  -- ───────────── A. 구조 ─────────────
  for x in select unnest(array['settings','applications','attendees','payments','notifications']) loop
    n := n + 1;
    ok := to_regclass('public.' || x) is not null;
    return query select n, 'A 구조', '테이블 ' || x, case when ok then '✅' else '❌' end, case when ok then '' else '없음 → 스키마 실행 필요' end;
  end loop;

  n := n + 1;
  ok := exists (select 1 from information_schema.columns where table_name = 'attendees' and column_name = 'lifetime');
  return query select n, 'A 구조', '평생회원 열 (최신 스키마)', case when ok then '✅' else '❌' end, case when ok then '' else 'supabase-schema.sql 최신본 재실행' end;

  for x in select unnest(array['public_status','submit_application','import_payments','match_payment_manual',
                               'mark_receipt_sent','enqueue_paid_notice','mark_notification','amount_due','norm_key']) loop
    n := n + 1;
    ok := exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = x);
    return query select n, 'A 구조', '함수 ' || x, case when ok then '✅' else '❌' end, '';
  end loop;

  for x in select unnest(array['v_applications','v_attendees','v_pending_receipts']) loop
    n := n + 1;
    ok := to_regclass('public.' || x) is not null;
    return query select n, 'A 구조', '뷰 ' || x, case when ok then '✅' else '❌' end, '';
  end loop;

  -- ───────────── B. 보안 ─────────────
  n := n + 1;
  select count(*) into cnt from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relname in ('settings','applications','attendees','payments','notifications') and c.relrowsecurity;
  return query select n, 'B 보안', 'RLS 켜짐 (5개 테이블)', case when cnt = 5 then '✅' else '❌' end, cnt || '/5';

  n := n + 1;
  ok := not has_table_privilege('anon', 'public.v_applications', 'select')
    and not has_table_privilege('anon', 'public.v_attendees', 'select')
    and not has_table_privilege('anon', 'public.v_pending_receipts', 'select');
  return query select n, 'B 보안', '공개 키로 신청자 명단 조회 불가', case when ok then '✅' else '❌ 위험' end,
    case when ok then '' else '개인정보 노출 — 최신 스키마 재실행' end;

  n := n + 1;
  ok := not has_function_privilege('anon', 'public.import_payments(jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.match_payment_manual(bigint,uuid)', 'execute')
    and not has_function_privilege('anon', 'public.mark_receipt_sent(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.mark_notification(bigint,text,text,text)', 'execute');
  return query select n, 'B 보안', '공개 키로 입금·매칭 위조 불가', case when ok then '✅' else '❌ 위험' end,
    case when ok then '' else '입금 위조 가능 — 최신 스키마 재실행' end;

  n := n + 1;
  ok := has_function_privilege('anon', 'public.public_status()', 'execute')
    and has_function_privilege('anon', 'public.submit_application(text,text,text,text,text,text,text,jsonb)', 'execute');
  return query select n, 'B 보안', '공개 키로 상태조회·신청 가능', case when ok then '✅' else '❌' end,
    case when ok then '' else '신청 페이지가 작동하지 않음' end;

  n := n + 1;
  ok := has_table_privilege('service_role', 'public.v_applications', 'select')
    and has_function_privilege('service_role', 'public.import_payments(jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.mark_notification(bigint,text,text,text)', 'execute');
  return query select n, 'B 보안', '관리 키(service_role)로 시트·알림톡 작동', case when ok then '✅' else '❌' end,
    case when ok then '' else '시트 동기화·알림톡 결과 기록 실패 가능' end;

  -- ───────────── C. 설정 ─────────────
  select * into s from settings where id = 1;
  n := n + 1; return query select n, 'C 설정', '접수 오픈 시각', case when s.open_at = '2026-11-10 10:00:00+09'::timestamptz then '✅' else '⚠️' end,
    to_char(s.open_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI') || ' (KST)' || case when s.open_at <> '2026-11-10 10:00:00+09'::timestamptz then ' → 테스트 후 되돌렸는지 확인' else '' end;
  n := n + 1; return query select n, 'C 설정', '정원 / 기관당 최대', case when s.capacity = 450 and s.group_max = 10 then '✅' else '⚠️' end, s.capacity || '석 / ' || s.group_max || '명';
  n := n + 1; return query select n, 'C 설정', '참가비', case when s.fee = 20000 then '✅' else '⚠️' end, s.fee || '원';
  n := n + 1; return query select n, 'C 설정', '입금 계좌', case when s.bank_account = '140-012-291070' then '✅' else '⚠️' end, s.bank_name || ' ' || s.bank_account || ' (' || s.bank_holder || ')';
  n := n + 1; return query select n, 'C 설정', '수동 마감 스위치', case when not s.closed then '✅' else '⚠️' end, case when s.closed then '마감 상태 → closed = false 로' else '열림' end;

  -- ───────────── D. 알림톡 연결 ─────────────
  n := n + 1;
  select count(*) into cnt from pg_trigger where tgrelid = 'public.notifications'::regclass and not tgisinternal and tgenabled <> 'D';
  return query select n, 'D 알림톡', '알림톡 트리거 켜짐', case when cnt = 1 then '✅' when cnt = 0 then '❌' else '⚠️' end,
    case when cnt = 0 then '꺼져 있음 → alter table notifications enable trigger user;'
         when cnt > 1 then cnt || '개 — 중복 발송 위험 (Webhook과 SQL 트리거 중 하나만)' else '' end;

  n := n + 1;
  ok := exists (select 1 from pg_extension where extname = 'pg_net');
  return query select n, 'D 알림톡', 'pg_net 확장', case when ok then '✅' else '❌' end, case when ok then '' else 'Webhook이 Vercel을 호출할 수 없음' end;

  n := n + 1;
  select count(*) into cnt from notifications where status = 'failed';
  return query select n, 'D 알림톡', '실패한 알림', case when cnt = 0 then '✅' else '⚠️' end,
    cnt || '건' || case when cnt > 0 then ' → select id, to_phone, error from notifications where status = ''failed'';' else '' end;

  n := n + 1;
  select count(*) into cnt from notifications where status = 'pending' and created_at < now() - interval '2 minutes';
  return query select n, 'D 알림톡', '2분 넘게 대기 중인 알림', case when cnt = 0 then '✅' else '⚠️' end,
    cnt || '건' || case when cnt > 0 then ' → Webhook 호출 실패 의심' else '' end;

  -- ───────────── E. 현재 데이터 ─────────────
  n := n + 1;
  return query select n, 'E 데이터', '신청 / 참가자 / 입금 / 알림',
    case when (select count(*) from applications) = 0 then '✅' else 'ℹ️' end,
    (select count(*) from applications) || '건 / ' || (select count(*) from attendees where status = 'active') || '명 / '
    || (select count(*) from payments) || '건 / ' || (select count(*) from notifications) || '건'
    || case when (select count(*) from applications) > 0 and now() < s.open_at then ' → 오픈 전인데 데이터가 있음 (테스트 흔적?)' else '' end;
  n := n + 1;
  return query select n, 'E 데이터', '공개 상태 (페이지에 보이는 값)', '✅', public_status()::text;

  -- ───────────── F. 모의 실행 (끝나면 전부 되돌림) ─────────────
  begin
    update settings set open_at = now() - interval '1 minute', closed = false where id = 1;

    -- F1 개인 신청
    r := submit_application('individual','점검복지관','점검개인','010-9999-0001','check@example.com','점검개인901111','점검',
                            '[{"name":"점검개인","phone":"010-9999-0001","birth6":"901111"}]');
    n := n + 1; return query select n, 'F 모의실행', '개인 신청', case when (r->>'ok')::boolean and (r->>'added_amount')::int = s.fee then '✅' else '❌' end, '청구 ' || (r->>'added_amount') || '원';
    a1 := (r->>'application_id')::uuid;

    -- F2 단체 3명 (평생 1)
    r := submit_application('group','점검단체복지관','점검담당','010-9999-0010','check@example.com','점검담당(점검단체)','',
                            '[{"name":"가","phone":"010-9999-0011"},{"name":"나","phone":"010-9999-0012","lifetime":true},{"name":"다","phone":"010-9999-0013"}]');
    n := n + 1; return query select n, 'F 모의실행', '단체 3명 (평생회원 1)', case when (r->>'added_amount')::int = 2 * s.fee then '✅' else '❌' end, '청구 ' || (r->>'added_amount') || '원 (2명분이어야 함)';
    a2 := (r->>'application_id')::uuid;

    -- F3 같은 기관 재신청 → 합쳐짐
    r := submit_application('group','(사) 점검단체 복지관','점검담당','010-9999-0010','check@example.com','점검담당(점검단체)','',
                            '[{"name":"라","phone":"010-9999-0014"}]');
    n := n + 1; return query select n, 'F 모의실행', '같은 기관 재신청 → 합치기', case when (r->>'org_total')::int = 4 then '✅' else '❌' end, '누적 ' || (r->>'org_total') || '명';

    -- F4 기관 10명 초과
    begin
      r := submit_application('group','점검단체복지관','점검담당','010-9999-0010','check@example.com','x','',
             (select jsonb_agg(jsonb_build_object('name','초과'||g,'phone','010-9998-'||lpad(g::text,4,'0'))) from generate_series(1,7) g));
      n := n + 1; return query select n, 'F 모의실행', '기관 10명 초과 차단', '❌', '막혀야 하는데 접수됨';
    exception when others then
      n := n + 1; return query select n, 'F 모의실행', '기관 10명 초과 차단', case when sqlerrm like 'GROUP_MAX%' then '✅' else '❌' end, split_part(sqlerrm, '|', 2);
    end;

    -- F5 중복 번호
    begin
      r := submit_application('individual','없음','중복','010-9999-0001','check@example.com','중복',null,'[{"name":"중복","phone":"010-9999-0001"}]');
      n := n + 1; return query select n, 'F 모의실행', '같은 번호 중복 차단', '❌', '막혀야 하는데 접수됨';
    exception when others then
      n := n + 1; return query select n, 'F 모의실행', '같은 번호 중복 차단', case when sqlerrm like 'DUP%' then '✅' else '❌' end, split_part(sqlerrm, '|', 2);
    end;

    -- F6 알림 적재
    select count(*) into cnt from notifications where application_id in (a1, a2) and kind = 'applied';
    n := n + 1; return query select n, 'F 모의실행', '신청 알림톡 적재 (참가자 전원 + 담당자)', case when cnt = 7 then '✅' else '❌' end, cnt || '건 (개인 1 + 단체 참가자 4 + 명단에 없는 담당자 2회 신청 2 = 7)';

    -- F7 입금 매칭 (은행이 잘라낸 이름 포함)
    v := import_payments(jsonb_build_array(
           jsonb_build_object('paid_at', now(), 'payer_name', '점검개인9011',       'amount', s.fee,     'raw', 'hc1-' || now()),
           jsonb_build_object('paid_at', now(), 'payer_name', '점검담당(점검단체', 'amount', 3 * s.fee, 'raw', 'hc2-' || now())));
    n := n + 1; return query select n, 'F 모의실행', '입금 자동매칭 (잘린 입금자명)', case when (v->>'matched')::int = 2 then '✅' else '❌' end, v::text;

    select count(*) into cnt from notifications where application_id in (a1, a2) and kind = 'paid';
    n := n + 1; return query select n, 'F 모의실행', '확정 알림톡 적재', case when cnt = 2 then '✅' else '❌' end, cnt || '건';

    select count(*) into cnt from v_pending_receipts where id in (a1, a2);
    n := n + 1; return query select n, 'F 모의실행', '영수증 발송 대상', case when cnt = 2 then '✅' else '❌' end, cnt || '건';

    raise exception 'HC_ROLLBACK';
  exception when others then
    if sqlerrm <> 'HC_ROLLBACK' then
      n := n + 1; return query select n, 'F 모의실행', '실행 중 오류', '❌', sqlerrm;
    end if;
  end;

  n := n + 1;
  return query select n, 'F 모의실행', '모의 데이터 되돌림',
    case when not exists (select 1 from attendees where phone_key like '0109999%' or phone_key like '0109998%') then '✅' else '❌' end,
    '오픈 시각·데이터 원상태, 알림톡 미발송';
end $$;

revoke all on function health_check() from public, anon, authenticated;

select * from health_check();
