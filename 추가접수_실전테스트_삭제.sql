-- 실전 테스트 신청 지우기 — 비고가 '[실전테스트]'인 신청만 지웁니다(실제 신청은 건드리지 않음)
delete from payments
 where application_id in (select id from applications where memo = '[실전테스트]');
delete from applications where memo = '[실전테스트]';      -- 참가자·알림 기록도 함께 지워짐

select count(*) as 남은_테스트신청 from applications where memo = '[실전테스트]';   -- 0
select public_status()->>'remaining' as 남은좌석, public_status()->>'open_at' as 오픈;
