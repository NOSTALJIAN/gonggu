-- MINIYENA v39: Customer-facing approximate price is 1.4 times private wholesale.
-- Round only the public estimate to the nearest 1,000 KRW.
-- Actual supplier name / wholesale remain in private admin-only metadata.
create or replace function gq_private.gq_update_estimated_product_price_v37()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
begin
 if TG_OP='DELETE' then
  update public.gq_products set estimated_price=null where id=OLD.product_id;
  return OLD;
 end if;
 update public.gq_products
 set estimated_price=case
  when NEW.wholesale_price>0 then (round(NEW.wholesale_price::numeric*1.4/1000)*1000)::integer
  else null end
 where id=NEW.product_id;
 return NEW;
end $function$;

-- Refresh estimates of previously registered products.
update public.gq_products p
set estimated_price=case
 when c.wholesale_price>0 then (round(c.wholesale_price::numeric*1.4/1000)*1000)::integer
 else null end
from public.gq_product_private_costs_v32 c
where p.id=c.product_id
 and p.estimated_price is distinct from
  (case when c.wholesale_price>0 then (round(c.wholesale_price::numeric*1.4/1000)*1000)::integer else null end);
