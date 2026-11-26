-- 2026 서울사회복지사의 밤 · 최종 참석자 사전 설문 + 수어통역 수요 조사 패치 (v2)
-- 기존 신청·입금·추가 접수 데이터와 함수는 바뀌지 않습니다. Supabase SQL Editor에 통째로 붙여넣고 Run.
-- 이전 버전(v1)을 이미 실행했어도 이 파일을 그대로 다시 Run 하면 됩니다.
--
--   · 알림톡은 입금 확인된 참석자에게만 가므로 페이지에서 별도 본인 확인을 하지 않음
--     → 성함(필수)·소속(선택)만 적고 응답. 같은 성함+소속으로 다시 내면 기존 응답을 고침
--   · 수어통역이 '필요'하면 좌석 안내 연락용 휴대전화만 추가로 받음
--   · 시트에는 참석 확정자 명단과 성함이 맞는지(명단확인)를 함께 표시
--   · 아름다운사회복지사상 수상자께 한마디(cheer_msg) 포함
--   · 응답 마감 : settings.survey_close_at (기본 12월 2일(수) 18시)
--   · 알림톡 ③ 사전 설문 안내 : enqueue_survey_test() 로 내 번호에 먼저, enqueue_survey_notice() 로 전체 발송

-- 1) 설정 : 설문 마감 시각
alter table settings add column if not exists survey_close_at timestamptz default '2026-12-02 18:00:00+09';
update settings set survey_close_at = coalesce(survey_close_at, '2026-12-02 18:00:00+09') where id = 1;

-- 2) 응답 테이블
--    v1(참석자 번호로 묶는 구조)이 남아 있으면 정리 : 응답이 0건이면 지우고, 있으면 surveys_v1 로 이름만 바꿔 보관
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'surveys' and column_name = 'attendee_id') then
    drop view if exists v_surveys;
    if (select count(*) from surveys) = 0 then
      drop table surveys;
    else
      alter table surveys rename to surveys_v1;
      raise notice 'v1 응답이 있어 surveys_v1 으로 보관했습니다.';
    end if;
  end if;
end $$;

create table if not exists surveys (
  id             uuid primary key default gen_random_uuid(),
  resp_key       text not null unique,        -- 성함+소속(공백·대소문자 무시) : 같은 사람 다시 제출 시 수정
  resp_name      text not null,               -- 성함
  resp_org       text,                        -- 소속(선택)
  one_word       text not null,               -- 내 2026년을 한 단어로
  hard_moment    text,                        -- 올해 가장 힘들었던 순간
  proud_moment   text,                        -- 올해 가장 보람 있던 순간
  again_sw       text not null check (again_sw in ('물론이죠','고민해 볼래요','다른 길도 궁금해요')),
  again_reason   text,                        -- 그렇게 답한 이유 한 줄
  song_comfort   text,                        -- 올해 위로가 된 노래
  song_colleague text,                        -- 동료에게 들려주고 싶은 노래
  song_commute   text,                        -- 출퇴근길 노래
  song_story     text,                        -- 신청곡 사연
  cheer_msg      text,                        -- 아름다운사회복지사상 수상자(이정미 사회복지사, 한국여성의집)께 한마디
  share_ok       text not null check (share_ok in ('이름·소속 공개','익명으로만','소개하지 않음')),
  sign_need      text not null check (sign_need in ('필요','필요 없음')),
  sign_phone     text,                        -- 수어통역 필요 시 좌석 안내 연락처
  sign_note      text,                        -- 수어통역 관련 요청(좌석 등)
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
alter table surveys enable row level security;   -- 정책 없음 = 익명 키로 직접 접근 불가 (아래 함수로만)
revoke all on table surveys from public, anon, authenticated;
grant all on table surveys to service_role;

-- 3) 알림톡 종류에 'survey' 추가
alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check check (kind in ('applied','paid','survey'));

-- 4) 응답 제출 (익명 키로 호출)
drop function if exists submit_survey(text, text, jsonb);
create function submit_survey(p_name text, p_org text, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s      settings%rowtype;
  v      jsonb := coalesce(p_answers, '{}'::jsonb);
  f_name text := left(btrim(coalesce(p_name, '')), 30);
  f_org  text := nullif(left(btrim(coalesce(p_org, '')), 60), '');
  f_key  text;
  f_one  text := btrim(coalesce(v->>'one_word', ''));
  f_sign text := v->>'sign_need';
  f_tel  text := btrim(coalesce(v->>'sign_phone', ''));
  existed boolean;
begin
  select * into s from settings where id = 1;
  if s.survey_close_at is not null and now() > s.survey_close_at then
    raise exception 'SURVEY_CLOSED|사전 설문이 마감되었습니다. 참여해 주셔서 감사합니다.';
  end if;

  if f_name = '' then raise exception 'INPUT|성함을 입력해 주세요.'; end if;
  if f_one = '' then raise exception 'INPUT|「내 2026년을 한 단어로」를 적어 주세요.'; end if;
  if (v->>'again_sw') is null or (v->>'again_sw') not in ('물론이죠','고민해 볼래요','다른 길도 궁금해요') then
    raise exception 'INPUT|「다시 태어나도 사회복지사?」에 답해 주세요.';
  end if;
  if (v->>'share_ok') is null or (v->>'share_ok') not in ('이름·소속 공개','익명으로만','소개하지 않음') then
    raise exception 'INPUT|현장 소개 방법을 골라 주세요.';
  end if;
  if f_sign is null or f_sign not in ('필요','필요 없음') then
    raise exception 'INPUT|수어통역이 필요한지 골라 주세요.';
  end if;
  if f_sign = '필요' then
    if length(digits_only(f_tel)) < 10 then
      raise exception 'INPUT|좌석 안내를 위해 연락받으실 휴대전화 번호를 적어 주세요.';
    end if;
    if coalesce((v->>'sign_consent')::boolean, false) is not true then
      raise exception 'INPUT|수어통역 지원 준비를 위한 정보 수집에 동의해 주세요.';
    end if;
  end if;

  f_key := regexp_replace(lower(f_name), '\s', '', 'g') || '|' || coalesce(norm_key(f_org), '');
  existed := exists (select 1 from surveys where resp_key = f_key);

  insert into surveys (resp_key, resp_name, resp_org, one_word, hard_moment, proud_moment, again_sw, again_reason,
                       song_comfort, song_colleague, song_commute, song_story, cheer_msg,
                       share_ok, sign_need, sign_phone, sign_note)
  values (f_key, f_name, f_org,
          left(f_one, 20),
          nullif(left(btrim(coalesce(v->>'hard_moment','')), 600), ''),
          nullif(left(btrim(coalesce(v->>'proud_moment','')), 600), ''),
          v->>'again_sw',
          nullif(left(btrim(coalesce(v->>'again_reason','')), 200), ''),
          nullif(left(btrim(coalesce(v->>'song_comfort','')), 120), ''),
          nullif(left(btrim(coalesce(v->>'song_colleague','')), 120), ''),
          nullif(left(btrim(coalesce(v->>'song_commute','')), 120), ''),
          nullif(left(btrim(coalesce(v->>'song_story','')), 600), ''),
          nullif(left(btrim(coalesce(v->>'cheer_msg','')), 300), ''),
          v->>'share_ok',
          f_sign,
          case when f_sign = '필요' then left(f_tel, 20) end,
          case when f_sign = '필요' then nullif(left(btrim(coalesce(v->>'sign_note','')), 300), '') end)
  on conflict (resp_key) do update set
    resp_name = excluded.resp_name, resp_org = excluded.resp_org,
    one_word = excluded.one_word, hard_moment = excluded.hard_moment, proud_moment = excluded.proud_moment,
    again_sw = excluded.again_sw, again_reason = excluded.again_reason,
    song_comfort = excluded.song_comfort, song_colleague = excluded.song_colleague,
    song_commute = excluded.song_commute, song_story = excluded.song_story, cheer_msg = excluded.cheer_msg,
    share_ok = excluded.share_ok, sign_need = excluded.sign_need,
    sign_phone = excluded.sign_phone, sign_note = excluded.sign_note,
    updated_at = now();

  return jsonb_build_object('ok', true, 'name', f_name, 'updated', existed);
end $$;
revoke all on function submit_survey(text, text, jsonb) from public;
grant execute on function submit_survey(text, text, jsonb) to anon, authenticated, service_role;

-- 5) 시트용 보기 (service_role 전용)
--    명단확인 : 입금 확인된 참석자 중 같은 성함이 몇 명인지 (O / 동명이인 n명 / 명단에 없음)
drop view if exists v_surveys;
create view v_surveys as
select sv.updated_at, sv.created_at,
       sv.resp_name as name, coalesce(sv.resp_org, '') as org_name,
       case m.n when 0 then '명단에 없음' when 1 then 'O' else '동명이인 ' || m.n || '명' end as roster,
       sv.one_word, sv.hard_moment, sv.proud_moment, sv.again_sw, sv.again_reason,
       sv.song_comfort, sv.song_colleague, sv.song_commute, sv.song_story, sv.cheer_msg,
       sv.share_ok, sv.sign_need, sv.sign_phone, sv.sign_note,
       sv.id
  from surveys sv
  cross join lateral (
    select count(*) as n from attendees t join applications a on a.id = t.application_id
     where t.status = 'active' and a.paid_at is not null
       and regexp_replace(lower(t.name), '\s', '', 'g') = regexp_replace(lower(sv.resp_name), '\s', '', 'g')
  ) m;
alter view v_surveys set (security_invoker = true);
revoke all on table v_surveys from public, anon, authenticated;
grant select on table v_surveys to service_role;

-- 6) 알림톡 ③ 사전 설문 안내
--   6-1) 테스트 : 내 번호로만 1건 (명단에 없는 번호여도 됨)
create or replace function enqueue_survey_test(p_phone text, p_name text)
returns int language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (application_id, kind, to_phone, variables)
  values (null, 'survey', btrim(p_phone), jsonb_build_object('#{성함}', btrim(p_name)));
  return 1;
end $$;

--   6-2) 전체 : 참석 확정자(입금 확인·면제) 전원, 참가자 1명당 1건.
--        이미 ③을 받은 번호는 건너뛰므로 여러 번 실행해도 중복 발송되지 않음
--        (늦게 입금 확인된 분에게 보내려면 다시 실행하면 그분들만 나감)
create or replace function enqueue_survey_notice()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into notifications (application_id, kind, to_phone, variables)
  select t.application_id, 'survey', t.phone, jsonb_build_object('#{성함}', t.name)
    from attendees t join applications a on a.id = t.application_id
   where t.status = 'active' and a.paid_at is not null
     and not exists (select 1 from notifications n
                      where n.kind = 'survey' and n.application_id is not null
                        and digits_only(n.to_phone) = t.phone_key
                        and n.status in ('pending','sent'));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function enqueue_survey_test(text, text) from public, anon, authenticated;
revoke all on function enqueue_survey_notice() from public, anon, authenticated;
grant execute on function enqueue_survey_test(text, text) to service_role;
grant execute on function enqueue_survey_notice() to service_role;

-- 확인
select survey_close_at as 설문마감 from settings;
select count(*) filter (where a.paid_at is not null) as 설문대상_참석확정,
       count(*) as 전체_유효참가자
  from attendees t join applications a on a.id = t.application_id where t.status = 'active';
