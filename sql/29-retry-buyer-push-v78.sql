-- v78: retry temporary push failures and recover stuck processing jobs.
-- Do not blindly retry notifications that have no subscribed recipient.
CREATE OR REPLACE FUNCTION gq_private.gq_retry_buyer_push_v78()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_reopened integer:=0; v_secret text;
BEGIN
 WITH candidates AS (
  SELECT id FROM public.gq_push_outbox
  WHERE created_at>now()-interval '24 hours'
    AND (
     (state='failed' AND attempts<3
       AND coalesce(last_error,'') !~* 'no active subscriptions|not subscribed|no subscription')
      OR
     (state='processing' AND created_at<now()-interval '10 minutes' AND attempts<3)
    )
  ORDER BY id LIMIT 40 FOR UPDATE SKIP LOCKED
 )
 UPDATE public.gq_push_outbox o
 SET state='pending',last_error=NULL
 FROM candidates c WHERE o.id=c.id;
 GET DIAGNOSTICS v_reopened=ROW_COUNT;

 IF EXISTS(SELECT 1 FROM public.gq_push_outbox WHERE state='pending') THEN
  SELECT secret INTO v_secret FROM gq_private.gq_push_webhook_auth WHERE id=1;
  IF v_secret IS NOT NULL THEN
   PERFORM net.http_post(
    url:='https://nokwzazxjqesyvwvqpvi.supabase.co/functions/v1/gq-dispatch-push',
    body:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-gq-webhook-secret',v_secret),
    timeout_milliseconds:=8000
   );
  END IF;
 END IF;
 RETURN v_reopened;
END;
$function$;
REVOKE ALL ON FUNCTION gq_private.gq_retry_buyer_push_v78() FROM PUBLIC,anon,authenticated;
SELECT cron.schedule('miniyena-buyer-push-retry-v78','*/3 * * * *',
 'select gq_private.gq_retry_buyer_push_v78();');