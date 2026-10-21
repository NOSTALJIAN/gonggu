-- Miniyena v32: Administrator-only product purchasing notes.
-- NEVER store supplier purchase price or private supplier name on gq_products/gq_stores:
-- both have public SELECT RLS policies for published catalog records.
create table if not exists public.gq_product_private_costs_v32 (
 product_id uuid primary key references public.gq_products(id) on delete cascade,
 supplier_name text not null default '',
 wholesale_price integer,
 updated_at timestamptz not null default now(),
 constraint gq_product_private_supplier_len check (char_length(supplier_name)<=150),
 constraint gq_product_private_wholesale_price check (wholesale_price is null or wholesale_price between 0 and 100000000)
);
alter table public.gq_product_private_costs_v32 enable row level security;
revoke all on public.gq_product_private_costs_v32 from public,anon,authenticated;
grant select on public.gq_product_private_costs_v32 to authenticated;
-- The admin-only API for updates is the checked SECURITY DEFINER RPC below.
create policy gq_product_private_admin_read_v32
on public.gq_product_private_costs_v32
for select to authenticated using ((select public.gq_is_admin()));

create or replace function public.gq_save_product_private_v32(
 p_product_id uuid,
 p_supplier_name text default '',
 p_wholesale_price integer default null
)
returns boolean
language plpgsql volatile security definer set search_path=''
as $$
begin
 if not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 if p_product_id is null or not exists(select 1 from public.gq_products where id=p_product_id) then
  raise exception '상품을 먼저 등록해 주세요.' using errcode='22023';
 end if;
 if char_length(coalesce(p_supplier_name,''))>150 then
  raise exception '비공개 도매업체명은 150자 이내로 입력해 주세요.' using errcode='22023';
 end if;
 if p_wholesale_price is not null and (p_wholesale_price<0 or p_wholesale_price>100000000) then
  raise exception '도매가는 0원 이상 1억원 이내로 입력해 주세요.' using errcode='22023';
 end if;
 insert into public.gq_product_private_costs_v32(product_id,supplier_name,wholesale_price,updated_at)
 values(p_product_id,btrim(coalesce(p_supplier_name,'')),p_wholesale_price,now())
 on conflict(product_id) do update set
 supplier_name=excluded.supplier_name,
 wholesale_price=excluded.wholesale_price,
 updated_at=now();
 return true;
end
$$;
revoke all on function public.gq_save_product_private_v32(uuid,text,integer) from public,anon;
grant execute on function public.gq_save_product_private_v32(uuid,text,integer) to authenticated;

comment on table public.gq_product_private_costs_v32
is 'MINIYENA admin-only supplier and cost data. Do not expose through public catalog API or customer quote views.';
