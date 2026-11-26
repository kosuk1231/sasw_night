-- 추가 접수 점검 : 「추가접수_패치.sql」과 「추가접수_켜기.sql」을 실행한 뒤 Run.
-- 가짜 신청을 넣어 규칙을 시험한 다음 전부 되돌립니다. (데이터·설정 원상태, 알림톡 미발송)
-- 결과 표에서 ❌가 없으면 정상입니다.

create or replace function round2_check()
returns table(번호 int, 항목 text, 결과 text, 상세 text)
language plpgsql security definer set search_path = public as $$
declare
  no  int[]  := '{}';
  nm  text[] := '{}';
  ok  text[] := '{}';
  dt  text[] := '{}';
  s   settings%rowtype;
  st  jsonb;
  old_org text;
  r   jsonb;
  err text;
  rem_before int;
  rem_after  int;
  t_cnt int;
begin
  select * into s from settings where id = 1;
  st := public_status();

  no := no || 1; nm := nm || text '추가 접수 켜짐';
  ok := ok || case when s.round2_on then '✅' else '❌' end;
  dt := dt || format('오픈 %s / %s석 / 기관당 %s명', to_char(s.round2_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI'), s.round2_cap, s.round2_org_max);

  no := no || 2; nm := nm || text '페이지에 보이는 값';
  ok := ok || case when (st->>'round')::int = 2 and (st->>'group_max')::int = s.round2_org_max then '✅' else '❌' end;
  dt := dt || format('남은 %s석, 기관당 %s명, 마감 %s', st->>'remaining', st->>'group_max', st->>'closed');

  -- 1차 참여 기관 하나 고르기
  select a.org_name into old_org
    from applications a join attendees t on t.application_id = a.id
   where a.org_key is not null and t.status = 'active' and t.created_at < coalesce(s.round2_at, now())
   limit 1;

  begin
    -- 지금 오픈한 것처럼 시각을 1분 전으로 당겨 모의 실행
    update settings set round2_on = true, round2_at = now() - interval '1 minute', closed = false where id = 1;
    rem_before := (public_status()->>'remaining')::int;

    if old_org is not null then
      begin
        perform submit_application('group', old_org, '점검담당', '010-0000-9101', 'x@example.com', '점검', '',
          '[{"name":"점검일","phone":"010-0000-9101"}]'::jsonb);
        err := '통과됨(막혀야 함)';
      exception when others then err := sqlerrm; end;
      no := no || 3; nm := nm || text '1차 기관 단체 신청 차단';
      ok := ok || case when err like 'ORG_EXISTS|%' then '✅' else '❌' end; dt := dt || split_part(err, '|', 2);

      begin
        perform submit_application('individual', old_org, '점검이', '010-0000-9102', 'x@example.com', '점검이000101', '',
          '[{"name":"점검이","phone":"010-0000-9102","birth6":"000101"}]'::jsonb);
        err := '통과됨(막혀야 함)';
      exception when others then err := sqlerrm; end;
      no := no || 4; nm := nm || text '1차 기관 소속 개인 신청 차단';
      ok := ok || case when err like 'ORG_EXISTS|%' then '✅' else '❌' end; dt := dt || split_part(err, '|', 2);
    else
      no := no || 3; nm := nm || text '1차 기관 차단'; ok := ok || text 'ℹ️'; dt := dt || text '1차 신청 데이터가 없어 건너뜀';
    end if;

    begin
      r := submit_application('group', '점검신규복지관', '점검담당', '010-0000-9103', 'x@example.com', '점검신규복지관', '',
        '[{"name":"점검삼","phone":"010-0000-9103"},{"name":"점검사","phone":"010-0000-9104"},{"name":"점검오","phone":"010-0000-9105"}]'::jsonb);
      err := 'OK';
    exception when others then err := sqlerrm; end;
    no := no || 5; nm := nm || text '신규 기관 단체 3명 신청';
    ok := ok || case when err = 'OK' then '✅' else '❌' end; dt := dt || case when err = 'OK' then '청구 ' || (r->>'total_amount') || '원' else err end;

    begin
      perform submit_application('individual', '점검신규복지관', '점검육', '010-0000-9106', 'x@example.com', '점검육000101', '',
        '[{"name":"점검육","phone":"010-0000-9106","birth6":"000101"}]'::jsonb);
      err := '통과됨(막혀야 함)';
    exception when others then err := sqlerrm; end;
    no := no || 6; nm := nm || text '신규 기관 4번째(개인) 차단';
    ok := ok || case when err like 'GROUP_MAX|%' then '✅' else '❌' end; dt := dt || split_part(err, '|', 2);

    begin
      perform submit_application('individual', '무소속', '점검칠', '010-0000-9107', 'x@example.com', '점검칠000101', '',
        '[{"name":"점검칠","phone":"010-0000-9107","birth6":"000101"}]'::jsonb);
      err := 'OK';
    exception when others then err := sqlerrm; end;
    no := no || 7; nm := nm || text '무소속 개인 신청';
    ok := ok || case when err = 'OK' then '✅' else '❌' end; dt := dt || case when err = 'OK' then '통과' else err end;

    rem_after := (public_status()->>'remaining')::int;
    no := no || 8; nm := nm || text '남은 좌석 차감(추가 접수분만)';
    ok := ok || case when rem_before - rem_after = 4 then '✅' else '❌' end; dt := dt || format('%s석 → %s석', rem_before, rem_after);

    -- 정원 초과: 남은 자리를 1석으로 만든 뒤 2명 신청
    update settings set round2_cap = (select count(*) from attendees where status = 'active' and created_at >= now() - interval '1 minute') + 1 where id = 1;
    begin
      perform submit_application('group', '점검정원복지관', '점검담당', '010-0000-9108', 'x@example.com', '점검정원', '',
        '[{"name":"점검팔","phone":"010-0000-9108"},{"name":"점검구","phone":"010-0000-9109"}]'::jsonb);
      err := '통과됨(막혀야 함)';
    exception when others then err := sqlerrm; end;
    no := no || 9; nm := nm || text '30석 초과 차단';
    ok := ok || case when err like 'FULL|%' then '✅' else '❌' end; dt := dt || split_part(err, '|', 2);

    raise exception 'R2_ROLLBACK';
  exception when others then
    if sqlerrm <> 'R2_ROLLBACK' then
      no := no || 99; nm := nm || text '점검 중 오류'; ok := ok || text '❌'; dt := dt || sqlerrm;
    end if;
  end;

  select count(*) into t_cnt from attendees where name like '점검%' and phone like '010-0000-91%';
  no := no || 10; nm := nm || text '모의 데이터 되돌림';
  ok := ok || case when t_cnt = 0 and (select round2_at from settings where id = 1) is not distinct from s.round2_at then '✅' else '❌' end;
  dt := dt || text '설정·데이터 원상태, 알림톡 미발송';

  return query select no[i], nm[i], ok[i], dt[i] from generate_subscripts(no, 1) i;
end $$;

revoke all on function round2_check() from public, anon, authenticated;

select * from round2_check();
