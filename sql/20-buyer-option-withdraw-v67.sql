-- v67: allow a buyer with their valid private quote link to withdraw a pending option change.
-- This does not update the quote item, payment, freight, purchase round or order status.
alter table gq_private.gq_option_change_requests_v61
  drop constraint gq_option_change_requests_v61_status_check;
alter table gq_private.gq_option_change_requests_v61
  add constraint gq_option_change_requests_v61_status_check
  check (status in ('pending','approved','rejected','withdrawn'));

create or replace function public.gq_withdraw_item_option_request_v67(
  p_quote_id uuid,
  p_lookup_token uuid,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request gq_private.gq_option_change_requests_v61%rowtype;
begin
  if not exists (
    select 1 from public.gq_quotes q
    where q.id=p_quote_id and q.lookup_token=p_lookup_token
  ) then
    raise exception '주문조회 링크가 올바르지 않아요.' using errcode='42501';
  end if;

  select * into v_request
  from gq_private.gq_option_change_requests_v61 r
  where r.id=p_request_id and r.quote_id=p_quote_id
  for update;

  if not found or v_request.status <> 'pending' then
    raise exception '이미 처리됐거나 취소된 옵션 변경 요청이에요. 새로고침 후 확인해 주세요.'
      using errcode='22023';
  end if;

  update gq_private.gq_option_change_requests_v61
  set status='withdrawn', decided_at=clock_timestamp(),
      decision_note='구매자가 요청 취소'
  where id=v_request.id;

  return jsonb_build_object('withdrawn',true,'request_id',v_request.id);
end;
$$;

revoke all on function public.gq_withdraw_item_option_request_v67(uuid,uuid,uuid) from public;
grant execute on function public.gq_withdraw_item_option_request_v67(uuid,uuid,uuid) to anon, authenticated;
