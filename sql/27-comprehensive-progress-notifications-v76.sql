-- v76: verified per-quote push subscriptions, across both MINIYENA web origins.
CREATE TABLE IF NOT EXISTS gq_private.gq_quote_push_subscribers_v76(
 quote_id uuid NOT NULL REFERENCES public.gq_quotes(id) ON DELETE CASCADE,
 customer_key uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(quote_id,customer_key)
);
ALTER TABLE gq_private.gq_quote_push_subscribers_v76 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE gq_private.gq_quote_push_subscribers_v76 FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.gq_link_quote_push_v76(
 p_quote_id uuid,p_lookup_token uuid,p_customer_key uuid
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
 IF p_quote_id IS NULL OR p_lookup_token IS NULL OR p_customer_key IS NULL
    OR NOT EXISTS(SELECT 1 FROM public.gq_quotes
        WHERE id=p_quote_id AND lookup_token=p_lookup_token)
 THEN RAISE EXCEPTION '올바른 주문조회 링크를 열어 주세요.'; END IF;
 -- A token permits reading this one quote only, never subscribing to other quotes.
 PERFORM pg_advisory_xact_lock(hashtextextended('gq_push_bind:'||p_quote_id::text,0));
 IF NOT EXISTS(SELECT 1 FROM gq_private.gq_quote_push_subscribers_v76
               WHERE quote_id=p_quote_id AND customer_key=p_customer_key)
    AND (SELECT count(*) FROM gq_private.gq_quote_push_subscribers_v76 WHERE quote_id=p_quote_id)>=8
 THEN RAISE EXCEPTION '이 주문의 알림 등록 기기 수 제한에 도달했어요.'; END IF;
 INSERT INTO gq_private.gq_quote_push_subscribers_v76(quote_id,customer_key)
 VALUES(p_quote_id,p_customer_key) ON CONFLICT DO NOTHING;
 RETURN true;
END;
$function$;
REVOKE ALL ON FUNCTION public.gq_link_quote_push_v76(uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gq_link_quote_push_v76(uuid,uuid,uuid) TO anon,authenticated,service_role;

-- Allow previous orders, whose primary key belongs to a different domain,
-- to also notify a subscriber who explicitly opened that order link.
CREATE OR REPLACE FUNCTION gq_private.gq_mirror_quote_push_v76()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_key uuid;
BEGIN
 IF NEW.quote_id IS NULL OR NEW.event_key LIKE '%:linked:%' THEN RETURN NEW; END IF;
 FOR v_key IN SELECT customer_key FROM gq_private.gq_quote_push_subscribers_v76
              WHERE quote_id=NEW.quote_id AND customer_key IS DISTINCT FROM NEW.customer_key LOOP
  INSERT INTO public.gq_push_outbox(event_key,customer_key,quote_id,title,message)
   VALUES(NEW.event_key||':linked:'||v_key::text,v_key,NEW.quote_id,NEW.title,NEW.message)
   ON CONFLICT(event_key) DO NOTHING;
 END LOOP;
 RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION gq_private.gq_mirror_quote_push_v76() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS gq_push_mirror_subscribers_v76 ON public.gq_push_outbox;
CREATE TRIGGER gq_push_mirror_subscribers_v76
AFTER INSERT ON public.gq_push_outbox FOR EACH ROW
EXECUTE FUNCTION gq_private.gq_mirror_quote_push_v76();

-- Idempotent, transaction-scoped notifications for changes that previously
-- had no buyer push. One message per quote/event/transaction, even for bulk item edits.
CREATE OR REPLACE FUNCTION gq_private.gq_push_quote_event_v76(
 p_quote_id uuid,p_kind text,p_message text,p_mail_value text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_q public.gq_quotes%rowtype; v_key text;
BEGIN
 SELECT * INTO v_q FROM public.gq_quotes WHERE id=p_quote_id;
 IF NOT FOUND OR v_q.status='cancelled' THEN RETURN; END IF;
 v_key:=v_q.id::text||':'||p_kind||':'||to_char(transaction_timestamp(),'YYYYMMDDHH24MISSUS');
 IF v_q.customer_key IS NOT NULL THEN
  INSERT INTO public.gq_push_outbox(event_key,customer_key,quote_id,title,message)
   VALUES(v_key||':'||v_q.customer_key::text,v_q.customer_key,v_q.id,
     '미니예나',p_message||' 주문조회에서 확인해 주세요.')
   ON CONFLICT(event_key) DO NOTHING;
 END IF;
 IF p_mail_value IS NOT NULL AND v_q.customer_email IS NOT NULL AND
   NOT EXISTS(SELECT 1 FROM gq_private.gq_email_outbox_v45 o
     WHERE o.kind='quote' AND o.object_id=p_quote_id
       AND o.event='order_progress' AND o.event_value=p_mail_value
       AND o.queued_at>=transaction_timestamp()) THEN
  INSERT INTO gq_private.gq_email_outbox_v45(kind,object_id,event,event_value)
   VALUES('quote',p_quote_id,'order_progress',p_mail_value);
 END IF;
END;
$function$;
REVOKE ALL ON FUNCTION gq_private.gq_push_quote_event_v76(uuid,text,text,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION gq_private.gq_notify_item_progress_v76()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_q public.gq_quotes%rowtype;
BEGIN
 SELECT * INTO v_q FROM public.gq_quotes WHERE id=NEW.quote_id;
 IF NOT FOUND OR v_q.status NOT IN ('quoted','confirmed') THEN RETURN NEW; END IF;
 IF OLD.fulfillment IS DISTINCT FROM NEW.fulfillment AND v_q.status='confirmed' THEN
  IF NEW.fulfillment='received' THEN
   -- Last item triggers an automatic pickup-ready notification separately.
   IF v_q.workflow_stage NOT IN ('pickup_ready','completed','shipped') THEN
    PERFORM gq_private.gq_push_quote_event_v76(NEW.quote_id,'item_received',
      '주문하신 상품이 입고됐어요.','item_received');
   END IF;
  ELSIF NEW.fulfillment='sold_out' THEN
   PERFORM gq_private.gq_push_quote_event_v76(NEW.quote_id,'item_sold_out',
     '주문 상품이 품절 처리됐어요. 금액과 환불 안내를 확인해 주세요.','item_sold_out');
  ELSIF NEW.fulfillment IN ('ordered','delayed') AND OLD.fulfillment='received' THEN
   PERFORM gq_private.gq_push_quote_event_v76(NEW.quote_id,'item_reverted',
      '상품 입고 상태가 변경됐어요.','item_reverted');
  END IF;
 END IF;
 IF OLD.supplier_ordered_at IS NULL AND NEW.supplier_ordered_at IS NOT NULL
    AND v_q.status='confirmed' THEN
  PERFORM gq_private.gq_push_quote_event_v76(NEW.quote_id,'item_ordered',
    '주문 상품의 도매 발주가 진행됐어요.','item_ordered');
 END IF;
 IF (OLD.color,OLD.size,OLD.quantity) IS DISTINCT FROM (NEW.color,NEW.size,NEW.quantity)
    AND v_q.status IN ('quoted','confirmed')
    AND current_setting('gq.option_request_approval_v61',true) IS DISTINCT FROM 'yes' THEN
  PERFORM gq_private.gq_push_quote_event_v76(NEW.quote_id,'item_options',
    '주문 상품의 옵션 또는 수량이 수정됐어요.','item_options');
 END IF;
 IF OLD.unit_price IS DISTINCT FROM NEW.unit_price AND v_q.status IN ('quoted','confirmed') THEN
  PERFORM gq_private.gq_push_quote_event_v76(NEW.quote_id,'item_price',
   '상품 가격이 변경됐어요. 최종 결제금액을 확인해 주세요.',NULL);
 END IF;
 RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION gq_private.gq_notify_item_progress_v76() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS gq_notify_item_progress_v76 ON public.gq_quote_items;
CREATE TRIGGER gq_notify_item_progress_v76
AFTER UPDATE OF fulfillment,supplier_ordered_at,color,size,quantity,unit_price ON public.gq_quote_items
FOR EACH ROW EXECUTE FUNCTION gq_private.gq_notify_item_progress_v76();

CREATE OR REPLACE FUNCTION gq_private.gq_notify_quote_progress_v76()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
 IF NEW.status NOT IN ('quoted','confirmed') THEN RETURN NEW; END IF;
 -- Individual supplier batch and quote-wide completion in one transaction
 -- are grouped by event family and transaction.
 IF NEW.supplier_ordered_at IS NOT NULL
    AND OLD.supplier_ordered_at IS DISTINCT FROM NEW.supplier_ordered_at THEN
  PERFORM gq_private.gq_push_quote_event_v76(NEW.id,'item_ordered',
    '상품 도매 발주가 완료됐어요.','item_ordered');
 END IF;
 IF NEW.status='confirmed' THEN
  IF NEW.delivery_method IS DISTINCT FROM OLD.delivery_method AND
     OLD.delivery_change_requested_at IS NOT NULL THEN
   PERFORM gq_private.gq_push_quote_event_v76(NEW.id,'delivery_changed',
     CASE WHEN NEW.delivery_method='courier' THEN '수령방식이 택배수령으로 변경됐어요.'
          ELSE '수령방식이 직접수령으로 변경됐어요.' END,'delivery_changed');
  END IF;
  IF NEW.delivery_change_rejected_at IS NOT NULL AND
     NEW.delivery_change_rejected_at IS DISTINCT FROM OLD.delivery_change_rejected_at THEN
   PERFORM gq_private.gq_push_quote_event_v76(NEW.id,'delivery_rejected',
     '수령방식 변경 요청이 반려됐어요.','delivery_rejected');
  END IF;
  IF NEW.amount_paid IS DISTINCT FROM OLD.amount_paid THEN
   PERFORM gq_private.gq_push_quote_event_v76(NEW.id,'payment_updated',
     '입금 확인금액이 변경됐어요.','payment_updated');
  END IF;
  IF NEW.amount_refunded IS DISTINCT FROM OLD.amount_refunded THEN
   PERFORM gq_private.gq_push_quote_event_v76(NEW.id,'refund_updated',
     '환불 처리금액이 변경됐어요.','refund_updated');
  END IF;
  IF (NEW.tracking_carrier,NEW.tracking_number) IS DISTINCT FROM
     (OLD.tracking_carrier,OLD.tracking_number)
     AND NEW.workflow_stage='shipped' AND
     NEW.workflow_stage IS NOT DISTINCT FROM OLD.workflow_stage THEN
   PERFORM gq_private.gq_push_quote_event_v76(NEW.id,'tracking_updated',
     '택배 운송장 정보가 변경됐어요.','tracking_updated');
  END IF;
 END IF;
 IF (NEW.shipping_fee,NEW.supplier_shipping_share) IS DISTINCT FROM
    (OLD.shipping_fee,OLD.supplier_shipping_share)
   AND (
     NEW.status='confirmed'
     OR (NEW.status='quoted' AND NEW.supplier_shipping_manual_confirmed_at IS NOT NULL
          AND NOT (OLD.supplier_shipping_manual_confirmed_at IS NULL AND
            NEW.purchase_intent='buy_now'))
   ) THEN
  PERFORM gq_private.gq_push_quote_event_v76(NEW.id,'fee_updated',
    '배송비 또는 결제금액이 변경됐어요.','fee_updated');
 END IF;
 RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION gq_private.gq_notify_quote_progress_v76() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS gq_notify_quote_progress_v76 ON public.gq_quotes;
CREATE TRIGGER gq_notify_quote_progress_v76
AFTER UPDATE OF supplier_ordered_at,delivery_method,delivery_change_rejected_at,
 amount_paid,amount_refunded,tracking_carrier,tracking_number,shipping_fee,supplier_shipping_share
ON public.gq_quotes FOR EACH ROW
EXECUTE FUNCTION gq_private.gq_notify_quote_progress_v76();

CREATE OR REPLACE FUNCTION gq_private.gq_notify_option_decision_v76()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
 IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('approved','rejected') THEN
  PERFORM gq_private.gq_push_quote_event_v76(NEW.quote_id,'option_decision',
   CASE WHEN NEW.status='approved' THEN '상품 옵션 변경 요청이 승인됐어요.'
        ELSE '상품 옵션 변경 요청이 반려됐어요.' END,NULL);
 END IF;
 RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION gq_private.gq_notify_option_decision_v76() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS gq_notify_option_decision_v76 ON gq_private.gq_option_change_requests_v61;
CREATE TRIGGER gq_notify_option_decision_v76
AFTER UPDATE OF status ON gq_private.gq_option_change_requests_v61
FOR EACH ROW EXECUTE FUNCTION gq_private.gq_notify_option_decision_v76();
