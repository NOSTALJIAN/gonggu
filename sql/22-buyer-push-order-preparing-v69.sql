-- Notify subscribed buyers when a confirmed order enters 'preparing'.
-- A transaction-scoped key deduplicates bundled orders and allows re-entry after rollback.
CREATE OR REPLACE FUNCTION public.gq_enqueue_buyer_push()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare label text; event_kind text; group_id uuid; v_event_key text;
begin
 if new.customer_key is null or new.status='cancelled' then return new; end if;
 if new.status is distinct from old.status then
   if new.status='quoted' then label:='견적이 도착했어요';event_kind:='status_quoted';
   elsif new.status='confirmed' then label:='주문이 확정됐어요';event_kind:='status_confirmed';
   else return new; end if;
 elsif new.workflow_stage is distinct from old.workflow_stage and new.status='confirmed' then
   case new.workflow_stage
    when 'preparing' then label:='주문하신 상품을 준비 중이에요.';event_kind:='preparing';
    when 'pickup_ready' then label:='상품 픽업 준비가 완료됐어요';event_kind:='pickup_ready';
    when 'shipped' then label:='상품이 배송 중이에요';event_kind:='shipped';
    when 'completed' then label:='주문이 완료됐어요';event_kind:='completed';
    when 'soldout_closed' then label:='품절 및 환불 처리를 확인해 주세요';event_kind:='soldout_closed';
    else return new;
   end case;
 else return new; end if;
 group_id:=coalesce(new.bundle_parent_id,new.id);
 v_event_key:=group_id::text||':'||event_kind||':'||new.customer_key::text;
 -- Re-entering 'preparing' is a new transition, but grouped orders in one
 -- transaction should receive only one notification.
 if event_kind='preparing' then
   v_event_key:=v_event_key||':'||to_char(transaction_timestamp(),'YYYYMMDDHH24MISSUS');
 end if;
 insert into public.gq_push_outbox(event_key,customer_key,quote_id,title,message)
 values(v_event_key,new.customer_key,new.id,'미니예나',
   case when event_kind='preparing' then label||' 미니예나에서 진행 상황을 확인해 주세요.'
        else label||' 미니예나에서 주문 상태를 확인해 주세요.' end)
 on conflict (event_key) do nothing;
 return new;
end $function$;
