-- MINIYENA v31: separate merchandising visibility from product sold-out status,
-- and keep a structured rejection reason on customer product-submission requests.
-- Additive: existing products remain in-stock; published/hidden flags remain unchanged.
alter table public.gq_products
  add column if not exists is_sold_out boolean not null default false;

alter table public.gq_product_requests
  add column if not exists rejection_reason text,
  add column if not exists rejection_note text;

alter table public.gq_product_requests
  add constraint gq_product_requests_rejection_reason_v31_check
    check (rejection_reason is null or rejection_reason in
      ('품절','거래처 확인 불가','상품 정보 부족','중복 신청','기타')),
  add constraint gq_product_requests_rejection_note_v31_check
    check (rejection_note is null or char_length(rejection_note) <= 300);

-- Old cached customer sessions must not be able to request a product that
-- became sold out since it was placed into the local shopping cart.
-- Do not alter historical quote-items, payments, or fulfillment status.
create or replace function public.gq_block_soldout_quote_item_v31()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.product_id is not null and exists(
    select 1 from public.gq_products p
    where p.id=new.product_id and (p.is_sold_out or not p.published)
  ) then
    raise exception '품절되었거나 전시가 종료된 상품이 포함되어 있어요. 장바구니를 확인해 주세요.'
      using errcode='22023';
  end if;
  return new;
end;
$$;
revoke all on function public.gq_block_soldout_quote_item_v31() from public,anon,authenticated;

create trigger gq_block_soldout_quote_item_v31
before insert on public.gq_quote_items
for each row execute function public.gq_block_soldout_quote_item_v31();

comment on column public.gq_products.is_sold_out is
  'Keep visible as sold out when published=true; prevents new quote-item insertion';
comment on column public.gq_product_requests.rejection_reason is
  'Admin-selected product request rejection reason, separate from application note';
