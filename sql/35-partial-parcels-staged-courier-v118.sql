-- MINIYENA partial courier shipments v118. No existing order totals are changed.
CREATE TABLE IF NOT EXISTS public.gq_partial_parcels_v118 (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 root_quote_id uuid NOT NULL REFERENCES public.gq_quotes(id) ON DELETE CASCADE,
 carrier text NOT NULL CHECK (length(btrim(carrier)) BETWEEN 1 AND 60),
 tracking_number text NOT NULL CHECK (btrim(tracking_number) ~ '^[A-Za-z0-9 -]{4,80}$'),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 created_by uuid NOT NULL,
 UNIQUE(root_quote_id,tracking_number)
);
CREATE TABLE IF NOT EXISTS public.gq_partial_parcel_items_v118 (
 parcel_id uuid NOT NULL REFERENCES public.gq_partial_parcels_v118(id) ON DELETE CASCADE,
 item_id uuid NOT NULL REFERENCES public.gq_quote_items(id) ON DELETE CASCADE,
 quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 20),
 PRIMARY KEY(parcel_id,item_id)
);
CREATE INDEX IF NOT EXISTS gq_partial_parcel_items_item_v118 ON public.gq_partial_parcel_items_v118(item_id);
CREATE INDEX IF NOT EXISTS gq_partial_parcels_root_v118 ON public.gq_partial_parcels_v118(root_quote_id,created_at DESC);
ALTER TABLE public.gq_partial_parcels_v118 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gq_partial_parcel_items_v118 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gq_partial_parcels_v118,public.gq_partial_parcel_items_v118 FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.gq_admin_create_partial_parcel_v118(
 p_root_quote_id uuid,p_carrier text,p_tracking_number text,p_lines jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $func$
DECLARE
 v_root public.gq_quotes%ROWTYPE; v_ids uuid[]; v_count integer;
 v_order public.gq_quotes%ROWTYPE; v_item public.gq_quote_items%ROWTYPE;
 v_line jsonb; v_item_id uuid; v_quantity integer; v_sent integer; v_received integer;
 v_carrier text:=btrim(coalesce(p_carrier,'')); v_tracking text:=btrim(coalesce(p_tracking_number,''));
 v_parcel uuid; v_line_count integer; v_quote_id uuid; v_latest record; v_ready boolean; v_items integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.gq_is_admin() THEN RAISE EXCEPTION '관리자만 부분배송을 등록할 수 있어요' USING errcode='42501'; END IF;
 IF p_root_quote_id IS NULL THEN RAISE EXCEPTION '기준 주문을 지정해 주세요'; END IF;
 IF length(v_carrier) NOT BETWEEN 1 AND 60 OR v_tracking !~ '^[A-Za-z0-9 -]{4,80}$' THEN
  RAISE EXCEPTION '택배사와 올바른 송장번호를 입력해 주세요' USING errcode='22023';
 END IF;
 IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines)<1 OR jsonb_array_length(p_lines)>100 THEN
  RAISE EXCEPTION '먼저 보낼 상품을 선택해 주세요' USING errcode='22023';
 END IF;
 SELECT * INTO v_root FROM public.gq_quotes WHERE id=p_root_quote_id FOR UPDATE;
 IF NOT FOUND OR v_root.bundle_parent_id IS NOT NULL THEN
  RAISE EXCEPTION '묶음배송 대표 주문을 다시 확인해 주세요' USING errcode='22023';
 END IF;
 WITH RECURSIVE grouped AS (
  SELECT id,ARRAY[id] AS visited FROM public.gq_quotes WHERE id=p_root_quote_id
  UNION ALL
  SELECT child.id,g.visited||child.id
  FROM public.gq_quotes child JOIN grouped g ON child.bundle_parent_id=g.id
  WHERE NOT child.id=ANY(g.visited) AND cardinality(g.visited)<16
 )
 SELECT array_agg(id ORDER BY id),count(*) INTO v_ids,v_count FROM grouped;
 IF v_count<1 OR v_count>40 THEN RAISE EXCEPTION '묶음 주문 구조를 확인해 주세요'; END IF;
 -- Lock the entire shipment group so simultaneous submissions cannot double-dispatch.
 PERFORM id FROM public.gq_quotes WHERE id=ANY(v_ids) ORDER BY id FOR UPDATE;
 FOR v_order IN SELECT * FROM public.gq_quotes WHERE id=ANY(v_ids) LOOP
  IF v_order.status<>'confirmed' OR v_order.delivery_method<>'courier' OR
      v_order.cancel_requested_at IS NOT NULL OR v_order.delivery_change_requested_at IS NOT NULL OR
      coalesce(v_order.workflow_stage,'new') NOT IN ('new','preparing','shipped') THEN
   RAISE EXCEPTION '묶인 주문의 확정·수령·배송 상태를 확인해 주세요' USING errcode='22023';
  END IF;
  IF v_order.id<>v_root.id AND (
    (v_order.postal_code IS NOT NULL AND v_order.postal_code<>v_root.postal_code) OR
    (v_order.address_line1 IS NOT NULL AND v_order.address_line1<>v_root.address_line1)
   ) THEN
   RAISE EXCEPTION '묶음 주문의 배송지가 다릅니다. 배송지를 먼저 확인해 주세요' USING errcode='22023';
  END IF;
 END LOOP;
 IF EXISTS (
  SELECT 1 FROM public.gq_partial_parcels_v118
  WHERE root_quote_id=p_root_quote_id AND replace(tracking_number,'-','')=replace(v_tracking,'-','')
 ) THEN RAISE EXCEPTION '이 묶음에 이미 등록한 송장번호예요' USING errcode='23505'; END IF;

 SELECT count(*),count(distinct entry->>'item_id') INTO v_line_count,v_items
 FROM jsonb_array_elements(p_lines) entry;
 IF v_line_count<>v_items THEN RAISE EXCEPTION '같은 상품이 두 번 선택되었어요' USING errcode='22023'; END IF;

 FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
  IF (v_line->>'item_id') IS NULL OR
    (v_line->>'item_id') !~ '^[0-9a-fA-F-]{36}$' OR
    (v_line->>'quantity') !~ '^[1-9][0-9]?$' THEN
   RAISE EXCEPTION '발송 상품과 수량을 확인해 주세요' USING errcode='22023';
  END IF;
  v_item_id:=(v_line->>'item_id')::uuid;v_quantity:=(v_line->>'quantity')::integer;
  SELECT * INTO v_item FROM public.gq_quote_items WHERE id=v_item_id FOR UPDATE;
  IF NOT FOUND OR NOT v_item.quote_id=ANY(v_ids) OR v_item.fulfillment IN ('sold_out','delivered') THEN
    RAISE EXCEPTION '발송 가능한 상품이 아니에요. 새로고침해 주세요' USING errcode='22023';
  END IF;
  IF EXISTS(
   SELECT 1 FROM public.gq_quotes q WHERE q.id=v_item.quote_id AND coalesce(q.workflow_stage,'new') NOT IN ('new','preparing')
  ) THEN RAISE EXCEPTION '이미 발송이 완료된 주문의 상품이에요' USING errcode='22023'; END IF;
  SELECT coalesce(sum(l.quantity),0) INTO v_sent
  FROM public.gq_partial_parcel_items_v118 l WHERE l.item_id=v_item_id;
  v_received:=CASE WHEN v_item.fulfillment='received' THEN v_item.quantity ELSE v_item.received_qty END;
  IF v_quantity>v_received-v_sent THEN
   RAISE EXCEPTION '입고완료된 남은 수량보다 많아요: %',v_item.product_name USING errcode='22023';
  END IF;
 END LOOP;

 INSERT INTO public.gq_partial_parcels_v118(root_quote_id,carrier,tracking_number,created_by)
 VALUES(p_root_quote_id,v_carrier,v_tracking,auth.uid()) RETURNING id INTO v_parcel;
 INSERT INTO public.gq_partial_parcel_items_v118(parcel_id,item_id,quantity)
 SELECT v_parcel,(entry->>'item_id')::uuid,(entry->>'quantity')::integer
 FROM jsonb_array_elements(p_lines) entry;

 -- An order only becomes fully shipped when every non-sold-out unit is in
 -- a registered parcel. Otherwise it stays in preparation for the next arrival.
 FOR v_quote_id IN SELECT unnest(v_ids) LOOP
  SELECT NOT EXISTS (
   SELECT 1 FROM public.gq_quote_items i WHERE i.quote_id=v_quote_id AND i.fulfillment<>'sold_out'
     AND (SELECT coalesce(sum(l.quantity),0)
       FROM public.gq_partial_parcel_items_v118 l WHERE l.item_id=i.id)<i.quantity
  ) AND EXISTS (
    SELECT 1 FROM public.gq_quote_items i WHERE i.quote_id=v_quote_id AND i.fulfillment<>'sold_out'
  ) INTO v_ready;
  IF v_ready THEN
   SELECT sh.carrier,sh.tracking_number INTO v_latest
   FROM public.gq_partial_parcels_v118 sh
   JOIN public.gq_partial_parcel_items_v118 l ON l.parcel_id=sh.id
   JOIN public.gq_quote_items i ON i.id=l.item_id
   WHERE i.quote_id=v_quote_id ORDER BY sh.created_at DESC,sh.id DESC LIMIT 1;
   UPDATE public.gq_quotes SET workflow_stage='shipped',
     workflow_updated_at=clock_timestamp(),tracking_carrier=v_latest.carrier,
     tracking_number=v_latest.tracking_number
     WHERE id=v_quote_id AND coalesce(workflow_stage,'new')<>'shipped';
  ELSE
   UPDATE public.gq_quotes SET workflow_stage='preparing',workflow_updated_at=clock_timestamp()
   WHERE id=v_quote_id AND coalesce(workflow_stage,'new')='new';
  END IF;
 END LOOP;
 RETURN jsonb_build_object('id',v_parcel,'registered',v_line_count,'tracking_number',v_tracking);
END;
$func$;

CREATE OR REPLACE FUNCTION public.gq_admin_list_partial_parcels_v118()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $func$
DECLARE v_result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.gq_is_admin() THEN RAISE EXCEPTION '관리자 권한이 필요해요' USING errcode='42501'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'root_quote_id',p.root_quote_id,'carrier',p.carrier,
  'tracking_number',p.tracking_number,'created_at',p.created_at,
  'items',(SELECT coalesce(jsonb_agg(jsonb_build_object(
    'item_id',l.item_id,'quote_id',i.quote_id,'quantity',l.quantity,
    'name',i.product_name,'color',i.color,'size',i.size) ORDER BY i.created_at,i.id),'[]'::jsonb)
    FROM public.gq_partial_parcel_items_v118 l JOIN public.gq_quote_items i ON i.id=l.item_id WHERE l.parcel_id=p.id)
 ) ORDER BY p.created_at DESC,p.id DESC),'[]'::jsonb)
 INTO v_result FROM public.gq_partial_parcels_v118 p;
 RETURN v_result;
END;
$func$;

CREATE OR REPLACE FUNCTION public.gq_read_partial_parcels_v118(p_quote_id uuid,p_lookup_token uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $func$
DECLARE v_result jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.gq_quotes WHERE id=p_quote_id AND lookup_token=p_lookup_token)
 THEN RETURN '[]'::jsonb;END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'carrier',p.carrier,'tracking_number',p.tracking_number,
  'created_at',p.created_at,
  'items',(SELECT coalesce(jsonb_agg(jsonb_build_object(
    'item_id',l.item_id,'quantity',l.quantity,'name',i.product_name,
    'color',i.color,'size',i.size) ORDER BY i.created_at),'[]'::jsonb)
   FROM public.gq_partial_parcel_items_v118 l JOIN public.gq_quote_items i ON i.id=l.item_id
   WHERE l.parcel_id=p.id AND i.quote_id=p_quote_id)
 ) ORDER BY p.created_at DESC),'[]'::jsonb) INTO v_result
 FROM public.gq_partial_parcels_v118 p
 WHERE EXISTS(SELECT 1 FROM public.gq_partial_parcel_items_v118 l
 JOIN public.gq_quote_items i ON i.id=l.item_id WHERE l.parcel_id=p.id AND i.quote_id=p_quote_id);
 RETURN v_result;
END;
$func$;

CREATE OR REPLACE FUNCTION gq_private.gq_protect_partially_shipped_items_v118()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $func$
DECLARE v_sent integer;
BEGIN
 SELECT coalesce(sum(l.quantity),0) INTO v_sent
 FROM public.gq_partial_parcel_items_v118 l WHERE l.item_id=OLD.id;
 IF v_sent>0 AND (
   NEW.quantity<v_sent OR NEW.fulfillment IN ('sold_out','ordered','delayed')
   OR NEW.quote_id IS DISTINCT FROM OLD.quote_id
 ) THEN
  RAISE EXCEPTION '이미 일부 발송한 상품은 입고 취소·품절·수량 축소할 수 없어요. 배송기록을 먼저 확인해 주세요'
   USING errcode='22023';
 END IF;
 RETURN NEW;
END;
$func$;
CREATE TRIGGER gq_protect_partially_shipped_items_v118
 BEFORE UPDATE OF fulfillment,quantity,quote_id ON public.gq_quote_items
 FOR EACH ROW EXECUTE FUNCTION gq_private.gq_protect_partially_shipped_items_v118();

CREATE OR REPLACE FUNCTION gq_private.gq_block_premature_partial_shipped_v118()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $func$
BEGIN
 IF OLD.workflow_stage='shipped' AND NEW.workflow_stage='preparing'
 AND EXISTS(SELECT 1 FROM public.gq_partial_parcel_items_v118 l
 JOIN public.gq_quote_items i ON i.id=l.item_id WHERE i.quote_id=OLD.id) THEN
  RAISE EXCEPTION '부분배송 기록이 있는 주문은 송장 이력을 유지해야 해요' USING errcode='22023';
 END IF;
 IF NEW.workflow_stage='shipped' AND coalesce(OLD.workflow_stage,'new')<>'shipped'
 AND EXISTS(SELECT 1 FROM public.gq_partial_parcel_items_v118 l
  JOIN public.gq_quote_items i ON i.id=l.item_id WHERE i.quote_id=OLD.id)
 AND EXISTS(SELECT 1 FROM public.gq_quote_items i WHERE i.quote_id=OLD.id AND i.fulfillment<>'sold_out'
  AND (SELECT coalesce(sum(l.quantity),0) FROM public.gq_partial_parcel_items_v118 l WHERE l.item_id=i.id)<i.quantity)
 THEN
  RAISE EXCEPTION '부분발송 후 남은 상품이 있어 전체 배송 중으로 변경할 수 없어요' USING errcode='22023';
 END IF;
 RETURN NEW;
END;
$func$;
CREATE TRIGGER gq_block_premature_partial_shipped_v118
 BEFORE UPDATE OF workflow_stage ON public.gq_quotes FOR EACH ROW
 EXECUTE FUNCTION gq_private.gq_block_premature_partial_shipped_v118();

REVOKE ALL ON FUNCTION public.gq_admin_create_partial_parcel_v118(uuid,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gq_admin_list_partial_parcels_v118() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gq_read_partial_parcels_v118(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gq_admin_create_partial_parcel_v118(uuid,text,text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gq_admin_list_partial_parcels_v118() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gq_read_partial_parcels_v118(uuid,uuid) TO anon,authenticated;
