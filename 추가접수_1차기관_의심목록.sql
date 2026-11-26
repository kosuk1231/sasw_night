-- 추가 접수 신청 중 '1차 참여 기관일 수 있는' 건 찾기 (조회만 함 — 아무것도 바꾸지 않음)
-- 서버는 기관명이 같으면(띄어쓰기·(사)·사회복지법인 표기 차이 포함) 자동으로 막습니다.
-- 이 목록은 그 자동 차단을 피해 간 경우 — 약칭·다른 표기(예: 행복종합사회복지관 ↔ 행복복지관),
-- 무소속으로 적은 개인, 1차 때와 같은 담당자·이메일 도메인 — 를 사람이 확인하기 위한 것입니다.
-- 접수 중·마감 후 아무 때나 Supabase SQL Editor에서 Run.

with s as (select round2_at from settings where id = 1),
-- 기관명에서 흔한 꼬리말을 뗀 '핵심 이름'
core as (
  select a.id, a.kind, a.org_name, a.contact_name, a.contact_phone, a.contact_email, a.created_at,
         regexp_replace(coalesce(a.org_key,''),
           '(종합사회복지관|사회복지관|노인복지관|장애인복지관|종합복지관|복지관|지역아동센터|아동센터|노인요양원|요양원|복지센터|센터|복지재단|재단|협회|법인|시설|의집|어린이집)', '', 'g') as k
    from applications a
),
r1 as (   -- 1차 신청(오픈 전 등록, 참석자 1명 이상 유효)
  select distinct c.* from core c join attendees t on t.application_id = c.id, s
   where t.status = 'active' and t.created_at < s.round2_at
),
r2 as (   -- 추가 접수 신청
  select distinct c.* from core c join attendees t on t.application_id = c.id, s
   where t.status = 'active' and t.created_at >= s.round2_at
),
hit as (
  -- ① 핵심 이름이 같거나 한쪽이 다른 쪽을 포함
  select r2.id, '기관명 유사: 1차 「' || r1.org_name || '」' as 사유
    from r2 join r1 on length(r2.k) >= 2 and length(r1.k) >= 2
                   and (r2.k = r1.k or strpos(r2.k, r1.k) > 0 or strpos(r1.k, r2.k) > 0)
  union all
  -- ② 신청 담당자 휴대전화가 1차 담당자와 같음
  select r2.id, '담당자 번호가 1차 「' || coalesce(r1.org_name, r1.contact_name) || '」 담당자와 같음'
    from r2 join r1 on digits_only(r2.contact_phone) = digits_only(r1.contact_phone)
  union all
  -- ③ 기관 이메일 도메인이 1차 신청과 같음 (포털 메일 제외)
  select r2.id, '이메일 도메인이 1차 「' || coalesce(r1.org_name, r1.contact_name) || '」와 같음 (@' || split_part(r1.contact_email,'@',2) || ')'
    from r2 join r1 on lower(split_part(r2.contact_email,'@',2)) = lower(split_part(r1.contact_email,'@',2))
   where lower(split_part(r2.contact_email,'@',2)) not in
         ('', 'gmail.com','naver.com','hanmail.net','daum.net','kakao.com','nate.com','hotmail.com',
          'outlook.com','icloud.com','me.com','yahoo.com','yahoo.co.kr','korea.kr')
  union all
  -- ④ 소속을 '없음'으로 적은 개인 (소속 확인 필요)
  select r2.id, '무소속 개인 — 실제 소속 확인' from r2 where r2.kind = 'individual' and r2.k = ''
)
select case r2.kind when 'group' then '단체' else '개인' end as 구분,
       coalesce(r2.org_name, '(없음)') as 신청기관,
       r2.contact_name as 담당자,
       (select count(*) from attendees t where t.application_id = r2.id and t.status = 'active') as 인원,
       to_char(r2.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') as 신청시각,
       string_agg(distinct h.사유, ' / ') as 확인할_이유,
       r2.id as 신청ID
  from hit h join r2 on r2.id = h.id
 group by r2.id, r2.kind, r2.org_name, r2.contact_name, r2.created_at
 order by r2.created_at;

-- ▶ 확인 결과 1차 기관이 맞으면 그 신청을 취소합니다(자리가 다시 열려 다음 신청자가 들어올 수 있음).
--   아래 '여기에_신청ID'를 위 목록의 신청ID로 바꿔 실행. 입금 전이면 그대로, 입금했다면 환불 안내 필요.
-- update attendees set status = 'cancelled' where application_id = '여기에_신청ID';
