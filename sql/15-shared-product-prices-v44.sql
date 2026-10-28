-- MINIYENA v44: share saved selling prices by exact catalog product_id.
-- Actual saved prices remain PRIVATE. The public catalog keeps only
-- estimated_price (wholesale × 1.4 rounded to KRW 1,000).
--
-- Auto-update ONLY currently unpriced, non-soldout items in quotes with
-- status=requested. Existing prices and quoted/confirmed/cancelled items are
-- preserved. Newly requested items reuse the last admin-saved product price.

create table if not exists gq_private.gq_product_saved_prices_v44(
 product_id uuid primary key references public.gq_products(id) on delete cascade,
 unit_price integer not null check(unit_price between 0 and 100000000),
 updated_at timestamptz not null default now()
);
alter table gq_private.gq_product_saved_prices_v44 enable row level security;
revoke all on gq_private.gq_product_saved_prices_v44 from public,anon,authenticated;

-- Bootstrap only products with a consistent historical selling price.
insert into gq_private.gq_product_saved_prices_v44(product_id,unit_price)
select i.product_id,max(i.unit_price)
from public.gq_quote_items i
join public.gq_quotes q on q.id=i.quote_id
join public.gq_products p on p.id=i.product_id
where i.product_id is not null and i.unit_price is not null
 and q.status in ('requested','quoted','confirmed')
group by i.product_id
having count(distinct i.unit_price)=1
on conflict(product_id) do nothing;

create or replace function gq_private.gq_apply_saved_product_price_v44()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare v_price integer;
begin
 if new.unit_price is not null or new.product_id is null then return new; end if;
 if not exists (
  select 1 from public.gq_quotes q where q.id=new.quote_id and q.status='requested'
 ) then return new; end if;
 select d.unit_price into v_price from gq_private.gq_product_saved_prices_v44 d
 where d.product_id=new.product_id;
 if found then new.unit_price:=v_price; end if;
 return new;
end $function$;
revoke all on function gq_private.gq_apply_saved_product_price_v44() from public,anon,authenticated;
drop trigger if exists gq_apply_saved_product_price_v44 on public.gq_quote_items;
create trigger gq_apply_saved_product_price_v44
before insert on public.gq_quote_items
for each row execute function gq_private.gq_apply_saved_product_price_v44();

create or replace function public.gq_admin_set_product_price_v44(
 p_item_id uuid,p_unit_price integer
) returns jsonb
language plpgsql volatile security definer set search_path=''
as $function$
declare v_product_id uuid; v_status text; v_auto integer:=0;
begin
 if not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 if p_item_id is null or p_unit_price is null or
    p_unit_price<0 or p_unit_price>100000000 then
  raise exception '개당 가격은 0원부터 1억원까지 입력해 주세요.' using errcode='22023';
 end if;

 select i.product_id,q.status into v_product_id,v_status
 from public.gq_quote_items i join public.gq_quotes q on q.id=i.quote_id
 where i.id=p_item_id for update of i;
 if not found then raise exception '견적 상품을 찾지 못했어요.' using errcode='22023'; end if;
 if v_status='cancelled' then
  raise exception '취소된 주문의 가격은 변경할 수 없어요.' using errcode='22023';
 end if;

 update public.gq_quote_items set unit_price=p_unit_price where id=p_item_id;

 if v_product_id is not null then
  insert into gq_private.gq_product_saved_prices_v44(product_id,unit_price,updated_at)
  values(v_product_id,p_unit_price,clock_timestamp())
  on conflict(product_id) do update
   set unit_price=excluded.unit_price,updated_at=excluded.updated_at;

  with affected as (
   update public.gq_quote_items i set unit_price=p_unit_price
   from public.gq_quotes q
   where q.id=i.quote_id and i.id<>p_item_id and i.product_id=v_product_id
    and i.unit_price is null and i.fulfillment<>'sold_out' and q.status='requested'
   returning i.id
  ) select count(*)::integer into v_auto from affected;
 end if;
 return jsonb_build_object('updated',v_auto+1,'auto_updated',v_auto);
end $function$;
revoke all on function public.gq_admin_set_product_price_v44(uuid,integer) from public,anon;
grant execute on function public.gq_admin_set_product_price_v44(uuid,integer) to authenticated;

-- One-time backfill of unfinished rows, using previously saved prices.
-- This cannot overwrite existing, published or cancelled prices.
update public.gq_quote_items i set unit_price=d.unit_price
from gq_private.gq_product_saved_prices_v44 d,public.gq_quotes q
where i.product_id=d.product_id and i.quote_id=q.id
 and i.unit_price is null and i.fulfillment<>'sold_out' and q.status='requested';
