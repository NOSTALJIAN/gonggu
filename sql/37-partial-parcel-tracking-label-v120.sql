-- MINIYENA v120: authorized parcel history now includes the verified tracking status.
CREATE OR REPLACE FUNCTION public.gq_admin_list_partial_parcels_v118()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.gq_is_admin() THEN RAISE EXCEPTION '관리자 권한이 필요해요' USING errcode='42501'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'root_quote_id',p.root_quote_id,'carrier',p.carrier,
  'tracking_number',p.tracking_number,'created_at',p.created_at,
  'tracking_status_code', (
    SELECT t.status_code FROM gq_private.lotte_tracking_v25 t
    WHERE regexp_replace(t.tracking_number,'[[:space:]-]','','g')
       =regexp_replace(p.tracking_number,'[[:space:]-]','','g')
      AND lower(regexp_replace(coalesce(p.carrier,''),'[[:space:]]','','g'))
        IN ('롯데택배','롯데','롯데글로벌로지스','lotte','lotteglobal')
    ORDER BY t.checked_at DESC LIMIT 1
  ),
  'items',(SELECT coalesce(jsonb_agg(jsonb_build_object(
    'item_id',l.item_id,'quote_id',i.quote_id,'quantity',l.quantity,
    'name',i.product_name,'color',i.color,'size',i.size) ORDER BY i.created_at,i.id),'[]'::jsonb)
    FROM public.gq_partial_parcel_items_v118 l JOIN public.gq_quote_items i ON i.id=l.item_id WHERE l.parcel_id=p.id)
 ) ORDER BY p.created_at DESC,p.id DESC),'[]'::jsonb)
 INTO v_result FROM public.gq_partial_parcels_v118 p;
 RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gq_read_partial_parcels_v118(p_quote_id uuid, p_lookup_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_result jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.gq_quotes WHERE id=p_quote_id AND lookup_token=p_lookup_token)
 THEN RETURN '[]'::jsonb;END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'carrier',p.carrier,'tracking_number',p.tracking_number,
  'created_at',p.created_at,
  'tracking_status_code', (
    SELECT t.status_code FROM gq_private.lotte_tracking_v25 t
    WHERE regexp_replace(t.tracking_number,'[[:space:]-]','','g')
       =regexp_replace(p.tracking_number,'[[:space:]-]','','g')
      AND lower(regexp_replace(coalesce(p.carrier,''),'[[:space:]]','','g'))
        IN ('롯데택배','롯데','롯데글로벌로지스','lotte','lotteglobal')
    ORDER BY t.checked_at DESC LIMIT 1
  ),
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
$function$;
NOTIFY pgrst,'reload schema';
