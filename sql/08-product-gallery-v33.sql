-- MINIYENA v33: store additional product photos without changing existing cover photos.
-- Product gallery URLs are public only when the product itself is published
-- (existing gq_products RLS still applies).
alter table public.gq_products
  add column if not exists gallery_urls text[] not null default '{}'::text[];
alter table public.gq_products
  add constraint gq_products_gallery_max_eight_v33
  check (cardinality(gallery_urls) <= 8);
comment on column public.gq_products.gallery_urls is
  'Additional customer-visible product photographs, up to eight; image_url remains the cover.';
notify pgrst,'reload schema';
