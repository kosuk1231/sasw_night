-- 2026 서울사회복지사의 밤 · 수기 입금확인 패치
-- 자동 매칭이 못 잡은 입금(입금자명이 다르거나, 나눠 내거나, 단체+개인을 한 번에 낸 경우)을
-- 사람이 확인해서 신청 건에 연결한다. 연결되면 자동 매칭과 똑같이
--   · 신청 건이 '입금확인'으로 바뀌고 (시트 동기화에 반영)
--   · 알림톡 ② 참석 확정이 한 번 나가고 (이미 입금확인된 건이면 다시 안 나감)
--   · 「③ 영수증 발송」 대상이 된다.
-- 기존 데이터·권한·추가 접수 설정은 바뀌지 않습니다. Supabase SQL Editor에 통째로 붙여넣고 Run.

-- 1) 아직 아무 신청에도 연결되지 않은 입금 목록 (시트 「수기입금처리」가 읽음)
drop view if exists v_unmatched_payments;
create view v_unmatched_payments as
select id, paid_at, payer_name, amount, raw, created_at
  from payments
 where application_id is null
 order by paid_at nulls last, id;
alter view v_unmatched_payments set (security_invoker = true);
revoke all on table v_unmatched_payments from public, anon, authenticated;
grant select on table v_unmatched_payments to service_role;

-- 2) 수기 입금확인
--   p_payment_id 있음 : 그 입금을 신청에 연결. p_amount 가 입금액보다 작으면 그만큼만 떼어 연결하고
--                       나머지는 미연결로 남긴다 (예: 6만 원을 단체 4만 + 개인 2만으로 나눔)
--   p_payment_id 없음 : 통장 외 입금(현금 등)을 p_amount 로 기록해 연결
create or replace function manual_confirm(
  p_application_id uuid,
  p_amount         int,
  p_payment_id     bigint default null,
  p_note           text   default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a        applications%rowtype;
  p        payments%rowtype;
  pid      bigint;
  was_paid boolean;
  due      int;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'AMOUNT|연결할 금액을 확인해 주세요.';
  end if;

  select * into a from applications where id = p_application_id for update;
  if not found then raise exception 'NO_APP|신청 건을 찾을 수 없습니다.'; end if;
  was_paid := a.paid_at is not null;

  if p_payment_id is not null then
    select * into p from payments where id = p_payment_id for update;
    if not found then raise exception 'NO_PAY|입금 건(%)을 찾을 수 없습니다.', p_payment_id; end if;
    if p.application_id is not null then
      raise exception 'ALREADY|이미 다른 신청에 연결된 입금입니다.';
    end if;
    if p_amount > p.amount then
      raise exception 'OVER|이 입금은 %원이라 그보다 큰 금액을 연결할 수 없습니다.', to_char(p.amount, 'FM999,999,999');
    end if;

    if p_amount = p.amount then
      update payments set application_id = a.id, match_type = 'manual', matched_at = now()
       where id = p.id;
      pid := p.id;
    else
      -- 일부만 떼어 연결: 원래 줄은 금액을 줄여 미연결로 남김(은행 내역 재업로드 시 중복 방지 지문은 그대로)
      update payments set amount = amount - p_amount where id = p.id;
      insert into payments (paid_at, payer_name, amount, fingerprint, raw, application_id, match_type, matched_at)
      values (p.paid_at, p.payer_name, p_amount, p.fingerprint || '#split#' || gen_random_uuid(),
              p.raw, a.id, 'manual', now())
      returning id into pid;
    end if;
  else
    insert into payments (paid_at, payer_name, amount, fingerprint, raw, application_id, match_type, matched_at)
    values (now(), '수기확인', p_amount, 'manual#' || gen_random_uuid(),
            coalesce(p_note, ''), a.id, 'manual', now())
    returning id into pid;
  end if;

  update applications
     set paid_amount = paid_amount + p_amount,
         paid_at     = coalesce(paid_at, p.paid_at, now()),
         updated_at  = now()
   where id = a.id;

  -- 알림톡 ② 참석 확정 — 이 신청이 처음 입금확인될 때만
  if not was_paid then perform enqueue_paid_notice(a.id); end if;

  due := amount_due(a.id);
  return jsonb_build_object(
    'ok', true,
    'payment_id',  pid,
    'name',        case when a.kind = 'group' then a.org_name else a.contact_name end,
    'kind',        a.kind,
    'amount_due',  due,
    'paid_amount', a.paid_amount + p_amount,
    'first_paid',  not was_paid
  );
end $$;

revoke all on function manual_confirm(uuid, int, bigint, text) from public, anon, authenticated;
grant execute on function manual_confirm(uuid, int, bigint, text) to service_role;
