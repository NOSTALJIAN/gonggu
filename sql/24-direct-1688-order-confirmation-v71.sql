-- 1688-only quotes skip weekly purchase intent, but retain all payment, delivery, cancellation and supplier fee checks.
-- The private product metadata is never returned to customers; only the trusted boolean.
CREATE OR REPLACE FUNCTION gq_private.gq_quote_is_1688_v71(p_quote_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.gq_quote_items i WHERE i.quote_id=p_quote_id)
 AND NOT EXISTS (
   SELECT 1 FROM public.gq_quote_items i
   LEFT JOIN public.gq_product_private_costs_v32 m ON m.product_id=i.product_id
   WHERE i.quote_id=p_quote_id
     AND (
       m.product_id IS NULL
       OR NOT (coalesce(m.source_type,'')='1688'
        OR coalesce(m.supplier_name,'') ~* '(^|[^a-z0-9])1688([^a-z0-9]|$)|阿里巴巴|알리바바')
     )
 );
$function$;
REVOKE ALL ON FUNCTION gq_private.gq_quote_is_1688_v71(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.gq_read_quote(p_quote_id uuid, p_lookup_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v public.gq_quotes%ROWTYPE; v_items jsonb; v_bundle boolean;
BEGIN
 SELECT * INTO v FROM public.gq_quotes WHERE id=p_quote_id AND lookup_token=p_lookup_token;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT coalesce(v.bundle_parent_id IS NOT NULL AND EXISTS(
   SELECT 1 FROM public.gq_quotes q2 WHERE q2.id=v.bundle_parent_id AND q2.status<>'cancelled'
 ),false) INTO v_bundle;
 SELECT COALESCE(jsonb_agg(
   jsonb_build_object('id',i.id,'store_name',i.store_name,'product_name',i.product_name,
    'color',i.color,'size',i.size,'quantity',i.quantity,
    'product_id',i.product_id,'supplier_ordered_at',i.supplier_ordered_at,
    'product_options',coalesce((select p.options from public.gq_products p where p.id=i.product_id),'{}'::jsonb),
    'option_request',(select jsonb_build_object(
       'id',r.id,'status',r.status,'requested_color',r.requested_color,
       'requested_size',r.requested_size,'requested_quantity',r.requested_quantity,
       'requested_at',r.requested_at,'decided_at',r.decided_at,'decision_note',r.decision_note)
       from gq_private.gq_option_change_requests_v61 r
       where r.item_id=i.id order by r.requested_at desc limit 1),
    'unit_price',CASE WHEN v.status IN ('quoted','confirmed','cancelled') THEN i.unit_price ELSE NULL END,
    'fulfillment',CASE WHEN v.status IN ('confirmed','cancelled') THEN i.fulfillment ELSE 'ordered' END)
    ORDER BY i.created_at,i.id),'[]'::jsonb)
 INTO v_items FROM public.gq_quote_items i WHERE i.quote_id=v.id;
 RETURN jsonb_build_object(
  'id',v.id,'direct_1688',gq_private.gq_quote_is_1688_v71(v.id),'supplier_ordered_at',v.supplier_ordered_at,'purchase_intent',v.purchase_intent,'purchase_intent_at',v.purchase_intent_at,'buyer_name',v.buyer_name,'baby_name',v.baby_name,'status',v.status,
  'delivery_method',v.delivery_method,'recipient_name',v.recipient_name,'postal_code',v.postal_code,
  'address_line1',v.address_line1,'address_line2',v.address_line2,'delivery_note',v.delivery_note,
  'bundle_applied',v_bundle,'amount_changed_at',v.amount_changed_at,
  'supplier_shipping_ready',coalesce(v.status='confirmed' OR v.supplier_shipping_manual_confirmed_at is not null OR (
    EXISTS(SELECT 1 FROM public.gq_quote_items line WHERE line.quote_id=v.id AND line.fulfillment<>'sold_out') AND
    NOT EXISTS(SELECT 1 FROM public.gq_quote_items line
       WHERE line.quote_id=v.id AND line.fulfillment<>'sold_out'
       AND NOT EXISTS(SELECT 1 FROM gq_private.gq_supplier_item_batch_items_v50 bi WHERE bi.item_id=line.id))
   ),false),
  'workflow_stage',CASE WHEN v.status='confirmed' THEN coalesce(v.workflow_stage,'new') ELSE NULL END,
  'workflow_updated_at',CASE WHEN v.status='confirmed' THEN v.workflow_updated_at ELSE NULL END,
  'tracking_carrier',CASE WHEN v.status='confirmed' AND v.workflow_stage IN ('shipped','completed') THEN v.tracking_carrier ELSE NULL END,
  'tracking_number',CASE WHEN v.status='confirmed' AND v.workflow_stage IN ('shipped','completed') THEN v.tracking_number ELSE NULL END,
  'delivery_change_requested_at',v.delivery_change_requested_at,
  'delivery_change_rejected_at',v.delivery_change_rejected_at,
  'requested_delivery_method',v.requested_delivery_method,
  'requested_recipient_name',v.requested_recipient_name,
  'requested_postal_code',v.requested_postal_code,
  'requested_address_line1',v.requested_address_line1,
  'requested_address_line2',v.requested_address_line2,
  'requested_delivery_note',v.requested_delivery_note,
  'shipping_fee',CASE WHEN v.status IN ('quoted','confirmed','cancelled') THEN v.shipping_fee ELSE NULL END,
  'supplier_shipping_share',CASE WHEN v.status IN ('quoted','confirmed','cancelled') THEN v.supplier_shipping_share ELSE NULL END,
  'supplier_shipping_people',CASE WHEN v.status IN ('quoted','confirmed','cancelled') AND v.supplier_shipping_share>0 THEN v.supplier_shipping_people ELSE NULL END,
  'amount_paid',CASE WHEN v.status IN ('confirmed','cancelled') THEN v.amount_paid ELSE 0 END,
  'amount_refunded',CASE WHEN v.status IN ('confirmed','cancelled') THEN v.amount_refunded ELSE 0 END,
  'cancel_requested_at',v.cancel_requested_at,'cancel_reason',v.cancel_reason,
  'cancel_rejected_at',v.cancel_rejected_at,'created_at',v.created_at,'items',v_items
 );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gq_confirm_quote(p_quote_id uuid, p_lookup_token uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.gq_quotes%rowtype;
begin
 select * into v from public.gq_quotes where id=p_quote_id and lookup_token=p_lookup_token for update;
 if not found or v.status<>'quoted' then raise exception '아직 최종 주문 가능한 견적이 아닙니다';end if;
 if v.purchase_intent<>'buy_now' and not gq_private.gq_quote_is_1688_v71(v.id) then
  raise exception '먼저 이번 회차 구매를 선택해 주세요.';
 end if;
 if v.cancel_requested_at is not null then raise exception '취소 요청 처리 중에는 최종 주문할 수 없습니다';end if;
 if v.delivery_change_requested_at is not null then raise exception '수령방식 변경 요청을 먼저 처리해 주세요.';end if;
 if v.delivery_method='courier' and v.bundle_parent_id is null and v.shipping_fee is null then
  raise exception '고객 수령 택배비가 아직 정해지지 않았어요.';end if;
 if exists(select 1 from public.gq_quote_items i where i.quote_id=v.id
      and i.fulfillment<>'sold_out' and i.unit_price is null) then
  raise exception '가격 미정 상품이 남아 있어요';end if;
 if not exists(select 1 from public.gq_quote_items i
      where i.quote_id=v.id and i.fulfillment<>'sold_out') then
  raise exception '구매할 수 있는 상품이 없어요.';end if;
 if v.supplier_shipping_manual_confirmed_at is null and exists(select 1 from public.gq_quote_items i
    where i.quote_id=v.id and i.fulfillment<>'sold_out'
    and not exists(select 1 from gq_private.gq_supplier_item_batch_items_v50 bi where bi.item_id=i.id)) then
  raise exception '도매배송비 배분이 아직 끝나지 않았어요. 관리자가 배송비를 확정한 뒤 최종 주문해 주세요.';
 end if;
 update public.gq_quotes set status='confirmed',purchase_intent='buy_now',
    purchase_intent_at=coalesce(purchase_intent_at,clock_timestamp()) where id=v.id;
 return true;
end $function$;

-- Repair already-quoted pure 1688 orders whose wholesale freight was never finalized.
-- Do not touch mixed orders, already-confirmed orders, manual amounts or supplier batches.
UPDATE public.gq_quotes q
SET supplier_shipping_total=0,
    supplier_shipping_people=1,
    supplier_shipping_manual_confirmed_at=clock_timestamp()
WHERE q.status='quoted'
  AND gq_private.gq_quote_is_1688_v71(q.id)
  AND q.supplier_shipping_manual_confirmed_at IS NULL
  AND coalesce(q.supplier_shipping_share,0)=0
  AND NOT EXISTS (
    SELECT 1 FROM public.gq_quote_items i
    JOIN gq_private.gq_supplier_item_batch_items_v50 bi ON bi.item_id=i.id
    WHERE i.quote_id=q.id
  );