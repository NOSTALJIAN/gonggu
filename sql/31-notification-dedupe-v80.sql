-- v80: prevent duplicate option-edit emails and notify delivery decisions even before final purchase.
CREATE OR REPLACE FUNCTION gq_private.gq_notify_item_progress_v76()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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
    '주문 상품의 옵션 또는 수량이 수정됐어요.',NULL);
 END IF;
 IF OLD.unit_price IS DISTINCT FROM NEW.unit_price AND v_q.status IN ('quoted','confirmed') THEN
  PERFORM gq_private.gq_push_quote_event_v76(NEW.quote_id,'item_price',
   '상품 가격이 변경됐어요. 최종 결제금액을 확인해 주세요.',NULL);
 END IF;
 RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION gq_private.gq_notify_quote_progress_v76()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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
 IF NEW.status='confirmed' THEN
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
