-- MINIYENA v119. Actual verified Lotte DELIVERED updates only fully delivered courier orders.
-- Existing bridge authentication and financial fields are preserved.
CREATE OR REPLACE FUNCTION public.gq_lotte_save_tracking_v25(p_secret text, p_tracking_number text, p_status_code text, p_status_label text, p_event_time text, p_events jsonb, p_tracking_url text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_saved_secret text;
BEGIN
  SELECT bridge_secret INTO v_saved_secret
  FROM gq_private.lotte_bridge_auth_v22 WHERE singleton_id=1;
  IF v_saved_secret IS NULL OR p_secret IS DISTINCT FROM v_saved_secret THEN
    RAISE EXCEPTION 'Unauthorized tracker update';
  END IF;
  IF p_tracking_number IS NULL OR p_tracking_number !~ '^[0-9A-Za-z -]{4,80}$' THEN
    RAISE EXCEPTION 'Invalid tracking number';
  END IF;
  IF p_status_code IS NULL OR p_status_code NOT IN
    ('UNKNOWN','INFORMATION_RECEIVED','AT_PICKUP','IN_TRANSIT','OUT_FOR_DELIVERY','ATTEMPT_FAIL','DELIVERED','AVAILABLE_FOR_PICKUP','EXCEPTION') THEN
    RAISE EXCEPTION 'Invalid shipment state';
  END IF;
  IF p_events IS NULL OR jsonb_typeof(p_events)<>'array' OR jsonb_array_length(p_events)>20 OR length(p_events::text)>12000 THEN
    RAISE EXCEPTION 'Invalid shipment events';
  END IF;
  IF length(coalesce(p_status_label,''))>160 OR length(coalesce(p_tracking_url,''))>600 THEN
    RAISE EXCEPTION 'Invalid shipment content';
  END IF;
  IF coalesce(p_tracking_url,'')<>'' AND p_tracking_url NOT LIKE 'https://link.tracker.delivery/track?%' THEN
    RAISE EXCEPTION 'Invalid tracking link';
  END IF;
  IF NOT EXISTS (
     SELECT 1 FROM public.gq_quotes q
     WHERE regexp_replace(coalesce(q.tracking_number,''),'[[:space:]-]','','g')
           =regexp_replace(p_tracking_number,'[[:space:]-]','','g')
       AND q.delivery_method='courier' AND q.status='confirmed'
       AND q.workflow_stage IN ('shipped','completed')
       AND lower(regexp_replace(coalesce(q.tracking_carrier,''),'[[:space:]]','','g'))
          IN ('롯데택배','롯데','롯데글로벌로지스','lotte','lotteglobal')
  ) AND NOT EXISTS (
     SELECT 1 FROM public.gq_partial_parcels_v118 p
     JOIN public.gq_partial_parcel_items_v118 pi ON pi.parcel_id=p.id
     JOIN public.gq_quote_items i ON i.id=pi.item_id
     JOIN public.gq_quotes q ON q.id=i.quote_id
     WHERE regexp_replace(p.tracking_number,'[[:space:]-]','','g')
           =regexp_replace(p_tracking_number,'[[:space:]-]','','g')
       AND q.status='confirmed' AND q.delivery_method='courier'
       AND coalesce(q.workflow_stage,'new') IN ('new','preparing','shipped','completed')
       AND lower(regexp_replace(p.carrier,'[[:space:]]','','g'))
          IN ('롯데택배','롯데','롯데글로벌로지스','lotte','lotteglobal')
  ) THEN
    RETURN false;
  END IF;
  INSERT INTO gq_private.lotte_tracking_v25
    (tracking_number,status_code,status_label,event_time,events,checked_at,tracking_url)
  VALUES
    (p_tracking_number,p_status_code,coalesce(p_status_label,''),
     nullif(p_event_time,'')::timestamptz,p_events,clock_timestamp(),coalesce(p_tracking_url,''))
  ON CONFLICT (tracking_number) DO UPDATE SET
    status_code=excluded.status_code,
    status_label=excluded.status_label,
    event_time=excluded.event_time,
    events=excluded.events,
    checked_at=excluded.checked_at,
    tracking_url=excluded.tracking_url;
  RETURN true;
END; $function$;

CREATE OR REPLACE FUNCTION gq_private.gq_complete_lotte_deliveries_v119()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $body$
DECLARE
 v_number text;
 v_quote_ids uuid[];
BEGIN
 IF NEW.status_code IS DISTINCT FROM 'DELIVERED' THEN RETURN NEW; END IF;
 v_number:=regexp_replace(NEW.tracking_number,'[[:space:]-]','','g');
 SELECT coalesce(array_agg(q.id),'{}'::uuid[]) INTO v_quote_ids
 FROM public.gq_quotes q
 WHERE q.status='confirmed'
   AND q.delivery_method='courier'
   AND q.workflow_stage='shipped'
   AND lower(regexp_replace(coalesce(q.tracking_carrier,''),'[[:space:]]','','g'))
       IN ('롯데택배','롯데','롯데글로벌로지스','lotte','lotteglobal')
   AND (
     regexp_replace(coalesce(q.tracking_number,''),'[[:space:]-]','','g')=v_number
     OR EXISTS (
       SELECT 1 FROM public.gq_partial_parcel_items_v118 l
       JOIN public.gq_partial_parcels_v118 p ON p.id=l.parcel_id
       JOIN public.gq_quote_items i ON i.id=l.item_id
       WHERE i.quote_id=q.id
         AND regexp_replace(p.tracking_number,'[[:space:]-]','','g')=v_number
     )
   )
   AND (
     (
       NOT EXISTS (
         SELECT 1 FROM public.gq_partial_parcel_items_v118 l
         JOIN public.gq_quote_items i ON i.id=l.item_id WHERE i.quote_id=q.id
       )
       AND regexp_replace(coalesce(q.tracking_number,''),'[[:space:]-]','','g')=v_number
     )
     OR (
       EXISTS (
         SELECT 1 FROM public.gq_partial_parcel_items_v118 l
         JOIN public.gq_quote_items i ON i.id=l.item_id WHERE i.quote_id=q.id
       )
       AND NOT EXISTS (
         SELECT 1 FROM public.gq_quote_items i
         WHERE i.quote_id=q.id AND i.fulfillment<>'sold_out'
           AND (SELECT coalesce(sum(l.quantity),0) FROM public.gq_partial_parcel_items_v118 l
                WHERE l.item_id=i.id)<i.quantity
       )
       AND NOT EXISTS (
         SELECT 1 FROM public.gq_partial_parcel_items_v118 l
         JOIN public.gq_quote_items i ON i.id=l.item_id
         JOIN public.gq_partial_parcels_v118 p ON p.id=l.parcel_id
         WHERE i.quote_id=q.id
           AND NOT EXISTS (
             SELECT 1 FROM gq_private.lotte_tracking_v25 t
             WHERE regexp_replace(t.tracking_number,'[[:space:]-]','','g')
                  =regexp_replace(p.tracking_number,'[[:space:]-]','','g')
               AND t.status_code='DELIVERED'
           )
       )
     )
   );

 IF cardinality(v_quote_ids)>0 THEN
   UPDATE public.gq_quote_items SET fulfillment='delivered'
    WHERE quote_id=ANY(v_quote_ids) AND fulfillment='received';
   UPDATE public.gq_quotes SET
     workflow_stage='completed',
     workflow_updated_at=clock_timestamp()
    WHERE id=ANY(v_quote_ids) AND status='confirmed' AND workflow_stage='shipped';
 END IF;
 RETURN NEW;
END;
$body$;

REVOKE ALL ON FUNCTION gq_private.gq_complete_lotte_deliveries_v119() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS gq_lotte_delivered_v119 ON gq_private.lotte_tracking_v25;
CREATE TRIGGER gq_lotte_delivered_v119
AFTER INSERT OR UPDATE OF status_code ON gq_private.lotte_tracking_v25
FOR EACH ROW EXECUTE FUNCTION gq_private.gq_complete_lotte_deliveries_v119();
NOTIFY pgrst,'reload schema';
