-- MINIYENA: admin-controlled order-lookup PIN recovery for legacy purchases (v30).
-- The real account holder must be checked by the administrator before using the UI.
-- Anonymous users cannot execute or inspect admin recovery functionality.
create or replace function public.gq_admin_pin_status_v30(p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare found jsonb;
begin
 if not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 if coalesce(array_length(p_ids,1),0)>1000 then
  raise exception '조회 건수가 너무 많아요.' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(p.quote_id::text),'[]'::jsonb) into found
 from public.gq_order_lookup_pins_v28 p
 where p.quote_id=any(coalesce(p_ids,array[]::uuid[]));
 return found;
end;
$$;
revoke all on function public.gq_admin_pin_status_v30(uuid[]) from public,anon;
grant execute on function public.gq_admin_pin_status_v30(uuid[]) to authenticated;

create or replace function public.gq_admin_set_lookup_pin_v30(
 p_quote_id uuid, p_lookup_pin text, p_contact text default null,
 p_include_unset_same_buyer boolean default false
) returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare
 q public.gq_quotes%rowtype;
 customer_phone text;
 current_phone text;
 item record;
 applied_count integer:=0;
begin
 if not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 if p_lookup_pin is null or p_lookup_pin !~ '^[0-9]{6}$' then
  raise exception '비밀번호는 숫자 6자리로 입력해 주세요.' using errcode='22023';
 end if;
 select * into q from public.gq_quotes where id=p_quote_id for update;
 if not found then raise exception '주문을 찾을 수 없어요.' using errcode='22023'; end if;
 current_phone:=regexp_replace(coalesce(q.contact,''),'[^0-9]','','g');
 customer_phone:=coalesce(nullif(regexp_replace(coalesce(p_contact,''),'[^0-9]','','g'),''),current_phone);
 if customer_phone like '82%' then customer_phone:='0'||substring(customer_phone from 3); end if;
 if customer_phone !~ '^01[0-9]{8,9}$' then
  raise exception '주문자의 휴대폰 번호를 먼저 확인하고 입력해 주세요.' using errcode='22023';
 end if;
 if p_contact is not null and btrim(p_contact) <> '' then
  update public.gq_quotes set contact=customer_phone where id=p_quote_id;
 end if;
 perform public.gq_save_lookup_pin_v28(q.id,q.lookup_token,p_lookup_pin);
 applied_count:=1;
 if p_include_unset_same_buyer then
  for item in
   select other.id,other.lookup_token
   from public.gq_quotes other
   left join public.gq_order_lookup_pins_v28 pin on pin.quote_id=other.id
   where other.id<>q.id
      and pin.quote_id is null -- Do not overwrite an existing customer-set PIN.
      and btrim(other.buyer_name)=btrim(q.buyer_name)
      and (case
        when regexp_replace(coalesce(other.contact,''),'[^0-9]','','g') like '82%'
        then '0'||substring(regexp_replace(coalesce(other.contact,''),'[^0-9]','','g') from 3)
        else regexp_replace(coalesce(other.contact,''),'[^0-9]','','g')
       end)=customer_phone
   order by other.created_at
  loop
   perform public.gq_save_lookup_pin_v28(item.id,item.lookup_token,p_lookup_pin);
   applied_count:=applied_count+1;
  end loop;
 end if;
 return jsonb_build_object('updated',applied_count);
end;
$$;
revoke all on function public.gq_admin_set_lookup_pin_v30(uuid,text,text,boolean) from public,anon;
grant execute on function public.gq_admin_set_lookup_pin_v30(uuid,text,text,boolean) to authenticated;
comment on function public.gq_admin_set_lookup_pin_v30(uuid,text,text,boolean)
is 'Admin-only legacy PIN recovery with optional update to other same buyer/phone orders that have no PIN.';
