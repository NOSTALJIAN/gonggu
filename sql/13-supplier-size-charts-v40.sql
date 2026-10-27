-- MINIYENA v40. One customer-visible image per private wholesale supplier.
-- Store the supplier/image association in gq_private, and only publish a photo path.
-- The existing public catalog stays readable; actual supplier names remain restricted.

alter table public.gq_products
 add column if not exists size_chart_path text;
alter table public.gq_products
 add constraint gq_products_size_chart_path_v40
 check (size_chart_path is null or size_chart_path ~ '^covers/[0-9a-f-]{36}[.]jpg$');

create table if not exists gq_private.gq_supplier_size_charts_v40 (
 supplier_name text primary key,
 photo_path text not null,
 updated_at timestamptz not null default now(),
 constraint gq_supplier_size_charts_name_v40 check (char_length(btrim(supplier_name)) between 1 and 150 and supplier_name=btrim(supplier_name)),
 constraint gq_supplier_size_charts_path_v40 check (photo_path ~ '^covers/[0-9a-f-]{36}[.]jpg$')
);
alter table gq_private.gq_supplier_size_charts_v40 enable row level security;
revoke all on gq_private.gq_supplier_size_charts_v40 from public, anon, authenticated;

create or replace function public.gq_list_supplier_size_charts_v40()
returns table(supplier_name text, photo_path text)
language plpgsql stable security definer set search_path=''
as $function$
begin
 if not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 return query
 select c.supplier_name, c.photo_path
 from gq_private.gq_supplier_size_charts_v40 c
 order by c.supplier_name;
end $function$;
revoke all on function public.gq_list_supplier_size_charts_v40() from public, anon;
grant execute on function public.gq_list_supplier_size_charts_v40() to authenticated;

create or replace function gq_private.gq_apply_supplier_size_chart_v40()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare v_path text;
begin
 select c.photo_path into v_path
 from gq_private.gq_supplier_size_charts_v40 c
 where c.supplier_name=btrim(coalesce(new.supplier_name,''));
 update public.gq_products
 set size_chart_path=v_path
 where id=new.product_id and size_chart_path is distinct from v_path;
 return new;
end $function$;
drop trigger if exists gq_apply_supplier_size_chart_v40 on public.gq_product_private_costs_v32;
create trigger gq_apply_supplier_size_chart_v40
 after insert or update of supplier_name
 on public.gq_product_private_costs_v32
 for each row execute function gq_private.gq_apply_supplier_size_chart_v40();

create or replace function public.gq_save_supplier_size_chart_v40(
 p_supplier_name text, p_photo_path text default null
) returns boolean
language plpgsql volatile security definer set search_path=''
as $function$
declare
 v_supplier text:=btrim(coalesce(p_supplier_name,''));
 v_path text:=nullif(btrim(coalesce(p_photo_path,'')),'');
begin
 if not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 if char_length(v_supplier) < 1 or char_length(v_supplier) > 150 then
  raise exception '도매업체명을 확인해 주세요.' using errcode='22023';
 end if;
 if v_path is not null and v_path !~ '^covers/[0-9a-f-]{36}[.]jpg$' then
  raise exception '등록한 사이즈표 사진 경로를 확인해 주세요.' using errcode='22023';
 end if;
 if v_path is null then
  delete from gq_private.gq_supplier_size_charts_v40 where supplier_name=v_supplier;
 else
  insert into gq_private.gq_supplier_size_charts_v40(supplier_name,photo_path,updated_at)
  values(v_supplier,v_path,now())
  on conflict(supplier_name) do update set
   photo_path=excluded.photo_path, updated_at=now();
 end if;
 update public.gq_products p
 set size_chart_path=v_path
 from public.gq_product_private_costs_v32 c
 where p.id=c.product_id and btrim(c.supplier_name)=v_supplier
  and p.size_chart_path is distinct from v_path;
 return true;
end $function$;
revoke all on function public.gq_save_supplier_size_chart_v40(text,text) from public, anon;
grant execute on function public.gq_save_supplier_size_chart_v40(text,text) to authenticated;
