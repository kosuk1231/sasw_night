-- 추가 접수 끄기(되돌리기) : 1차 기준(450석, 기관당 10명)으로 돌아갑니다.
-- 추가 접수로 들어온 신청 데이터는 지워지지 않습니다.
update settings set round2_on = false where id = 1;
select public_status();
