-- Keep GitHub member storefront courier shipping at 3,000 KRW (including remote addresses).
-- New MINIYENA storefront remains 3,500 KRW, 6,500 KRW for remote addresses.
-- Existing order amounts and payment records are intentionally untouched.
DO $migration$
DECLARE
 fn text;
 oldpart text;
 newpart text;
BEGIN
 -- New GitHub instant orders: 3,000 KRW flat shipping.
 fn := pg_get_functiondef('public.gq_instant_purchase_github_v114(text,text,text,text,jsonb,uuid,text,text,text,text,text,text,text,text,boolean)'::regprocedure);
 oldpart := $a$THEN 3500+CASE WHEN v_remote THEN 3000 ELSE 0 END$a$;
 newpart := $a$THEN 3000$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected GitHub purchase function, shipping not changed'; END IF;
 EXECUTE replace(fn,oldpart,newpart);

 -- Editing shipping on existing direct orders must preserve storefront-specific fees.
 fn := pg_get_functiondef('public.gq_update_delivery_shipping_v113(uuid,uuid,text,text,text,text,text,text,boolean)'::regprocedure);
 oldpart := $a$declare v_result text;v_remote boolean;v_fee integer;v_is_instant boolean;$a$;
 newpart := $a$declare v_result text;v_remote boolean;v_fee integer;v_is_instant boolean;v_price_channel text;$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected delivery edit declaration'; END IF;
 fn := replace(fn,oldpart,newpart);
 oldpart := $a$select instant_purchase into v_is_instant from public.gq_quotes$a$;
 newpart := $a$select instant_purchase,price_channel into v_is_instant,v_price_channel from public.gq_quotes$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected delivery edit query'; END IF;
 fn := replace(fn,oldpart,newpart);
 oldpart := $a$3500+case when v_remote then 3000 else 0 end else 0 end;$a$;
 newpart := $a$case when v_price_channel='github' then 3000 else 3500+case when v_remote then 3000 else 0 end end else 0 end;$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected delivery edit shipping formula'; END IF;
 EXECUTE replace(fn,oldpart,newpart);

 -- Admin approval of address / delivery changes must also use 3,000 KRW for GitHub.
 fn := pg_get_functiondef('public.gq_review_delivery_v11(uuid,boolean,integer)'::regprocedure);
 oldpart := $a$3500+CASE WHEN coalesce(q.requested_remote_area,false)$a$;
 newpart := $a$CASE WHEN q.price_channel='github' THEN 3000 ELSE 3500+CASE WHEN coalesce(q.requested_remote_area,false)$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected admin delivery approval formula (start)'; END IF;
 fn := replace(fn,oldpart,newpart);
 oldpart := $a$THEN 3000 ELSE 0 END
   ELSE 3000 END ELSE 0 END;$a$;
 newpart := $a$THEN 3000 ELSE 0 END END
   ELSE 3000 END ELSE 0 END;$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected admin delivery approval formula (end)'; END IF;
 EXECUTE replace(fn,oldpart,newpart);

 -- Buyer tracking needs the price channel for accurate instructions when changing delivery.
 fn := pg_get_functiondef('public.gq_read_quote_instant_v104(uuid,uuid)'::regprocedure);
 oldpart := $a$declare v jsonb; v_instant boolean; v_remote boolean; v_requested_remote boolean;$a$;
 newpart := $a$declare v jsonb; v_instant boolean; v_remote boolean; v_requested_remote boolean; v_channel text;$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected buyer tracking declaration'; END IF;
 fn := replace(fn,oldpart,newpart);
 oldpart := $a$select q.instant_purchase,q.remote_area,q.requested_remote_area into v_instant,v_remote,v_requested_remote$a$;
 newpart := $a$select q.instant_purchase,q.remote_area,q.requested_remote_area,q.price_channel into v_instant,v_remote,v_requested_remote,v_channel$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected buyer tracking price query'; END IF;
 fn := replace(fn,oldpart,newpart);
 oldpart := $a$jsonb_build_object('instant_purchase',coalesce(v_instant,false),'remote_area'$a$;
 newpart := $a$jsonb_build_object('instant_purchase',coalesce(v_instant,false),'price_channel',v_channel,'remote_area'$a$;
 IF position(oldpart IN fn)=0 THEN RAISE EXCEPTION 'Unexpected buyer tracking JSON payload'; END IF;
 EXECUTE replace(fn,oldpart,newpart);
END $migration$;
