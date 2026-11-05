-- MINIYENA: GitHub customers order at 1.3x Namdaemun wholesale cost
-- Existing quote item unit prices/payment records are intentionally not updated.
-- China (1688) prices and manually fixed option prices are unchanged.

CREATE OR REPLACE FUNCTION gq_private.gq_update_estimated_product_price_v37()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
 IF TG_OP='DELETE' THEN
  UPDATE public.gq_products SET estimated_price=NULL, github_estimated_price=NULL WHERE id=OLD.product_id;
  RETURN OLD;
 END IF;
 UPDATE public.gq_products SET
  estimated_price=CASE
    WHEN NEW.source_type='1688' AND NEW.yuan_price>0 THEN round(NEW.yuan_price*650)::integer
    WHEN NEW.source_type='namdaemun' AND NEW.wholesale_price>0 THEN (round(NEW.wholesale_price::numeric*1.4/100)*100)::integer
    ELSE NULL END,
  github_estimated_price=CASE
    WHEN NEW.source_type='1688' AND NEW.yuan_price>0 THEN round(NEW.yuan_price*550)::integer
    WHEN NEW.source_type='namdaemun' AND NEW.wholesale_price>0 THEN round(NEW.wholesale_price::numeric*1.3)::integer
    ELSE NULL END
 WHERE id=NEW.product_id;
 RETURN NEW;
END;
$$;

UPDATE public.gq_products AS p
SET github_estimated_price=round(pc.wholesale_price::numeric*1.3)::integer
FROM public.gq_product_private_costs_v32 AS pc
WHERE pc.product_id=p.id AND pc.source_type='namdaemun' AND pc.wholesale_price>0
  AND p.github_estimated_price IS DISTINCT FROM round(pc.wholesale_price::numeric*1.3)::integer;

CREATE OR REPLACE FUNCTION public.gq_instant_purchase_github_v114(
 p_name text, p_baby_name text, p_contact text, p_note text, p_items jsonb,
 p_customer_key uuid, p_delivery_method text, p_recipient_name text,
 p_postal_code text, p_address_line1 text, p_address_line2 text,
 p_delivery_note text, p_lookup_pin text, p_email text, p_remote_area boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
 v_result jsonb; v_id uuid; v_line record;
 v_expected integer; v_priced integer:=0; v_goods_total bigint:=0;
 v_client_count integer; v_client_total bigint;
 v_actual_price integer; v_variant_text text;
 v_remote boolean; v_fee integer;
BEGIN
 -- Use the existing verified buyer/contact/order-insertion path.
 v_result:=public.gq_request_quote_v45(
  p_name,p_baby_name,p_contact,p_note,p_items,p_customer_key,
  p_delivery_method,p_recipient_name,p_postal_code,p_address_line1,
  p_address_line2,p_delivery_note,p_lookup_pin,p_email
 );
 v_id:=(v_result->>'id')::uuid;
 IF v_id IS NULL THEN RAISE EXCEPTION '주문번호 생성에 실패했어요.'; END IF;

 SELECT count(*) INTO v_expected FROM public.gq_quote_items WHERE quote_id=v_id;
 IF v_expected<1 THEN RAISE EXCEPTION '주문할 상품이 없어요.' USING errcode='22023'; END IF;

 FOR v_line IN
  SELECT i.id,i.color,i.size,p.github_estimated_price,p.pricing_mode,
         p.option_prices,p.published,p.is_sold_out,s.active
  FROM public.gq_quote_items i
  JOIN public.gq_products p ON p.id=i.product_id
  JOIN public.gq_stores s ON s.id=p.store_id
  WHERE i.quote_id=v_id
  ORDER BY p.id,i.id FOR UPDATE OF i,p,s
 LOOP
  v_actual_price:=NULL;
  IF v_line.pricing_mode='fixed_options' THEN
   v_variant_text:=v_line.option_prices->v_line.color->>v_line.size;
   IF coalesce(v_variant_text,'') ~ '^[1-9][0-9]{0,8}$' THEN
    v_actual_price:=v_variant_text::integer;
   END IF;
  ELSE
   v_actual_price:=v_line.github_estimated_price;
  END IF;
  IF NOT v_line.published OR v_line.is_sold_out OR NOT v_line.active
    OR v_actual_price IS NULL OR v_actual_price<1 OR v_actual_price>100000000 THEN
   RAISE EXCEPTION '판매 종료되거나 해당 색상·사이즈 판매가를 확인할 수 없는 상품이 있어요. 새로고침해 주세요.'
    USING errcode='22023';
  END IF;
  UPDATE public.gq_quote_items SET unit_price=v_actual_price WHERE id=v_line.id AND quote_id=v_id;
  v_priced:=v_priced+1;
 END LOOP;

 IF v_expected<>v_priced THEN
  RAISE EXCEPTION '상품 목록이 변경됐어요. 다시 주문해 주세요.' USING errcode='22023';
 END IF;
 SELECT coalesce(sum(i.unit_price::bigint*i.quantity),0) INTO v_goods_total
 FROM public.gq_quote_items i WHERE i.quote_id=v_id;

 -- Never trust client-submitted prices. They must match the independently computed
 -- live server-side GitHub sales prices for every item and for the cart total.
 SELECT count(*) FILTER (WHERE jsonb_typeof(item->'expected_price')='number'
   AND (item->>'expected_price') ~ '^[1-9][0-9]{0,8}$'),
   coalesce(sum(CASE WHEN (item->>'expected_price') ~ '^[1-9][0-9]{0,8}$'
      THEN (item->>'expected_price')::bigint*(item->>'quantity')::bigint ELSE 0 END),0)
 INTO v_client_count,v_client_total
 FROM jsonb_array_elements(p_items) item;
 IF v_client_count<>v_expected OR v_client_total<>v_goods_total THEN
  RAISE EXCEPTION '선택한 옵션의 판매가격이 변경됐어요. 장바구니를 다시 열어 금액을 확인하고 주문해 주세요.'
   USING errcode='22023';
 END IF;

 v_remote:=p_delivery_method='courier' AND (
    coalesce(p_remote_area,false)
    OR coalesce(p_postal_code,'') ~ '^(63[0-6]|402)'
    OR coalesce(p_address_line1,'') ~ '(제주특별자치도|제주시|서귀포시|울릉군)'
 );
 v_fee:=CASE WHEN p_delivery_method='courier'
   THEN 3500+CASE WHEN v_remote THEN 3000 ELSE 0 END
   ELSE 0 END;
 IF v_goods_total<1 OR v_goods_total+v_fee>1000000000 THEN
  RAISE EXCEPTION '주문금액을 확인해 주세요.' USING errcode='22023';
 END IF;

 -- A direct order must not leave a pending legacy quote-request email.
 DELETE FROM gq_private.gq_email_outbox_v45
 WHERE kind='quote' AND object_id=v_id AND event='quote_received';

 UPDATE public.gq_quotes SET
  status='confirmed',
  purchase_intent='buy_now',purchase_intent_at=clock_timestamp(),quoted_at=clock_timestamp(),
  supplier_shipping_total=0,supplier_shipping_share=0,supplier_shipping_people=1,
  supplier_shipping_manual_confirmed_at=clock_timestamp(),
  shipping_fee=v_fee,remote_area=v_remote,
  price_channel='github',notification_origin='https://nostaljian.github.io/gonggu/',
  instant_purchase=true
 WHERE id=v_id AND lookup_token=(v_result->>'token')::uuid AND status='requested';
 IF NOT FOUND THEN RAISE EXCEPTION '주문 확정 저장에 실패했어요.'; END IF;

 RETURN v_result;
END;
$$;

-- Execute from the public checkout only. The function's internal rules
-- validate live catalog, option prices and requested item totals.
REVOKE ALL ON FUNCTION public.gq_instant_purchase_github_v114(
 text,text,text,text,jsonb,uuid,text,text,text,text,text,text,text,text,boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gq_instant_purchase_github_v114(
 text,text,text,text,jsonb,uuid,text,text,text,text,text,text,text,text,boolean
) TO anon, authenticated;
