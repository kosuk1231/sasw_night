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
-- 평생회원은 참가비 면제
alter table attendees add column if not exists lifetime boolean not null default false;

-- 신청 1건의 청구액 = 평생회원이 아닌 참가자 수 × 참가비
create or replace function amount_due(p_application_id uuid)
returns int language sql stable as $$
  select (count(*) filter (where not t.lifetime))::int * (select fee from settings where id = 1)
    from attendees t where t.application_id = p_application_id and t.status = 'active'
$$;
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
  -- 잔여 좌석만 공개한다. 신청 인원(used)을 함께 내보내면 둘을 더해 정원이 계산되므로 내보내지 않는다.
  return jsonb_build_object(
    'server_now',  now(),
    'open_at',     s.open_at,
    'remaining',   greatest(s.capacity - used, 0),
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

  -- 같은 신청서 안에서 참가자끼리 번호가 겹치는지 (예: 담당자 번호를 여러 칸에 반복 입력)
  select digits_only(e->>'phone') into dup
    from jsonb_array_elements(p_attendees) e
   group by digits_only(e->>'phone')
  having count(*) > 1
   limit 1;
  if dup is not null then
    raise exception 'DUP_IN|참가자 명단에 같은 연락처(%)가 두 번 이상 들어 있습니다. 참가자마다 본인 휴대전화 번호를 입력해 주세요.',
      regexp_replace(dup, '^(\d{3})(\d{3,4})(\d{4})$', '\1-\2-\3');
  end if;
  dup := null;

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
  -- '없음' 류는 기관이 아니다 → 10명 합산에서 제외
  if k in ('없음','없슴','무소속','소속없음','해당없음','na','none') then k := null; end if;

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

    -- 주의: 위의 count(*) 가 FOUND 를 항상 true 로 바꾸므로 FOUND 대신 app.id 로 판단한다
    if app.id is not null then
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
    insert into attendees (application_id, seq, name, position, phone, birth6, lifetime)
    values (app.id, cur + i, btrim(rec->>'name'), nullif(btrim(coalesce(rec->>'position','')),''),
            btrim(rec->>'phone'), nullif(btrim(coalesce(rec->>'birth6','')),''),
            coalesce((rec->>'lifetime')::boolean, false));
  end loop;

  -- ── 카카오 알림톡 ① 신청 접수: 참가자 전원 (변수는 #{성함} 하나) ──
  insert into notifications (application_id, kind, to_phone, variables)
  select app.id, 'applied', btrim(e->>'phone'),
         jsonb_build_object('#{성함}', btrim(e->>'name'))
  from jsonb_array_elements(p_attendees) e;

  -- 담당자가 참가자 명단에 없으면(대리 신청) 담당자에게도 1건
  if p_kind = 'group' and not exists (
       select 1 from jsonb_array_elements(p_attendees) e
        where digits_only(e->>'phone') = digits_only(p_contact_phone)) then
    insert into notifications (application_id, kind, to_phone, variables)
    values (app.id, 'applied', p_contact_phone, jsonb_build_object('#{성함}', p_contact_name));
  end if;

  -- 참가자 전원이 평생회원이면 낼 돈이 없으므로 바로 '확정' (입금 매칭·영수증 대상에서 빠짐)
  if amount_due(app.id) = 0 then
    update applications set paid_at = coalesce(paid_at, now()), updated_at = now() where id = app.id;
  end if;

  select count(*) into used from attendees where status = 'active';

  return jsonb_build_object(
    'ok',            true,
    'application_id', app.id,
    'kind',          app.kind,
    'org_name',      app.org_name,
    'added',         n,
    'org_total',     cur + n,
    'added_amount',  (select (count(*) filter (where not coalesce((e->>'lifetime')::boolean,false)))::int
                        from jsonb_array_elements(p_attendees) e) * s.fee,
    'total_amount',  amount_due(app.id),
    'exempt',        amount_due(app.id) = 0,
    'remaining',     greatest(s.capacity - used, 0)
  );
exception
  when unique_violation then
    raise exception 'DUP|이미 신청된 연락처가 포함되어 있습니다. 참가자마다 본인 휴대전화 번호를 입력했는지 확인해 주세요.';
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
  base      text;
  digs      text;
  head      text;
  is_amb    boolean;
  ambiguous int := 0;
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
  --   은행 「내용」은 '주희진861208'(이름+생년월일), '고창기 / 6803'(이름+전화 뒷자리),
  --   '서울구로삶터지역자활'(기관명이 10자에서 잘림)처럼 들어온다.
  --   ▸ 이름 부분  : 뒤에 붙은 숫자를 떼어낸 키 (base)
  --   ▸ 숫자 부분  : 참가자 생년월일 6자리 또는 전화번호 뒷자리와 대조해 동명이인을 가른다
  --   ▸ 기관명 잘림 : 5자 이상이면 앞부분 일치도 후보로 본다
  --   후보가 같은 점수로 2건 이상이면 '보류' — 엉뚱한 사람에게 붙이느니 사람이 확인한다.
  -- 이름 뒤에 숫자(생년월일·전화 뒷자리)가 붙은 입금을 먼저 처리 → 동명이인이 확실한 쪽부터 자리를 잡는다
  for p in select * from payments where application_id is null
           order by (payer_key ~ '[0-9]{4,}$') desc, id loop
    target := null;
    base   := regexp_replace(p.payer_key, '[0-9]+$', '');                       -- '주희진861208' → '주희진'
    digs   := substring(p.payer_key from '([0-9]+)$');                          --              → '861208'
    head   := regexp_replace(norm_key(regexp_replace(p.payer_name, '\s*[_/(,\-].*$', '')), '[0-9]+$', '');
                                                                                -- '전안나_대관' → '전안나', '고창기 / 6803' → '고창기'
    continue when base = '' and coalesce(head, '') = '';

    with c as (
      select a.id, a.created_at,
             ( case when digs is not null and length(digs) >= 4 and exists (
                      select 1 from attendees t
                       where t.application_id = a.id and t.status = 'active'
                         and (t.birth6 = digs or (length(digs) between 4 and 5 and t.birth6 like digs || '%')
                              or (length(digs) <= 8 and right(t.phone_key, length(digs)) = digs)))
                    then 2 else 0 end
             + case when a.payer_key in (p.payer_key, base, head) or a.org_key in (p.payer_key, base, head)
                         or regexp_replace(a.payer_key, '[0-9]+$', '') in (base, head)
                    then 1 else 0 end ) as score
        from applications a
       where a.paid_at is null
         and amount_due(a.id) = p.amount
         and (   a.payer_key in (p.payer_key, base, head)
              or regexp_replace(a.payer_key, '[0-9]+$', '') in (base, head)
              or a.org_key   in (p.payer_key, base, head)
              or (length(base) >= 5 and (a.org_key like base || '%' or a.payer_key like base || '%')))
    ), top as (
      select * from c where score = (select max(score) from c)
    )
    select case when (select count(*) from top) = 1 then (select id from top) end,
           (select count(*) from top) > 1
      into target, is_amb;

    if is_amb then ambiguous := ambiguous + 1; end if;

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

  return jsonb_build_object('inserted', inserted, 'skipped', skipped, 'matched', matched, 'ambiguous', ambiguous);
end $$;

-- 입금 확인 알림톡 적재 (자동·수기 매칭 공통)
create or replace function enqueue_paid_notice(p_application_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a applications%rowtype;
begin
  select * into a from applications where id = p_application_id;
  -- 카카오 알림톡 ② 참석 확정: 담당자(단체)·신청자(개인) 1건 (변수는 #{성함} 하나)
  insert into notifications (application_id, kind, to_phone, variables)
  values (a.id, 'paid', a.contact_phone, jsonb_build_object('#{성함}', a.contact_name));
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
-- 열 구성이 바뀌어도 재실행되도록 뷰는 지우고 다시 만든다 (데이터와 무관)
drop view if exists v_pending_receipts, v_attendees, v_applications;

create or replace view v_applications as
select
  a.id, a.kind,
  case a.kind when 'group' then '단체' else '개인' end as kind_label,
  a.org_name, a.contact_name, a.contact_phone, a.contact_email, a.payer_name,
  (select count(*) from attendees t where t.application_id = a.id and t.status='active') as headcount,
  amount_due(a.id) as amount_due,
  a.paid_amount, a.paid_at,
  case when amount_due(a.id) = 0 then '면제(평생회원)'
       when a.paid_at is not null then '입금확인' else '미입금' end as pay_status,
  a.receipt_sent_at, a.memo, a.created_at, a.updated_at,
  a.org_key,
  (select count(*) from attendees t where t.application_id = a.id and t.status='active' and t.lifetime) as lifetime_count
from applications a;

create or replace view v_attendees as
select
  t.id, t.application_id,
  case a.kind when 'group' then '단체' else '개인' end as kind_label,
  a.org_name, t.seq, t.name, t.position, t.phone, t.birth6, t.status,
  case when t.lifetime then '면제(평생회원)'
       when a.paid_at is not null then '입금확인' else '미입금' end as pay_status,
  t.created_at,
  a.org_key,
  t.lifetime
from attendees t join applications a on a.id = t.application_id
where t.status = 'active';

-- 영수증 보낼 대상: 입금 확인됐고 아직 안 보낸 건
create or replace view v_pending_receipts as
select a.id, a.kind, a.org_name, a.contact_name, a.contact_email, a.payer_name,
       a.paid_amount, a.paid_at,
       (select count(*) from attendees t where t.application_id=a.id and t.status='active') as headcount
from applications a
where a.paid_at is not null and a.receipt_sent_at is null and a.paid_amount > 0;

-- ------------------------------------------------------------
-- 10. 권한 — 공개 키(anon)로는 '상태 조회'와 '신청'만 가능하게
--   ※ PostgreSQL은 함수 실행 권한을 PUBLIC(모든 사용자)에게 기본으로 준다.
--     anon 만 빼면 PUBLIC 경로로 여전히 호출되므로 PUBLIC 에서도 회수해야 한다.
--   ※ 뷰는 기본적으로 '만든 사람 권한'으로 실행되어 RLS 를 우회한다.
--     security_invoker 로 바꾸고, 공개 역할의 조회 권한을 회수한다.
-- ------------------------------------------------------------

-- (1) 원본 테이블: RLS 에 더해 공개 역할의 직접 권한도 회수 (이중 잠금)
revoke all on table settings, applications, attendees, payments, notifications from public, anon, authenticated;
grant  all on table settings, applications, attendees, payments, notifications to service_role;
revoke all on all sequences in schema public from public, anon, authenticated;
grant  usage, select on all sequences in schema public to service_role;

-- (2) 뷰: 호출한 사람 권한으로 실행 + 공개 역할 조회 금지 (시트 동기화는 service_role)
alter view v_applications     set (security_invoker = true);
alter view v_attendees        set (security_invoker = true);
alter view v_pending_receipts set (security_invoker = true);
revoke all on table v_applications, v_attendees, v_pending_receipts from public, anon, authenticated;
grant select on table v_applications, v_attendees, v_pending_receipts to service_role;

-- (3) 함수: 공개용 2개만 열고, 나머지는 service_role 전용
revoke all on function public_status()                                              from public;
revoke all on function submit_application(text,text,text,text,text,text,text,jsonb) from public;
grant execute on function public_status()                                              to anon, authenticated, service_role;
grant execute on function submit_application(text,text,text,text,text,text,text,jsonb) to anon, authenticated, service_role;

revoke all on function import_payments(jsonb)                 from public, anon, authenticated;
revoke all on function match_payment_manual(bigint,uuid)      from public, anon, authenticated;
revoke all on function mark_receipt_sent(uuid)                from public, anon, authenticated;
revoke all on function enqueue_paid_notice(uuid)             from public, anon, authenticated;
revoke all on function mark_notification(bigint,text,text,text) from public, anon, authenticated;
revoke all on function amount_due(uuid)                       from public, anon, authenticated;
grant execute on function import_payments(jsonb), match_payment_manual(bigint,uuid), mark_receipt_sent(uuid),
                          enqueue_paid_notice(uuid), mark_notification(bigint,text,text,text), amount_due(uuid)
                       to service_role;

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
