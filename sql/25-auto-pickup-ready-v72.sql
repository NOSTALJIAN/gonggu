-- v72: an item reaching stock automatically advances a pickup order.
-- Pickup-only; courier order stages are not affected.
-- Sold-out items are excluded, but at least one saleable item must be received.
CREATE OR REPLACE FUNCTION gq_private.gq_auto_pickup_ready_v72()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_quote public.gq_quotes%ROWTYPE;
BEGIN
  -- Item changes are ordinarily admin-only; do not turn a non-admin write
  -- into a privileged order-stage transition.
  IF NOT public.gq_is_admin() THEN RETURN NEW; END IF;
  SELECT * INTO v_quote
  FROM public.gq_quotes q
  WHERE q.id=NEW.quote_id
    AND q.status='confirmed'
    AND q.delivery_method='pickup'
    AND q.workflow_stage='preparing'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;

  -- At least one live item has actually arrived, with no live item waiting.
  IF EXISTS (
    SELECT 1 FROM public.gq_quote_items i
    WHERE i.quote_id=NEW.quote_id AND i.fulfillment IN ('received','delivered')
  ) AND NOT EXISTS (
    SELECT 1 FROM public.gq_quote_items i
    WHERE i.quote_id=NEW.quote_id AND i.fulfillment IN ('ordered','delayed')
  ) THEN
    UPDATE public.gq_quotes
    SET workflow_stage='pickup_ready', workflow_updated_at=clock_timestamp()
    WHERE id=v_quote.id AND workflow_stage='preparing';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION gq_private.gq_auto_pickup_ready_v72() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER gq_auto_pickup_ready_v72
AFTER UPDATE OF fulfillment ON public.gq_quote_items
FOR EACH ROW
WHEN (
  OLD.fulfillment IS DISTINCT FROM NEW.fulfillment
  AND NEW.fulfillment IN ('received','sold_out')
)
EXECUTE FUNCTION gq_private.gq_auto_pickup_ready_v72();

-- Convert eligible existing pickup orders already fully received.
-- This preserves all fulfillment/payment/shipping data and fires
-- existing buyer pickup-ready email and push notifications.
UPDATE public.gq_quotes q
SET workflow_stage='pickup_ready', workflow_updated_at=clock_timestamp()
WHERE q.status='confirmed'
  AND q.delivery_method='pickup'
  AND q.workflow_stage='preparing'
  AND EXISTS (
    SELECT 1 FROM public.gq_quote_items i
    WHERE i.quote_id=q.id AND i.fulfillment IN ('received','delivered')
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.gq_quote_items i
    WHERE i.quote_id=q.id AND i.fulfillment IN ('ordered','delayed')
  );