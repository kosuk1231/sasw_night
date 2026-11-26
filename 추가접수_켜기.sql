-- 추가 접수 켜기 : 11월 23일(월) 10:00 오픈, 30석, 신규 기관 기관당 3명
-- 실행하는 순간부터 신청 페이지가 '추가 접수 오픈 예정' 카운트다운으로 바뀝니다.
update settings set
  round2_on      = true,
  round2_at      = '2026-11-23 10:00:00+09',
  round2_cap     = 30,
  round2_org_max = 3,
  closed         = false
where id = 1;

select round2_on, round2_at, round2_cap, round2_org_max, closed from settings;
select public_status();
