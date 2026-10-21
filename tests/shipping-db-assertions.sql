-- Run after the fixture and optional migration in a disposable database only.
\set ON_ERROR_STOP on
set role service_role;
select public.gq_lotte_store_details_v26('12345678','IN_TRANSIT','테스트 API 상태',null,
 '[{"time":"2026-10-21T12:00:00+09:00","location":{"name":"테스트 위치"},"status":{"name":"테스트 이력"}}]',null);
reset role;
set role anon;
do $$ declare payload jsonb; begin
 payload:=public.gq_read_shipping_v26('00000000-0000-0000-0000-000000000002','child-token');
 if payload->>'tracking_number'<>'12345678' or jsonb_array_length(payload->'shipment_tracking'->'events')<>1
 then raise exception 'Child did not inherit actual shared history'; end if;
 if payload::text like '%root-token%' or payload::text like '%other-token%'
 then raise exception 'Leaked lookup token'; end if;
 begin
  perform public.gq_read_shipping_v26('00000000-0000-0000-0000-000000000002','wrong');
  raise exception 'Invalid token accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform public.gq_shipping_payload_v26('00000000-0000-0000-0000-000000000001');
  raise exception 'Internal helper exposed';
 exception when insufficient_privilege then null; end;
 begin
  perform public.gq_lotte_store_details_v26('12345678',null,null,null,'[]',null);
  raise exception 'Anonymous writer accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform 1 from public.gq_shipment_details_v26;
  raise exception 'Anonymous table read accepted';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
set role authenticated;
do $$ begin
 begin
  perform public.gq_read_admin_shipping_v26(array['00000000-0000-0000-0000-000000000001']);
  raise exception 'Non-admin read accepted';
 exception when insufficient_privilege then null; end;
end $$;
set app.test_admin='true';
do $$ declare payload jsonb; begin
 payload:=public.gq_read_admin_shipping_v26(array['00000000-0000-0000-0000-000000000002']);
 if payload->'00000000-0000-0000-0000-000000000002'->>'tracking_number'<>'12345678'
 then raise exception 'Admin shared invoice missing'; end if;
end $$;
reset role;
do $$ begin
 if (select workflow_stage from public.gq_quotes where lookup_token='root-token')<>'completed'
 or (select workflow_stage from public.gq_quotes where lookup_token='child-token')<>'shipped'
 or (select amount_paid from public.gq_quotes where lookup_token='root-token')<>50000
 then raise exception 'Existing order data changed'; end if;
end $$;
-- Conflicting and stale invoices must not expose unrelated histories.
update public.gq_quotes set tracking_carrier='롯데택배',tracking_number='99999999' where lookup_token='child-token';
do $$ begin
 if public.gq_shipping_payload_v26('00000000-0000-0000-0000-000000000002')<>'{}'::jsonb
 then raise exception 'Conflicting invoices shared history'; end if;
end $$;
update public.gq_quotes set tracking_number='88888888' where lookup_token in ('root-token','child-token');
do $$ declare payload jsonb; begin
 payload:=public.gq_shipping_payload_v26('00000000-0000-0000-0000-000000000002');
 if payload->'shipment_tracking'<>'null'::jsonb then raise exception 'Stale history returned'; end if;
end $$;
select 'PASS: token authorization, admin gate, private storage, shared shipment, conflict/stale protection, unchanged workflow/payment' as result;
