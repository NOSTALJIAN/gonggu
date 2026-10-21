-- MINIYENA order access: phone/name + 6-digit PIN, NO SMS.
-- Five wrong PIN attempts per phone lock lookups for 30 minutes.
create table if not exists public.gq_order_lookup_pins_v28(
 quote_id uuid primary key references public.gq_quotes(id) on delete cascade,
 pin_hash text not null,updated_at timestamptz not null default now());
alter table public.gq_order_lookup_pins_v28 enable row level security;
revoke all on public.gq_order_lookup_pins_v28 from public,anon,authenticated;
create table if not exists public.gq_pin_attempts_v28(
 phone_hash text primary key,failures integer not null default 0,
 last_attempt_at timestamptz not null default now(),locked_until timestamptz);
alter table public.gq_pin_attempts_v28 enable row level security;
revoke all on public.gq_pin_attempts_v28 from public,anon,authenticated;

create or replace function public.gq_save_lookup_pin_v28(p_quote_id uuid,p_lookup_token uuid,p_lookup_pin text)
returns boolean language plpgsql volatile security definer set search_path='' as $$
begin
 if p_lookup_pin is null or p_lookup_pin !~ '^[0-9]{6}$' then
  raise exception '조회 비밀번호는 숫자 6자리로 입력해 주세요.' using errcode='22023';
 end if;
 if not exists(select 1 from public.gq_quotes q where q.id=p_quote_id and q.lookup_token=p_lookup_token) then
  raise exception '주문조회 링크를 확인해 주세요.' using errcode='42501';
 end if;
 insert into public.gq_order_lookup_pins_v28(quote_id,pin_hash,updated_at)
 values(p_quote_id,extensions.crypt(p_lookup_pin,extensions.gen_salt('bf',10)),now())
 on conflict(quote_id) do update set pin_hash=excluded.pin_hash,updated_at=now();
 return true;
end $$;
revoke all on function public.gq_save_lookup_pin_v28(uuid,uuid,text) from public;
grant execute on function public.gq_save_lookup_pin_v28(uuid,uuid,text) to anon,authenticated;

-- New checkout creates an order and the PIN atomically.
create or replace function public.gq_request_quote_v29(
 p_name text,p_baby_name text,p_contact text,p_note text,p_items jsonb,p_customer_key uuid,
 p_delivery_method text,p_recipient_name text,p_postal_code text,p_address_line1 text,
 p_address_line2 text,p_delivery_note text,p_lookup_pin text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare result jsonb; contact_digits text;
begin
 contact_digits:=regexp_replace(coalesce(p_contact,''),'[^0-9]','','g');
 if contact_digits !~ '^01[0-9]{8,9}$' then
  raise exception '휴대폰 번호를 확인해 주세요.' using errcode='22023';
 end if;
 if p_lookup_pin is null or p_lookup_pin !~ '^[0-9]{6}$' then
  raise exception '조회 비밀번호는 숫자 6자리로 입력해 주세요.' using errcode='22023';
 end if;
 result:=public.gq_request_quote_v8(
  p_name,p_baby_name,contact_digits,p_note,p_items,p_customer_key,
  p_delivery_method,p_recipient_name,p_postal_code,p_address_line1,p_address_line2,p_delivery_note);
 perform public.gq_save_lookup_pin_v28((result->>'id')::uuid,(result->>'token')::uuid,p_lookup_pin);
 return result;
end $$;
revoke all on function public.gq_request_quote_v29(text,text,text,text,jsonb,uuid,text,text,text,text,text,text,text) from public;
grant execute on function public.gq_request_quote_v29(text,text,text,text,jsonb,uuid,text,text,text,text,text,text,text) to anon,authenticated;

-- Anonymous lookup is PIN-gated, phone-rate-limited and never exposes orders without a matching PIN.
create or replace function public.gq_lookup_by_details_v28(p_buyer_name text,p_contact text,p_lookup_pin text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
 buyer text:=btrim(coalesce(p_buyer_name,''));
 phone text:=regexp_replace(coalesce(p_contact,''),'[^0-9]','','g');
 identity_hash text;
 attempts public.gq_pin_attempts_v28%rowtype;
 found jsonb:='[]'::jsonb;
 current_time timestamptz:=clock_timestamp();
begin
 if length(buyer) not between 1 and 40 or phone !~ '^01[0-9]{8,9}$'
  or p_lookup_pin is null or p_lookup_pin !~ '^[0-9]{6}$' then
  raise exception '이름, 휴대폰 번호, 숫자 6자리 비밀번호를 확인해 주세요.' using errcode='22023';
 end if;
 identity_hash:=encode(extensions.digest('miniYena:pin:v28:'||phone,'sha256'),'hex');
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(identity_hash,26881));
 select * into attempts from public.gq_pin_attempts_v28 where phone_hash=identity_hash for update;
 if attempts.locked_until>current_time then
  raise exception '조회 시도가 많아요. 30분 후 다시 시도하거나 주문조회 링크를 이용해 주세요.' using errcode='42501';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',r.id,'lookup_token',r.lookup_token,'buyer_name',r.buyer_name,
   'baby_name',r.baby_name,'created_at',r.created_at) order by r.created_at desc),'[]'::jsonb)
 into found from (
   select q.id,q.lookup_token,q.buyer_name,q.baby_name,q.created_at
   from public.gq_quotes q
   join public.gq_order_lookup_pins_v28 pins on pins.quote_id=q.id
   where btrim(q.buyer_name)=buyer
     and (case when regexp_replace(coalesce(q.contact,''),'[^0-9]','','g') like '82%'
           then '0'||substring(regexp_replace(coalesce(q.contact,''),'[^0-9]','','g') from 3)
           else regexp_replace(coalesce(q.contact,''),'[^0-9]','','g') end)=phone
     and extensions.crypt(p_lookup_pin,pins.pin_hash)=pins.pin_hash
   order by q.created_at desc limit 100
 ) r;
 if jsonb_array_length(found)>0 then
  delete from public.gq_pin_attempts_v28 where phone_hash=identity_hash;
 else
  insert into public.gq_pin_attempts_v28(phone_hash,failures,last_attempt_at,locked_until)
  values(identity_hash,1,current_time,null)
  on conflict(phone_hash) do update
  set failures=case when public.gq_pin_attempts_v28.last_attempt_at<current_time-interval '30 minutes'
    then 1 else least(public.gq_pin_attempts_v28.failures+1,1000) end,
      last_attempt_at=current_time,
      locked_until=case
       when public.gq_pin_attempts_v28.last_attempt_at<current_time-interval '30 minutes' then null
       when public.gq_pin_attempts_v28.failures>=4 then current_time+interval '30 minutes'
       else null end;
 end if;
 return found;
end $$;
revoke all on function public.gq_lookup_by_details_v28(text,text,text) from public;
grant execute on function public.gq_lookup_by_details_v28(text,text,text) to anon,authenticated;

create or replace function public.gq_pin_lookup_ready_v28()
returns boolean language sql stable security invoker set search_path=''
as $$ select true $$;
revoke all on function public.gq_pin_lookup_ready_v28() from public;
grant execute on function public.gq_pin_lookup_ready_v28() to anon,authenticated;
