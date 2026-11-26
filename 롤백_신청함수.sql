-- 긴급 패치를 되돌리는 SQL (문제가 생겼을 때만 사용)
-- 신청 함수를 패치 이전 상태로 되돌립니다. 데이터·권한·설정은 그대로입니다.

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
end $$;
