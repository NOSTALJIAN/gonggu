-- MiniYena v34. Customer-submitted applications can contain one cover and
-- up to eight supplementary photos. Photos stay in the PRIVATE incoming bucket
-- until reviewed and explicitly approved by an administrator.
alter table public.gq_product_requests
 add column if not exists extra_photo_paths text[] not null default '{}'::text[];
alter table public.gq_product_requests
 add constraint gq_product_requests_extra_photo_count_v34
 check (cardinality(extra_photo_paths)<=8 and array_position(extra_photo_paths,null) is null);

create or replace function public.gq_submit_product_request_v34(
 p_store_name text,
 p_product_name text,
 p_customer_name text,
 p_note text,
 p_photo_path text,
 p_extra_photo_paths text[] default '{}'::text[]
)
returns uuid language plpgsql volatile security definer set search_path='' as $$
declare
 v_extra text[]:=coalesce(p_extra_photo_paths,'{}'::text[]);
 v_id uuid;
begin
 if cardinality(v_extra)>8 or array_position(v_extra,null) is not null
    or exists(
       select 1 from pg_catalog.unnest(v_extra) as e(path)
       where e.path=p_photo_path
         or e.path !~ '^incoming/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]jpg$'
         or not exists(
          select 1 from storage.objects o
          where o.bucket_id='gq-request-photos' and o.name=e.path
         )
    )
    or (select count(distinct e.path) from pg_catalog.unnest(v_extra) e(path))<>cardinality(v_extra)
 then
  raise exception '신청 사진은 대표사진 포함 최대 9장까지 등록할 수 있어요. 사진을 다시 확인해 주세요.'
    using errcode='22023';
 end if;
 -- Call the existing, already validated submission function for the cover.
 -- The extra-photo update is part of the same transaction: atomic on error.
 v_id:=public.gq_submit_product_request(
   p_store_name,p_product_name,p_customer_name,p_note,p_photo_path
 );
 update public.gq_product_requests
 set extra_photo_paths=v_extra
 where id=v_id;
 return v_id;
end $$;
revoke all on function public.gq_submit_product_request_v34(text,text,text,text,text,text[]) from public,anon,authenticated;
grant execute on function public.gq_submit_product_request_v34(text,text,text,text,text,text[]) to anon,authenticated;
comment on column public.gq_product_requests.extra_photo_paths
is 'Admin-only, private incoming product request images; first cover remains photo_path.';
notify pgrst, 'reload schema';