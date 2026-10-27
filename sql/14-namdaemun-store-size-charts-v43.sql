-- MINIYENA v42/v43: Size charts belong to the Namdaemun store (gq_stores.id),
-- not to the administrator-only private wholesale supplier name.
-- Up to 12 images per store, shared across all products at that store.

alter table public.gq_stores
 add column if not exists size_chart_paths text[] not null default '{}'::text[];

do $$
begin
 if not exists (
  select 1 from pg_constraint
  where conname='gq_stores_chart_paths_v42'
    and conrelid='public.gq_stores'::regclass
 ) then
  alter table public.gq_stores
   add constraint gq_stores_chart_paths_v42
   check (cardinality(size_chart_paths) <= 12 and
    (cardinality(size_chart_paths)=0 or
     array_to_string(size_chart_paths,',') ~
      '^covers/[0-9a-f-]{36}[.]jpg(,covers/[0-9a-f-]{36}[.]jpg){0,11}$'));
 end if;
end $$;

-- Admin-only update. Public clients can READ chart paths from active stores,
-- but cannot update the catalog or change a store's charts.
create or replace function public.gq_save_store_size_charts_v42(
 p_store_id uuid, p_photo_paths text[]
) returns boolean
language plpgsql security definer set search_path=''
as $function$
declare v_paths text[]:=coalesce(p_photo_paths,'{}'::text[]);
begin
 if not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 if cardinality(v_paths)>12 or
    (cardinality(v_paths)>0 and
      (array_position(v_paths,null) is not null or
       array_to_string(v_paths,',') !~
       '^covers/[0-9a-f-]{36}[.]jpg(,covers/[0-9a-f-]{36}[.]jpg){0,11}$')) then
  raise exception '사이즈표는 최대 12장까지 등록할 수 있어요.' using errcode='22023';
 end if;
 update public.gq_stores set size_chart_paths=v_paths where id=p_store_id;
 if not found then
  raise exception '거래처를 찾을 수 없어요.' using errcode='22023';
 end if;
 -- Maintain the legacy public product fields for older client versions.
 update public.gq_products
 set size_chart_paths=v_paths, size_chart_path=v_paths[1]
 where store_id=p_store_id and
  (size_chart_paths is distinct from v_paths or size_chart_path is distinct from v_paths[1]);
 return true;
end $function$;
revoke all on function public.gq_save_store_size_charts_v42(uuid,text[]) from public,anon;
grant execute on function public.gq_save_store_size_charts_v42(uuid,text[]) to authenticated;

-- Retire supplier-name linkage; the ID of the selected store is canonical.
drop trigger if exists gq_apply_supplier_size_chart_v40
 on public.gq_product_private_costs_v32;

create or replace function gq_private.gq_copy_store_size_charts_v43()
returns trigger language plpgsql security invoker set search_path=''
as $function$
declare v_paths text[];
begin
 select s.size_chart_paths into v_paths
 from public.gq_stores s where s.id=new.store_id;
 v_paths:=coalesce(v_paths,'{}'::text[]);
 new.size_chart_paths:=v_paths;
 new.size_chart_path:=v_paths[1];
 return new;
end $function$;
drop trigger if exists gq_copy_store_size_charts_v43 on public.gq_products;
create trigger gq_copy_store_size_charts_v43
 before insert or update of store_id on public.gq_products
 for each row execute function gq_private.gq_copy_store_size_charts_v43();

-- Synchronize any existing products when installing this migration.
update public.gq_products p
set size_chart_paths=s.size_chart_paths,size_chart_path=s.size_chart_paths[1]
from public.gq_stores s
where p.store_id=s.id and
 (p.size_chart_paths is distinct from s.size_chart_paths or
  p.size_chart_path is distinct from s.size_chart_paths[1]);
