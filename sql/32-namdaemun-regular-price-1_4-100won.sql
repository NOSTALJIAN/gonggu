-- MINIYENA pricing consistency (production-applied)
-- New storefront: Namdaemun wholesale x1.4, rounded to KRW 100.
-- GitHub storefront: Namdaemun wholesale x1.2, unchanged.
-- Existing quote/order/payment amounts are not touched.
create or replace function gq_private.gq_update_estimated_product_price_v37()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
begin
 if TG_OP='DELETE' then
  update public.gq_products set estimated_price=null,github_estimated_price=null where id=old.product_id;
  return old;
 end if;
 update public.gq_products set
  estimated_price=case
   when new.source_type='1688' and new.yuan_price>0 then round(new.yuan_price*600)::integer
   when new.source_type='namdaemun' and new.wholesale_price>0 then (round(new.wholesale_price::numeric*1.4/100)*100)::integer
   else null end,
  github_estimated_price=case
   when new.source_type='1688' and new.yuan_price>0 then round(new.yuan_price*500)::integer
   when new.source_type='namdaemun' and new.wholesale_price>0 then round(new.wholesale_price::numeric*1.2)::integer
   else null end
 where id=new.product_id;
 return new;
end $function$;

-- Bring existing published Namdaemun estimates in line with the same formula.
update public.gq_products p
set estimated_price=(round(c.wholesale_price::numeric*1.4/100)*100)::integer
from public.gq_product_private_costs_v32 c
where p.id=c.product_id
  and c.source_type='namdaemun'
  and c.wholesale_price>0
  and p.estimated_price is distinct from (round(c.wholesale_price::numeric*1.4/100)*100)::integer;
