-- Automatically charge KRW 3,000 for courier delivery, KRW 0 for pickup.
-- Preserve manual fees and one-charge-only behavior for bundled deliveries.


CREATE OR REPLACE FUNCTION public.gq_request_quote_v8(p_name text, p_baby_name text, p_contact text, p_note text, p_items jsonb, p_customer_key uuid, p_delivery_method text, p_recipient_name text, p_postal_code text, p_address_line1 text, p_address_line2 text, p_delivery_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_result jsonb; v_id uuid;
BEGIN
 IF p_delivery_method IS NULL OR p_delivery_method NOT IN ('pickup','courier') THEN
  RAISE EXCEPTION '수령방식을 선택해 주세요';
 END IF;
 IF p_delivery_method='courier' THEN
  IF char_length(btrim(coalesce(p_recipient_name,''))) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION '받는 사람 이름을 입력해 주세요'; END IF;
  IF btrim(coalesce(p_postal_code,'')) !~ '^[0-9]{5}$' THEN RAISE EXCEPTION '우편번호 5자리를 입력해 주세요'; END IF;
  IF char_length(btrim(coalesce(p_address_line1,''))) NOT BETWEEN 4 AND 250 THEN RAISE EXCEPTION '택배 받을 주소를 입력해 주세요'; END IF;
  IF char_length(coalesce(p_address_line2,''))>250 OR char_length(coalesce(p_delivery_note,''))>200 THEN RAISE EXCEPTION '배송 상세정보가 너무 길어요'; END IF;
 END IF;
 SELECT public.gq_request_quote_v7(p_name,p_baby_name,p_contact,p_note,p_items,p_customer_key) INTO v_result;
 v_id := (v_result->>'id')::uuid;
 UPDATE public.gq_quotes SET
  delivery_method=p_delivery_method,
  recipient_name=CASE WHEN p_delivery_method='courier' THEN btrim(p_recipient_name) ELSE NULL END,
  postal_code=CASE WHEN p_delivery_method='courier' THEN btrim(p_postal_code) ELSE NULL END,
  address_line1=CASE WHEN p_delivery_method='courier' THEN btrim(p_address_line1) ELSE NULL END,
  address_line2=CASE WHEN p_delivery_method='courier' THEN nullif(btrim(coalesce(p_address_line2,'')),'') ELSE NULL END,
  delivery_note=CASE WHEN p_delivery_method='courier' THEN nullif(btrim(coalesce(p_delivery_note,'')),'') ELSE NULL END,
  shipping_fee=CASE WHEN p_delivery_method='courier' THEN 3000 ELSE 0 END
 WHERE id=v_id AND lookup_token=(v_result->>'token')::uuid;
 RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gq_update_delivery_v11(p_quote_id uuid, p_lookup_token uuid, p_delivery_method text, p_recipient_name text, p_postal_code text, p_address_line1 text, p_address_line2 text, p_delivery_note text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE q public.gq_quotes%ROWTYPE; v_review boolean;
BEGIN
 SELECT * INTO q FROM public.gq_quotes WHERE id=p_quote_id AND lookup_token=p_lookup_token FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '견적을 찾을 수 없어요'; END IF;
 IF q.status='cancelled' THEN RAISE EXCEPTION '취소된 주문은 수정할 수 없어요'; END IF;
 IF q.cancel_requested_at IS NOT NULL THEN RAISE EXCEPTION '취소 요청 처리 후 변경할 수 있어요'; END IF;
 IF p_delivery_method NOT IN ('pickup','courier') OR p_delivery_method IS NULL THEN
  RAISE EXCEPTION '수령방식을 선택해 주세요'; END IF;
 IF p_delivery_method='courier' THEN
  IF char_length(btrim(coalesce(p_recipient_name,''))) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION '받는 사람을 입력해 주세요'; END IF;
  IF btrim(coalesce(p_postal_code,'')) !~ '^[0-9]{5}$' THEN RAISE EXCEPTION '우편번호 5자리를 입력해 주세요'; END IF;
  IF char_length(btrim(coalesce(p_address_line1,''))) NOT BETWEEN 4 AND 250 THEN RAISE EXCEPTION '주소를 입력해 주세요'; END IF;
  IF char_length(coalesce(p_address_line2,''))>250 OR char_length(coalesce(p_delivery_note,''))>200 THEN RAISE EXCEPTION '주소 또는 배송 요청사항이 너무 길어요'; END IF;
 END IF;
 v_review := q.status='confirmed' OR q.bundle_parent_id IS NOT NULL
   OR EXISTS(SELECT 1 FROM public.gq_quotes child WHERE child.bundle_parent_id=q.id AND child.status<>'cancelled');
 IF v_review THEN
  UPDATE public.gq_quotes SET
   delivery_change_requested_at=clock_timestamp(),delivery_change_rejected_at=NULL,
   requested_delivery_method=p_delivery_method,
   requested_recipient_name=CASE WHEN p_delivery_method='courier' THEN btrim(p_recipient_name) ELSE NULL END,
   requested_postal_code=CASE WHEN p_delivery_method='courier' THEN btrim(p_postal_code) ELSE NULL END,
   requested_address_line1=CASE WHEN p_delivery_method='courier' THEN btrim(p_address_line1) ELSE NULL END,
   requested_address_line2=CASE WHEN p_delivery_method='courier' THEN nullif(btrim(coalesce(p_address_line2,'')),'') ELSE NULL END,
   requested_delivery_note=CASE WHEN p_delivery_method='courier' THEN nullif(btrim(coalesce(p_delivery_note,'')),'') ELSE NULL END
   WHERE id=q.id;
  RETURN 'pending';
 END IF;
 IF q.status='quoted' THEN
   -- 1) 먼저 재견적으로 되돌리고 2) 배송비 리셋.
   -- v9의 배송비 잠금 트리거가 공개된 견적을 구매자가 수정하는 것을 막기 때문입니다.
   UPDATE public.gq_quotes SET status='requested',quoted_at=NULL WHERE id=q.id;
 END IF;
 UPDATE public.gq_quotes SET
   delivery_method=p_delivery_method,
   recipient_name=CASE WHEN p_delivery_method='courier' THEN btrim(p_recipient_name) ELSE NULL END,
   postal_code=CASE WHEN p_delivery_method='courier' THEN btrim(p_postal_code) ELSE NULL END,
   address_line1=CASE WHEN p_delivery_method='courier' THEN btrim(p_address_line1) ELSE NULL END,
   address_line2=CASE WHEN p_delivery_method='courier' THEN nullif(btrim(coalesce(p_address_line2,'')),'') ELSE NULL END,
   delivery_note=CASE WHEN p_delivery_method='courier' THEN nullif(btrim(coalesce(p_delivery_note,'')),'') ELSE NULL END,
   shipping_fee=CASE WHEN p_delivery_method='courier' THEN 3000 ELSE 0 END,
   delivery_change_requested_at=NULL,delivery_change_rejected_at=NULL
 WHERE id=q.id;
 RETURN 'updated';
END;
$function$;

CREATE OR REPLACE FUNCTION public.gq_review_delivery_v11(p_quote_id uuid, p_approve boolean, p_shipping_fee integer DEFAULT NULL::integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE q public.gq_quotes%ROWTYPE; v_bundle boolean; v_changed_address boolean;
BEGIN
 IF NOT public.gq_is_admin() THEN RAISE EXCEPTION '관리자만 배송 변경 요청을 처리할 수 있어요'; END IF;
 SELECT * INTO q FROM public.gq_quotes WHERE id=p_quote_id FOR UPDATE;
 IF NOT FOUND OR q.delivery_change_requested_at IS NULL THEN RAISE EXCEPTION '대기 중인 배송 변경 요청이 없어요'; END IF;
 IF q.status='cancelled' THEN RAISE EXCEPTION '취소된 주문입니다'; END IF;
 IF NOT coalesce(p_approve,false) THEN
  UPDATE public.gq_quotes SET delivery_change_requested_at=NULL,
   delivery_change_rejected_at=clock_timestamp(),requested_delivery_method=NULL,
   requested_recipient_name=NULL,requested_postal_code=NULL,requested_address_line1=NULL,
   requested_address_line2=NULL,requested_delivery_note=NULL
  WHERE id=q.id;
  RETURN true;
 END IF;
 v_bundle := q.bundle_parent_id IS NOT NULL OR EXISTS(
  SELECT 1 FROM public.gq_quotes child WHERE child.bundle_parent_id=q.id AND child.status<>'cancelled');
 v_changed_address := q.delivery_method IS DISTINCT FROM q.requested_delivery_method
   OR coalesce(q.postal_code,'') IS DISTINCT FROM coalesce(q.requested_postal_code,'')
   OR coalesce(q.address_line1,'') IS DISTINCT FROM coalesce(q.requested_address_line1,'')
   OR coalesce(q.address_line2,'') IS DISTINCT FROM coalesce(q.requested_address_line2,'');
 IF v_bundle AND v_changed_address THEN
  RAISE EXCEPTION '묶음배송 중에는 수령방식·배송지 변경을 승인할 수 없어요. 먼저 관련 묶음배송을 해제해 주세요';
 END IF;
 -- 승인 시 고객 배송비를 수령방식으로 자동 계산합니다.
 -- 관리자는 별도 배송비 편집 화면에서 예외를 조정할 수 있습니다.
 p_shipping_fee:=CASE WHEN q.requested_delivery_method='courier' THEN 3000 ELSE 0 END;
 UPDATE public.gq_quotes SET
   delivery_method=q.requested_delivery_method,
   recipient_name=q.requested_recipient_name,postal_code=q.requested_postal_code,
   address_line1=q.requested_address_line1,address_line2=q.requested_address_line2,
   delivery_note=q.requested_delivery_note,
   shipping_fee=CASE WHEN v_bundle THEN q.shipping_fee ELSE p_shipping_fee END,
   delivery_change_requested_at=NULL,delivery_change_rejected_at=NULL,
   requested_delivery_method=NULL,requested_recipient_name=NULL,
   requested_postal_code=NULL,requested_address_line1=NULL,
   requested_address_line2=NULL,requested_delivery_note=NULL
 WHERE id=q.id;
 RETURN true;
END;
$function$;

-- One pre-existing, unpriced courier quote should get the new base fee.
-- Never change quoted, confirmed, cancelled, manually priced or bundled orders.
UPDATE public.gq_quotes
SET shipping_fee=3000
WHERE delivery_method='courier' AND shipping_fee IS NULL
  AND status='requested' AND bundle_parent_id IS NULL;