-- 2026 서울사회복지사의 밤 · 추가 접수 패치
-- 추가 접수 규칙
--   · 총 30석(1차 신청 450명과 별도로 셈)
--   · 1차 사전신청에 참여한 기관은 신청 불가 → 신규 기관만
--   · 신규 기관은 기관당 3명(단체 + 개인 소속 합산)
--   · 소속이 없는 개인(없음·무소속)은 기관 제한 없이 신청 가능
-- 이 파일은 기능만 추가합니다. 실제로 켜는 것은 아래 「추가접수_켜기.sql」입니다.
-- 기존 데이터·권한·알림톡 설정은 바뀌지 않습니다.
-- Supabase SQL Editor에 통째로 붙여넣고 Run.

-- 1) 설정 칸 추가 (이미 있으면 건너뜀)
alter table settings add column if not exists round2_on      boolean     not null default false;
alter table settings add column if not exists round2_at      timestamptz;
alter table settings add column if not exists round2_cap     int         not null default 30;
alter table settings add column if not exists round2_org_max int         not null default 3;

-- 2) 공개 상태 — 추가 접수 중이면 추가 접수 기준으로 보여 준다
create or replace function public_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare s settings%rowtype; used int; used2 int;
begin
  select * into s from settings where id = 1;
  select count(*) into used from attendees where status = 'active';

  if s.round2_on and s.round2_at is not null then
    select count(*) into used2 from attendees
     where status = 'active' and created_at >= s.round2_at;
    return jsonb_build_object(
      'server_now',  now(),
      'round',       2,
      'open_at',     s.round2_at,
      'remaining',   greatest(s.round2_cap - used2, 0),
      'nearly_full', (s.round2_cap - used2) <= 5,
      'group_max',   s.round2_org_max,
      'fee',         s.fee,
      'closed',      s.closed or (s.close_at is not null and now() > s.close_at) or used2 >= s.round2_cap,
      'bank',        jsonb_build_object('name', s.bank_name, 'account', s.bank_account, 'holder', s.bank_holder)
    );
  end if;

  return jsonb_build_object(
    'server_now',  now(),
    'round',       1,
    'open_at',     s.open_at,
    'remaining',   greatest(s.capacity - used, 0),
    'nearly_full', (s.capacity - used) <= 30,
    'group_max',   s.group_max,
    'fee',         s.fee,
    'closed',      s.closed or (s.close_at is not null and now() > s.close_at) or used >= s.capacity,
    'bank',        jsonb_build_object('name', s.bank_name, 'account', s.bank_account, 'holder', s.bank_holder)
  );
end $$;

-- 3) 신청 접수 — 긴급 패치 버전에 추가 접수 규칙만 더함
create or replace function submit_application(
  p_kind          text,
  p_org_name      text,
  p_contact_name  text,
  p_contact_phone text,
  p_contact_email text,
  p_payer_name    text,
  p_memo          text,
  p_attendees     jsonb      -- [{name, position, phone, birth6, lifetime}, ...]
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s     settings%rowtype;
  app   applications%rowtype;
  n     int;
  used  int;
  cur   int := 0;
  org_total int := 0;
  old_cnt   int := 0;
  k     text;
  i     int := 0;
  rec   jsonb;
  dup   text;
  r2    boolean;
  gmax  int;
  cap_left int;
begin
  select * into s from settings where id = 1;
  r2   := s.round2_on and s.round2_at is not null;
  gmax := case when r2 then s.round2_org_max else s.group_max end;

  if s.closed or (s.close_at is not null and now() > s.close_at) then
    raise exception 'CLOSED|접수가 마감되었습니다.';
  end if;
  if now() < (case when r2 then s.round2_at else s.open_at end) then
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

  if r2 then
    select count(*) into used from attendees where status = 'active' and created_at >= s.round2_at;
    cap_left := s.round2_cap - used;
  else
    select count(*) into used from attendees where status = 'active';
    cap_left := s.capacity - used;
  end if;
  if n > cap_left then
    raise exception 'FULL|남은 자리가 신청 인원보다 적습니다. 인원을 줄여 다시 시도해 주세요.';
  end if;

  -- 같은 신청서 안에서 참가자끼리 번호가 겹치는지
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

  -- 기관 키: 단체는 기관명, 개인은 소속
  k := nullif(norm_key(p_org_name), '');
  if k in ('없음','없슴','무소속','소속없음','해당없음','na','none') then k := null; end if;

  -- ── 추가 접수: 1차에 참여한 기관은 신청할 수 없다 ──
  if r2 and k is not null then
    select count(*) into old_cnt
      from attendees t join applications a on a.id = t.application_id
     where a.org_key = k and t.status = 'active' and t.created_at < s.round2_at;
    if old_cnt > 0 then
      raise exception 'ORG_EXISTS|「%」은(는) 1차 사전신청에 참여한 기관이라 추가 접수 대상이 아닙니다. 추가 접수는 1차에 신청하지 않은 기관만 신청할 수 있습니다.',
        btrim(p_org_name);
    end if;
  end if;

  if p_kind = 'group' then
    if k is null then
      raise exception 'NO_ORG|기관·단체명을 입력해 주세요.';
    end if;

    select * into app from applications where kind = 'group' and org_key = k for update;

    select count(*) into org_total
      from attendees t join applications a on a.id = t.application_id
     where a.org_key = k and t.status = 'active';
    if org_total + n > gmax then
      raise exception 'GROUP_MAX|「%」은(는) 이미 %명 신청되어 있어 %명까지 추가할 수 있습니다. (기관당 최대 %명, 개인 신청 포함)',
        btrim(p_org_name), org_total, greatest(gmax - org_total, 0), gmax;
    end if;

    if app.id is not null then
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
    if k is not null then
      select count(*) into org_total
        from attendees t join applications a on a.id = t.application_id
       where a.org_key = k and t.status = 'active';
      if org_total + n > gmax then
        raise exception 'GROUP_MAX|「%」 소속은 이미 %명이 신청되어 있습니다. 기관당 최대 %명까지만 참석할 수 있습니다.',
          btrim(p_org_name), org_total, gmax;
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

  -- 카카오 알림톡 ① 신청 접수: 참가자 전원
  insert into notifications (application_id, kind, to_phone, variables)
  select app.id, 'applied', btrim(e->>'phone'),
         jsonb_build_object('#{성함}', btrim(e->>'name'))
  from jsonb_array_elements(p_attendees) e;

  if p_kind = 'group' and not exists (
       select 1 from jsonb_array_elements(p_attendees) e
        where digits_only(e->>'phone') = digits_only(p_contact_phone)) then
    insert into notifications (application_id, kind, to_phone, variables)
    values (app.id, 'applied', p_contact_phone, jsonb_build_object('#{성함}', p_contact_name));
  end if;

  if amount_due(app.id) = 0 then
    update applications set paid_at = coalesce(paid_at, now()), updated_at = now() where id = app.id;
  end if;

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
    'remaining',     greatest(cap_left - n, 0)
  );
exception
  when unique_violation then
    raise exception 'DUP|이미 신청된 연락처가 포함되어 있습니다. 참가자마다 본인 휴대전화 번호를 입력했는지 확인해 주세요.';
end $$;

-- 4) 권한 (기존과 같게 유지)
revoke all on function public_status() from public;
revoke all on function submit_application(text,text,text,text,text,text,text,jsonb) from public;
grant execute on function public_status() to anon, authenticated, service_role;
grant execute on function submit_application(text,text,text,text,text,text,text,jsonb) to anon, authenticated, service_role;
