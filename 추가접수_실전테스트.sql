-- 추가 접수 오픈 전 실전 테스트 (11/23 10:00 전에 실행)
-- 실제 서버에 테스트 신청 1건을 넣어 알림톡 ①, 시트 동기화, (이어서) 수기 입금확인 → 알림톡 ②, 영수증 메일까지 확인합니다.
--  · 신청 페이지는 그대로 '추가 접수 시작까지' 상태를 유지합니다(한 문장 안에서 잠깐 열고 바로 닫아서 다른 사람에게는 열리지 않음).
--  · 이 테스트 신청은 '오픈 전 신청'으로 기록되어 추가 접수 30석에서 빠지지 않습니다.
--  · 테스트가 끝나면 「추가접수_실전테스트_삭제.sql」로 지웁니다.
--
-- ✏️ 아래 4개 값만 테스트할 분 정보로 바꾸고 Run
--    (휴대전화는 1차에 신청하지 않은 번호여야 합니다 — 이미 신청된 번호면 '이미 신청' 오류가 납니다)
do $$
declare
  v_name  text := '고석우테스트';        -- 성함 (알림톡에 이 이름이 나갑니다)
  v_phone text := '010-0000-0000';       -- 알림톡 받을 휴대전화
  v_email text := 'kosuk1231@sasw.or.kr'; -- 영수증 받을 이메일
  v_birth text := '800101';              -- 생년월일 6자리(입금자명용)
  s settings%rowtype;
  r jsonb;
begin
  select * into s from settings where id = 1;
  if not s.round2_on then raise exception '추가 접수가 켜져 있지 않습니다(추가접수_켜기.sql 먼저)'; end if;
  if now() >= s.round2_at then raise exception '이미 추가 접수가 열렸습니다 — 이 테스트는 오픈 전에만 실행하세요'; end if;

  update settings set round2_at = now() - interval '1 minute' where id = 1;   -- 이 문장 안에서만 잠깐 열림
  r := submit_application('individual', '무소속', v_name, v_phone, v_email, v_name || v_birth, '[실전테스트]',
         jsonb_build_array(jsonb_build_object('name', v_name, 'phone', v_phone, 'birth6', v_birth)));
  update settings set round2_at = s.round2_at where id = 1;                  -- 원래 오픈 시각으로 되돌림

  raise notice '테스트 신청 완료: %', r;
end $$;

-- 결과 확인
select contact_name as 성함, contact_phone as 연락처, amount_due as 청구액, pay_status as 입금상태, memo as 비고, created_at
  from v_applications where memo = '[실전테스트]';
select kind as 알림종류, to_phone as 수신번호, status as 발송상태, created_at
  from notifications where application_id in (select id from applications where memo = '[실전테스트]')
 order by created_at;
select round2_at as 추가접수_오픈시각 from settings;           -- 2026-11-23 01:00:00+00 (=10:00) 이어야 함
select public_status()->>'remaining' as 남은좌석, public_status()->>'open_at' as 오픈;  -- 30 / 오픈 전
