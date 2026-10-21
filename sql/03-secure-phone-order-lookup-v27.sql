-- MINIYENA secure cross-browser order recovery (v27)
-- REQUIREMENTS
--   1. Supabase Authentication > Providers > Phone enabled.
--   2. SMS provider (Twilio etc.) configured and tested with Korean +82 numbers.
--   3. Run this entire migration in your Supabase SQL editor.
--   4. DO NOT grant anonymous access to the private order lookup function.
--
-- Orders lacking a saved mobile number cannot be recovered by phone:
-- send the existing private order link from admin instead.
-- Never look up full orders or shipping addresses by name/phone alone.

begin;

do $preflight$
begin
  if to_regclass('public.gq_quotes') is null then
    raise exception 'Required table public.gq_quotes not found';
  end if;
  if (
    select count(*) from information_schema.columns
    where table_schema='public' and table_name='gq_quotes'
      and column_name in ('id','lookup_token','buyer_name','baby_name','contact','created_at')
  ) <> 6 then
    raise exception 'Verify public.gq_quotes required columns before applying v27';
  end if;
  if to_regclass('auth.users') is null then
    raise exception 'Supabase Auth users table not found';
  end if;
end
$preflight$;

-- Anonymous capability check: only reports availability, never order data.
create or replace function public.gq_phone_lookup_ready_v27()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$ select true $$;

revoke all on function public.gq_phone_lookup_ready_v27() from public;
grant execute on function public.gq_phone_lookup_ready_v27() to anon, authenticated;

-- Executable ONLY with verified Supabase Auth phone session.
-- The phone comes from auth.users after verified OTP, not from client arguments.
-- Return only the existing private-link credentials for matching records.
create or replace function public.gq_phone_orders_v27(p_buyer_name text default null)
returns table(
  id text,
  lookup_token text,
  buyer_name text,
  baby_name text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  signed_in_phone text;
  local_phone text;
  match_name text := nullif(btrim(p_buyer_name), '');
begin
  if auth.uid() is null then
    raise exception '휴대폰 인증 후 다시 조회해 주세요.' using errcode='42501';
  end if;

  select u.phone into signed_in_phone
  from auth.users u
  where u.id = auth.uid()
    and u.phone_confirmed_at is not null
  limit 1;

  if signed_in_phone is null or signed_in_phone = '' then
    raise exception '휴대폰 인증이 확인되지 않았어요.' using errcode='42501';
  end if;

  signed_in_phone := regexp_replace(signed_in_phone,'[^0-9]','','g');
  local_phone := case
    when signed_in_phone like '82%' then '0' || substring(signed_in_phone from 3)
    else signed_in_phone
  end;

  if local_phone !~ '^01[0-9]{8,9}$' then
    raise exception '인증된 국내 휴대폰 번호를 확인해 주세요.' using errcode='42501';
  end if;
  if match_name is not null and length(match_name) > 40 then
    raise exception '주문자 이름을 확인해 주세요.' using errcode='22023';
  end if;

  return query
  select q.id::text, q.lookup_token::text, q.buyer_name::text,
         q.baby_name::text, q.created_at
  from public.gq_quotes q
  where
    (case
       when regexp_replace(coalesce(q.contact::text,''),'[^0-9]','','g') like '82%'
       then '0' || substring(regexp_replace(q.contact::text,'[^0-9]','','g') from 3)
       else regexp_replace(coalesce(q.contact::text,''),'[^0-9]','','g')
     end) = local_phone
    and (match_name is null or btrim(q.buyer_name::text) = match_name)
  order by q.created_at desc, q.id desc
  limit 100;
end;
$$;

revoke all on function public.gq_phone_orders_v27(text) from public, anon;
grant execute on function public.gq_phone_orders_v27(text) to authenticated;

comment on function public.gq_phone_orders_v27(text)
is 'V27: issue existing private order lookup links only after Supabase SMS-verified phone authentication. Optional exact buyer name filter.';

commit;
