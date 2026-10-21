-- Disposable PostgreSQL test database only; never run this fixture in Supabase.
create role anon;
create role authenticated;
create role service_role;
create table public.gq_quotes (
 id uuid primary key, lookup_token text, bundle_parent_id uuid,
 status text, delivery_method text, tracking_carrier text, tracking_number text,
 workflow_stage text, amount_paid integer
);
insert into public.gq_quotes values
 ('00000000-0000-0000-0000-000000000001','root-token',null,'confirmed','courier','롯데택배','1234-5678','completed',50000),
 ('00000000-0000-0000-0000-000000000002','child-token','00000000-0000-0000-0000-000000000001','confirmed','courier',null,null,'shipped',10000),
 ('00000000-0000-0000-0000-000000000003','other-token',null,'confirmed','courier','롯데택배','99999999','shipped',30000);
alter table public.gq_quotes enable row level security;
revoke all on public.gq_quotes from public,anon,authenticated;
create function public.gq_read_quote(p_quote_id uuid,p_lookup_token text) returns jsonb
language sql security definer set search_path=pg_catalog,public as $$
 select to_jsonb(q)-'lookup_token' from public.gq_quotes q
 where q.id=p_quote_id and q.lookup_token=p_lookup_token
$$;
revoke all on function public.gq_read_quote(uuid,text) from public;
grant execute on function public.gq_read_quote(uuid,text) to anon,authenticated;
create function public.gq_is_admin() returns boolean language sql as $$
 select coalesce(current_setting('app.test_admin',true),'false')='true'
$$;
