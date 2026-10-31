-- ============================================================
-- 2026 서울사회복지사의 밤 · 사전신청 시스템
-- Supabase (PostgreSQL) 스키마
-- 실행: Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 RUN
-- ============================================================

-- ------------------------------------------------------------
-- 0. 공통 유틸
-- ------------------------------------------------------------

-- 기관명·입금자명 정규화 키
--   "(사)서울시 사회복지사협회" → "서울시사회복지사협회"
--   법인격 표기, 공백, 특수문자를 제거해 같은 단체로 묶는다.
create or replace function norm_key(t text)
returns text language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             lower(coalesce(t, '')),
             '\(주\)|\(사\)|\(재\)|\(의\)|주식회사|사단법인|재단법인|의료법인|사회복지법인|학교법인',
             '', 'g'
           ),
           '[^0-9a-z가-힣]', '', 'g'
         )
$$;

-- 1234567 → '1,234,567'
create or replace function won(n int)
returns text language sql immutable as $$
  select trim(to_char(coalesce(n,0), 'FM999,999,999,999'))
$$;

-- timestamptz → '11월 13일(금)'  (KST)
create or replace function kdate(ts timestamptz)
returns text language sql immutable as $$
  select to_char(ts at time zone 'Asia/Seoul', 'FMMM월 FMDD일')
      || '(' || (array['일','월','화','수','목','금','토'])[extract(dow from ts at time zone 'Asia/Seoul')::int + 1] || ')'
$$;

-- 전화번호에서 숫자만
create or replace function digits_only(t text)
returns text language sql immutable as $$
  select regexp_replace(coalesce(t, ''), '[^0-9]', '', 'g')
$$;

-- ------------------------------------------------------------
-- 1. 설정 (코드 수정 없이 여기서 바꾼다)
-- ------------------------------------------------------------
create table if not exists settings (
  id          int primary key default 1,
  open_at     timestamptz not null default '2026-11-10 10:00:00+09',  -- 접수 오픈
  close_at    timestamptz,                                            -- 비워두면 정원까지
  capacity    int  not null default 450,                              -- 전체 정원
  group_max   int  not null default 10,                               -- 기관당 누적 최대 (단체+개인 소속 합산)
  fee         int  not null default 20000,                            -- 1인 참가비(원)
  closed      boolean not null default false,                         -- 수동 마감 스위치
  bank_name   text default '신한은행',
  bank_account text default '140-012-291070',
  bank_holder text default '서울특별시사회복지사협회',
  pay_due_days int  not null default 3,                               -- 입금 기한(신청일 + N일), 알림톡 #{입금기한}
  constraint settings_singleton check (id = 1)
);
insert into settings (id) values (1) on conflict (id) do nothing;

-- ------------------------------------------------------------
-- 2. 신청 (개인 1건 = 1행, 단체 1곳 = 1행)
-- ------------------------------------------------------------
create table if not exists applications (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('individual', 'group')),
  org_name      text,                                    -- 단체: 기관명 / 개인: 소속(선택)
  org_key       text,                                    -- 기관 키 (단체 병합 + 개인 소속 합산에 사용)
  contact_name  text not null,
  contact_phone text not null,
  contact_email text not null,
  payer_name    text not null,                           -- 실제 입금자명
  payer_key     text generated always as (norm_key(payer_name)) stored,
  memo          text,
  paid_amount   int not null default 0,
  paid_at       timestamptz,
  receipt_sent_at timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- 단체는 org_key 하나당 1행만 → 재신청이 같은 행으로 합쳐지는 근거
create unique index if not exists applications_group_uniq
  on applications (org_key) where kind = 'group';
create index if not exists applications_payer_key_idx on applications (payer_key);

-- ------------------------------------------------------------
-- 3. 참가자 (1명 = 1행, 450명 카운트의 기준)
-- ------------------------------------------------------------
create table if not exists attendees (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references applications(id) on delete cascade,
  seq            int  not null,
  name           text not null,
  position       text,
  phone          text not null,
  phone_key      text generated always as (digits_only(phone)) stored,
  birth6         text,
  status         text not null default 'active' check (status in ('active', 'cancelled')),
  created_at     timestamptz not null default now()
);
create index if not exists attendees_app_idx on attendees (application_id);
-- 같은 번호로 두 번 신청되는 것을 DB 레벨에서 차단
create unique index if not exists attendees_phone_uniq
  on attendees (phone_key) where status = 'active';

-- ------------------------------------------------------------
-- 4. 은행 입금 내역
-- ------------------------------------------------------------
create table if not exists payments (
  id             bigserial primary key,
  paid_at        timestamptz,
  payer_name     text not null,
  payer_key      text generated always as (norm_key(payer_name)) stored,
  amount         int  not null,
  fingerprint    text unique,              -- 같은 파일 재업로드 시 중복 방지
  raw            text,
  application_id uuid references applications(id),
  match_type     text check (match_type in ('auto', 'manual')),
  matched_at     timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists payments_payer_key_idx on payments (payer_key);

-- ------------------------------------------------------------
-- 4-1. 카카오 알림톡 발송함 (outbox)
--   DB가 여기에 행을 넣으면 → Database Webhook → Vercel /api/kakao → Solapi
--   클라이언트가 중간에 꺼져도 DB 트랜잭션과 함께 기록되므로 누락이 없다.
-- ------------------------------------------------------------
create table if not exists notifications (
  id             bigserial primary key,
  application_id uuid references applications(id) on delete cascade,
  kind           text not null check (kind in ('applied','paid')),   -- applied: 신청자 전원 / paid: 담당자·신청자
  to_phone       text not null,
  variables      jsonb not null default '{}'::jsonb,   -- Solapi 치환변수 {"#{이름}":"홍길동", ...}
  status         text not null default 'pending' check (status in ('pending','sent','failed')),
  provider_id    text,            -- Solapi groupId / messageId
  error          text,
  attempts       int not null default 0,
  created_at     timestamptz not null default now(),
  sent_at        timestamptz
);
create index if not exists notifications_status_idx on notifications (status, id);

-- ------------------------------------------------------------
-- 5. RLS — 익명 키로는 테이블에 직접 접근 불가.
--    아래 SECURITY DEFINER 함수로만 들어온다.
-- ------------------------------------------------------------
alter table settings     enable row level security;
alter table applications enable row level security;
alter table attendees    enable row level security;
alter table payments     enable row level security;
alter table notifications enable row level security;
-- 정책을 만들지 않음 = anon 전면 차단 (service_role 키는 RLS 우회)

-- ------------------------------------------------------------
-- 6. 공개 상태 조회 — 신청 페이지가 1초마다 부르는 함수
--    서버 시각(server_now)을 함께 돌려줘서, 사용자가 PC 시계를
--    조작해도 오픈 시각을 앞당길 수 없게 한다.
-- ------------------------------------------------------------
create or replace function public_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare s settings%rowtype; used int;
begin
  select * into s from settings where id = 1;
  select count(*) into used from attendees where status = 'active';
  -- 정원(capacity)과 잔여석은 내부 운영 기준이라 외부에 내보내지 않는다.
  return jsonb_build_object(
    'server_now',  now(),
    'open_at',     s.open_at,
    'used',        used,
    'nearly_full', (s.capacity - used) <= 30,
    'group_max',   s.group_max,
    'fee',         s.fee,
    'closed',      s.closed or (s.close_at is not null and now() > s.close_at) or used >= s.capacity,
    'bank',       jsonb_build_object('name', s.bank_name, 'account', s.bank_account, 'holder', s.bank_holder)
  );
end $$;

-- ------------------------------------------------------------
-- 7. 신청 접수 — 이 시스템의 심장
--    정원 확인과 저장이 하나의 트랜잭션 안에서 끝난다.
--    advisory lock 으로 동시 신청을 한 줄로 세워 451번째를 막는다.
-- ------------------------------------------------------------
create or replace function submit_application(
  p_kind          text,
  p_org_name      text,
  p_contact_name  text,
  p_contact_phone text,
  p_contact_email text,
  p_payer_name    text,
  p_memo          text,
  p_attendees     jsonb      -- [{name, position, phone, birth6}, ...]
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s     settings%rowtype;
  app   applications%rowtype;
  n     int;
  used  int;
  cur   int := 0;
  org_total int := 0;
  k     text;
  i     int := 0;
  rec   jsonb;
  dup   text;
begin
  select * into s from settings where id = 1;

  if s.closed or (s.close_at is not null and now() > s.close_at) then
    raise exception 'CLOSED|접수가 마감되었습니다.';
  end if;
  if now() < s.open_at then
    raise exception 'NOT_OPEN|아직 접수 시작 전입니다.';
  end if;

  n := jsonb_array_length(coalesce(p_attendees, '[]'::jsonb));
  if n < 1 then
    raise exception 'EMPTY|참가자를 1명 이상 입력해 주세요.';
  end if;
  if p_kind = 'individual' and n <> 1 then
    raise exception 'IND_ONE|개인 신청은 1명만 가능합니다.';
  end if;

  -- 여기부터 커밋까지 한 번에 한 건만 통과한다
  perform pg_advisory_xact_lock(hashtext('swnight2026'));

  select count(*) into used from attendees where status = 'active';
  if used + n > s.capacity then
    raise exception 'FULL|남은 자리가 신청 인원보다 적습니다. 인원을 줄여 다시 시도해 주세요.';
  end if;

  -- 휴대전화 중복 확인 (이미 신청된 사람 차단)
  select a.name into dup
  from jsonb_array_elements(p_attendees) e
  join attendees a
    on a.status = 'active'
   and a.phone_key = digits_only(e->>'phone')
  limit 1;
  if dup is not null then
    raise exception 'DUP|%님은 이미 신청이 완료되어 있습니다.', dup;
  end if;

  -- 기관 키: 단체는 기관명, 개인은 소속으로 만든다 (둘 다 같은 10명 한도에 합산)
  k := nullif(norm_key(p_org_name), '');

  if p_kind = 'group' then
    if k is null then
      raise exception 'NO_ORG|기관·단체명을 입력해 주세요.';
    end if;

    select * into app from applications where kind = 'group' and org_key = k for update;

    -- 같은 기관의 누적 인원 = 단체 신청 + 개인으로 신청한 같은 소속
    select count(*) into org_total
      from attendees t join applications a on a.id = t.application_id
     where a.org_key = k and t.status = 'active';
    if org_total + n > s.group_max then
      raise exception 'GROUP_MAX|「%」은(는) 이미 %명 신청되어 있어 %명까지 추가할 수 있습니다. (기관당 최대 %명, 개인 신청 포함)',
        btrim(p_org_name), org_total, greatest(s.group_max - org_total, 0), s.group_max;
    end if;

    if found then
      -- ── 재신청: 기존 단체 행에 합친다 ──
      select count(*) into cur from attendees
       where application_id = app.id and status = 'active';
      update applications set
        contact_name  = p_contact_name,
        contact_phone = p_contact_phone,
        contact_email = p_contact_email,
        payer_name    = p_payer_name,
        memo          = case when coalesce(p_memo,'') = '' then memo else p_memo end,
        updated_at    = now()
      where id = app.id;
    else
      insert into applications
        (kind, org_name, org_key, contact_name, contact_phone, contact_email, payer_name, memo)
      values
        ('group', btrim(p_org_name), k, p_contact_name, p_contact_phone, p_contact_email, p_payer_name, p_memo)
      returning * into app;
    end if;
  else
    -- 개인 신청: 소속 기관의 누적 인원이 한도에 닿았으면 막는다
    if k is not null then
      select count(*) into org_total
        from attendees t join applications a on a.id = t.application_id
       where a.org_key = k and t.status = 'active';
      if org_total + n > s.group_max then
        raise exception 'GROUP_MAX|「%」 소속은 이미 %명이 신청되어 있습니다. 기관당 최대 %명까지만 참석할 수 있습니다.',
          btrim(p_org_name), org_total, s.group_max;
      end if;
    end if;
    insert into applications
      (kind, org_name, org_key, contact_name, contact_phone, contact_email, payer_name, memo)
    values
      ('individual', nullif(btrim(coalesce(p_org_name,'')),''), k, p_contact_name, p_contact_phone, p_contact_email, p_payer_name, p_memo)
    returning * into app;
  end if;

  for rec in select * from jsonb_array_elements(p_attendees) loop
    i := i + 1;
    insert into attendees (application_id, seq, name, position, phone, birth6)
    values (app.id, cur + i, btrim(rec->>'name'), nullif(btrim(coalesce(rec->>'position','')),''),
            btrim(rec->>'phone'), nullif(btrim(coalesce(rec->>'birth6','')),''));
  end loop;

  -- ── 카카오 알림톡 적재: 신청자 전원 (단체든 개인이든 참가자 한 명당 1건) ──
  insert into notifications (application_id, kind, to_phone, variables)
  select app.id, 'applied', btrim(e->>'phone'), jsonb_build_object(
    '#{이름}',     btrim(e->>'name'),
    '#{구분}',     case when app.kind = 'group' then '단체' else '개인' end,
    '#{기관명}',   coalesce(app.org_name, '-'),
    '#{담당자}',   p_contact_name,
    '#{인원}',     n::text,
    '#{누적인원}', (cur + n)::text,
    '#{금액}',     won(n * s.fee),
    '#{누적금액}', won((cur + n) * s.fee),
    '#{입금자명}', p_payer_name,
    '#{은행}',     coalesce(s.bank_name, ''),
    '#{계좌번호}', coalesce(s.bank_account, ''),
    '#{예금주}',   coalesce(s.bank_holder, ''),
    '#{입금기한}', kdate(now() + make_interval(days => s.pay_due_days)),
    '#{행사일시}', '2026. 12. 4.(금) 17:00',
    '#{장소}',     '그랜드컨벤션센터'
  )
  from jsonb_array_elements(p_attendees) e;

  -- 담당자가 참가자 명단에 없으면(대리 신청) 담당자에게도 1건
  if p_kind = 'group' and not exists (
       select 1 from jsonb_array_elements(p_attendees) e
        where digits_only(e->>'phone') = digits_only(p_contact_phone)) then
    insert into notifications (application_id, kind, to_phone, variables)
    select app.id, 'applied', p_contact_phone,
           (select variables from notifications
             where application_id = app.id and kind = 'applied'
             order by id desc limit 1) || jsonb_build_object('#{이름}', p_contact_name);
  end if;

  select count(*) into used from attendees where status = 'active';

  return jsonb_build_object(
    'ok',            true,
    'application_id', app.id,
    'kind',          app.kind,
    'org_name',      app.org_name,
    'added',         n,
    'org_total',     cur + n,
    'added_amount',  n * s.fee,
    'total_amount',  (cur + n) * s.fee,
    'remaining',     greatest(s.capacity - used, 0)
  );
end $$;

-- ------------------------------------------------------------
-- 8. 입금 내역 업로드 + 자동 매칭
--    p_rows: [{paid_at, payer_name, amount, raw}, ...]
--    매칭 조건: 입금자명 정규화 키 일치  AND  금액이 청구액과 일치
-- ------------------------------------------------------------
create or replace function import_payments(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  rec       jsonb;
  inserted  int := 0;
  skipped   int := 0;
  matched   int := 0;
  fp        text;
  s         settings%rowtype;
  p         payments%rowtype;
  target    uuid;
begin
  select * into s from settings where id = 1;

  -- 1) 적재 (fingerprint 로 같은 거래 중복 방지)
  for rec in select * from jsonb_array_elements(p_rows) loop
    fp := md5(coalesce(rec->>'paid_at','') || '|' || coalesce(rec->>'payer_name','')
              || '|' || coalesce(rec->>'amount','') || '|' || coalesce(rec->>'raw',''));
    begin
      insert into payments (paid_at, payer_name, amount, fingerprint, raw)
      values (nullif(rec->>'paid_at','')::timestamptz,
              btrim(rec->>'payer_name'),
              (rec->>'amount')::int,
              fp,
              rec->>'raw');
      inserted := inserted + 1;
    exception when unique_violation then
      skipped := skipped + 1;
    end;
  end loop;

  -- 2) 자동 매칭
  for p in select * from payments where application_id is null order by id loop
    target := null;

    -- 입금자명 키 일치 + 미납 금액이 정확히 맞는 건
    select a.id into target
    from applications a
    where (a.payer_key = p.payer_key or a.org_key = p.payer_key)
      and a.paid_at is null
      and (select count(*) from attendees t
            where t.application_id = a.id and t.status='active') * s.fee = p.amount
    order by a.created_at
    limit 1;

    if target is not null then
      update payments
         set application_id = target, match_type = 'auto', matched_at = now()
       where id = p.id;
      update applications
         set paid_amount = paid_amount + p.amount,
             paid_at     = coalesce(p.paid_at, now()),
             updated_at  = now()
       where id = target;
      perform enqueue_paid_notice(target);
      matched := matched + 1;
    end if;
  end loop;

  return jsonb_build_object('inserted', inserted, 'skipped', skipped, 'matched', matched);
end $$;

-- 입금 확인 알림톡 적재 (자동·수기 매칭 공통)
create or replace function enqueue_paid_notice(p_application_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a applications%rowtype; hc int;
begin
  select * into a from applications where id = p_application_id;
  select count(*) into hc from attendees where application_id = a.id and status = 'active';
  insert into notifications (application_id, kind, to_phone, variables)
  values (a.id, 'paid', a.contact_phone, jsonb_build_object(
    '#{이름}',     a.contact_name,
    '#{기관명}',   coalesce(a.org_name, ''),
    '#{인원}',     hc::text,
    '#{입금액}',   won(a.paid_amount),
    '#{입금일}',   to_char(coalesce(a.paid_at, now()) at time zone 'Asia/Seoul', 'YYYY. MM. DD.'),
    '#{이메일}',   a.contact_email,
    '#{행사일시}', '2026. 12. 4.(금) 17:00',
    '#{장소}',     '그랜드컨벤션센터'
  ));
end $$;

-- 수기 매칭 (자동으로 못 잡은 건을 관리자가 연결)
create or replace function match_payment_manual(p_payment_id bigint, p_application_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p payments%rowtype;
begin
  select * into p from payments where id = p_payment_id;
  if not found then raise exception 'NOT_FOUND|입금 건을 찾을 수 없습니다.'; end if;
  if p.application_id is not null then raise exception 'ALREADY|이미 매칭된 건입니다.'; end if;

  update payments set application_id = p_application_id, match_type = 'manual', matched_at = now()
   where id = p_payment_id;
  update applications
     set paid_amount = paid_amount + p.amount,
         paid_at     = coalesce(paid_at, p.paid_at, now()),
         updated_at  = now()
   where id = p_application_id;
  perform enqueue_paid_notice(p_application_id);
  return jsonb_build_object('ok', true);
end $$;

-- 영수증 발송 기록
create or replace function mark_receipt_sent(p_application_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update applications set receipt_sent_at = now(), updated_at = now()
   where id = p_application_id;
  return jsonb_build_object('ok', true);
end $$;

-- 알림톡 발송 결과 기록 (Vercel /api/kakao 가 service_role 키로 호출)
create or replace function mark_notification(p_id bigint, p_status text, p_provider_id text, p_error text)
returns void language sql security definer set search_path = public as $$
  update notifications
     set status = p_status, provider_id = p_provider_id, error = p_error,
         attempts = attempts + 1,
         sent_at = case when p_status = 'sent' then now() else sent_at end
   where id = p_id
$$;

-- ------------------------------------------------------------
-- 9. 조회용 뷰 (구글시트 동기화 · 관리자 화면)
-- ------------------------------------------------------------
create or replace view v_applications as
select
  a.id, a.kind,
  case a.kind when 'group' then '단체' else '개인' end as kind_label,
  a.org_name, a.contact_name, a.contact_phone, a.contact_email, a.payer_name,
  (select count(*) from attendees t where t.application_id = a.id and t.status='active') as headcount,
  (select count(*) from attendees t where t.application_id = a.id and t.status='active')
    * (select fee from settings where id=1) as amount_due,
  a.paid_amount, a.paid_at,
  case when a.paid_at is not null then '입금확인' else '미입금' end as pay_status,
  a.receipt_sent_at, a.memo, a.created_at, a.updated_at
from applications a;

create or replace view v_attendees as
select
  t.id, t.application_id,
  case a.kind when 'group' then '단체' else '개인' end as kind_label,
  a.org_name, t.seq, t.name, t.position, t.phone, t.birth6, t.status,
  case when a.paid_at is not null then '입금확인' else '미입금' end as pay_status,
  t.created_at
from attendees t join applications a on a.id = t.application_id
where t.status = 'active';

-- 영수증 보낼 대상: 입금 확인됐고 아직 안 보낸 건
create or replace view v_pending_receipts as
select a.id, a.kind, a.org_name, a.contact_name, a.contact_email, a.payer_name,
       a.paid_amount, a.paid_at,
       (select count(*) from attendees t where t.application_id=a.id and t.status='active') as headcount
from applications a
where a.paid_at is not null and a.receipt_sent_at is null;

-- ------------------------------------------------------------
-- 10. 권한 — 익명 키로 부를 수 있는 함수만 열어준다
-- ------------------------------------------------------------
grant execute on function public_status()        to anon, authenticated;
grant execute on function submit_application(text,text,text,text,text,text,text,jsonb) to anon, authenticated;
revoke execute on function import_payments(jsonb)          from anon, authenticated;
revoke execute on function match_payment_manual(bigint,uuid) from anon, authenticated;
revoke execute on function mark_receipt_sent(uuid)         from anon, authenticated;
revoke execute on function enqueue_paid_notice(uuid)       from anon, authenticated;
revoke execute on function mark_notification(bigint,text,text,text) from anon, authenticated;

-- ============================================================
-- 설정 예시 (값을 채워 실행)
-- ============================================================
-- update settings set
--   fee          = 20000,
--   bank_name    = '신한은행',
--   bank_account = '140-012-291070',
--   bank_holder  = '서울특별시사회복지사협회',
--   pay_due_days = 3               -- 알림톡 #{입금기한} = 신청일 + 3일
-- where id = 1;
--
-- [Database Webhook 설정]  Supabase 대시보드 > Database > Webhooks > Create
--   Table: notifications / Events: INSERT
--   Type: HTTP Request / Method: POST
--   URL: https://<배포도메인>/api/kakao
--   HTTP Headers: x-webhook-secret: <WEBHOOK_SECRET 과 같은 값>
