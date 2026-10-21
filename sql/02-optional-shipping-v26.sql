-- OPTIONAL, NOT APPLIED TO PRODUCTION. Run 01-inspect-shipping.sql first.
-- Additive alternative if v25 does not already persist/expose delivery history.
-- Does not replace existing RPCs, alter gq_quotes, or update workflow/payment data.
-- Atomic: an unsupported existing signature or name conflict rolls back everything.
begin;

do $preflight$
declare f record;
begin
  if to_regclass('public.gq_quotes') is null then raise exception 'gq_quotes is missing'; end if;
  if (select count(*) from information_schema.columns where table_schema='public'
      and table_name='gq_quotes' and column_name in
      ('id','bundle_parent_id','status','delivery_method','tracking_carrier','tracking_number')) <> 6
  then raise exception 'Inspect gq_quotes: required shipping columns differ'; end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='gq_read_quote') <> 1
  then raise exception 'Inspect gq_read_quote: expected one unambiguous overload'; end if;
  select p.* into f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='gq_read_quote';
  if not f.prosecdef or f.pronargs <> 2 or f.proretset or f.prorettype not in ('json'::regtype,'jsonb'::regtype)
     or f.proargnames[1] is distinct from 'p_quote_id'
     or f.proargnames[2] is distinct from 'p_lookup_token'
     or f.proargtypes[0] not in ('uuid'::regtype,'text'::regtype,'varchar'::regtype)
     or f.proargtypes[1] not in ('uuid'::regtype,'text'::regtype,'varchar'::regtype)
  then raise exception 'Unsupported gq_read_quote signature; inspect before adapting migration'; end if;
  if not exists (select 1 from pg_proc where oid=to_regprocedure('public.gq_is_admin()')
    and prorettype='boolean'::regtype and not proretset)
  then raise exception 'Inspect administrator authorization function'; end if;
end
$preflight$;

create table public.gq_shipment_details_v26 (
  tracking_number text primary key check (tracking_number ~ '^[0-9]{4,30}$'),
  status_code text,
  status_label text,
  event_time text,
  events jsonb not null default '[]'::jsonb check (jsonb_typeof(events)='array'),
  tracking_url text,
  fetched_at timestamptz not null default now()
);
alter table public.gq_shipment_details_v26 enable row level security;
revoke all on public.gq_shipment_details_v26 from public, anon, authenticated;
-- No public read/write policies. Browser access only through authorized read RPCs.

create function public.gq_lotte_store_details_v26(
  p_tracking_number text, p_status_code text, p_status_label text,
  p_event_time text, p_events jsonb, p_tracking_url text
) returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare invoice text := regexp_replace(p_tracking_number,'[[:space:]-]','','g');
begin
  if invoice is null or invoice !~ '^[0-9]{4,30}$'
     or p_events is null or jsonb_typeof(p_events)<>'array'
  then raise exception 'Invalid invoice or events'; end if;
  -- Caller supplies only a successful, actual Delivery Tracker response.
  -- Never call this RPC for lookup errors/timeouts or manufacture empty events.
  insert into public.gq_shipment_details_v26 as saved
    (tracking_number,status_code,status_label,event_time,events,tracking_url,fetched_at)
  values(invoice,p_status_code,p_status_label,p_event_time,p_events,p_tracking_url,now())
  on conflict(tracking_number) do update set
    status_code=excluded.status_code,status_label=excluded.status_label,
    event_time=excluded.event_time,events=excluded.events,
    tracking_url=excluded.tracking_url,fetched_at=excluded.fetched_at;
end $$;
revoke all on function public.gq_lotte_store_details_v26(text,text,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.gq_lotte_store_details_v26(text,text,text,text,jsonb,text) to service_role;

-- Internal helper. Only authorized wrappers below may invoke it.
create function public.gq_shipping_payload_v26(p_quote_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare shipments jsonb; shipment jsonb; details jsonb;
begin
  with recursive ancestors as (
    select to_jsonb(q) as data, array[q.id::text] as path
    from public.gq_quotes q where q.id::text=p_quote_id and q.status<>'cancelled'
    union all
    select to_jsonb(parent),a.path||parent.id::text
    from ancestors a join public.gq_quotes parent on parent.id::text=a.data->>'bundle_parent_id'
    where parent.status<>'cancelled' and not parent.id::text=any(a.path)
  ), root as (
    select data,path from ancestors order by cardinality(path) desc limit 1
  ), members as (
    select data,array[data->>'id'] as path from root
    union all
    select to_jsonb(child),m.path||child.id::text
    from members m join public.gq_quotes child on child.bundle_parent_id::text=m.data->>'id'
    where child.status<>'cancelled' and not child.id::text=any(m.path)
  ), pairs as (
    select distinct
      case when lower(regexp_replace(data->>'tracking_carrier','[[:space:]]','','g'))
        in ('롯데택배','롯데','롯데글로벌로지스','lotte','lotteglobal') then 'lotte'
        else lower(btrim(data->>'tracking_carrier')) end as carrier,
      regexp_replace(data->>'tracking_number','[[:space:]-]','','g') as invoice
    from members where data->>'delivery_method'='courier'
      and nullif(btrim(data->>'tracking_carrier'),'') is not null
      and nullif(btrim(data->>'tracking_number'),'') is not null
  ) select jsonb_agg(jsonb_build_object('carrier',carrier,'invoice',invoice)) into shipments from pairs;
  if jsonb_array_length(shipments) is distinct from 1 then return '{}'::jsonb; end if;
  shipment:=shipments->0;
  -- Other carriers are not silently converted to Lotte.
  if shipment->>'carrier'<>'lotte' then return '{}'::jsonb; end if;
  select jsonb_build_object(
    'source','delivery-tracker','carrier_id','kr.lotte','tracking_number',d.tracking_number,
    'status',d.status_label,'status_code',d.status_code,'event_time',d.event_time,
    'events',d.events,'fetched_at',d.fetched_at
  ) into details from public.gq_shipment_details_v26 d
    where d.tracking_number=shipment->>'invoice';
  return jsonb_build_object('tracking_carrier','롯데택배',
    'tracking_number',shipment->>'invoice','shipment_tracking',details);
end $$;
revoke all on function public.gq_shipping_payload_v26(text) from public,anon,authenticated;

-- Generate the existing read call using its inspected argument types, not a guessed UUID signature.
do $reader$
declare f record; definition text;
begin
  select p.oid,p.proargtypes into f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='gq_read_quote';
  definition:=format($fn$
    create function public.gq_read_shipping_v26(p_quote_id text,p_lookup_token text)
    returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $body$
    declare authorized_quote jsonb;
    begin
      authorized_quote:=to_jsonb(public.gq_read_quote(p_quote_id::%s,p_lookup_token::%s));
      if authorized_quote is null or authorized_quote='null'::jsonb
         or authorized_quote->>'id' is distinct from p_quote_id
      then raise exception 'Quote not found or invalid lookup token' using errcode='42501'; end if;
      if authorized_quote->>'status'='cancelled'
         or authorized_quote->>'delivery_method' is distinct from 'courier'
      then return '{}'::jsonb; end if;
      return public.gq_shipping_payload_v26(p_quote_id);
    end $body$;
  $fn$,format_type(f.proargtypes[0],null),format_type(f.proargtypes[1],null));
  execute definition;
  revoke all on function public.gq_read_shipping_v26(text,text) from public,anon,authenticated;
  -- Preserve the original read RPC's caller roles; never broaden token-read permissions.
  if has_function_privilege('anon',f.oid,'EXECUTE') then
    grant execute on function public.gq_read_shipping_v26(text,text) to anon;
  end if;
  if has_function_privilege('authenticated',f.oid,'EXECUTE') then
    grant execute on function public.gq_read_shipping_v26(text,text) to authenticated;
  end if;
end
$reader$;

create function public.gq_read_admin_shipping_v26(p_quote_ids text[])
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare result jsonb;
begin
  if public.gq_is_admin() is distinct from true then
    raise exception 'Administrator required' using errcode='42501'; end if;
  if p_quote_ids is null or cardinality(p_quote_ids)>200 then raise exception 'At most 200 quote IDs'; end if;
  select coalesce(jsonb_object_agg(id,public.gq_shipping_payload_v26(id)),'{}'::jsonb)
    into result from (select distinct unnest(p_quote_ids) as id) ids;
  return result;
end $$;
revoke all on function public.gq_read_admin_shipping_v26(text[]) from public,anon,authenticated;
grant execute on function public.gq_read_admin_shipping_v26(text[]) to authenticated;
notify pgrst,'reload schema';
commit;
