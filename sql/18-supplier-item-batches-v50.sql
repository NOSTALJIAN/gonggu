-- MINIYENA v50: supplier-specific item batches and exact per-buyer split.
-- This migration replaces the whole-quote selector, not historical data.
-- Old v47 tables/functions remain for backward compatibility.
-- One quote can contain items from different Namdaemun stores; each store
-- is assigned its own batch and fee, with amounts summed on the quote.
-- Supplier ordering is per item, and the quote is supplier-ordered only after
-- every active item in that quote has been ordered.
-- Sensitive selected-item data is restricted to authenticated admins via RPC.

alter table public.gq_quote_items
 add column if not exists supplier_ordered_at timestamptz;

create table if not exists gq_private.gq_supplier_item_batches_v50(
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null references public.gq_stores(id),
 total integer not null check(total between 0 and 1000000),
 people integer not null check(people between 1 and 100),
 created_at timestamptz not null default clock_timestamp(),
 ordered_at timestamptz
);
create table if not exists gq_private.gq_supplier_item_batch_items_v50(
 batch_id uuid not null references gq_private.gq_supplier_item_batches_v50(id) on delete cascade,
 item_id uuid not null unique references public.gq_quote_items(id) on delete cascade,
 primary key(batch_id,item_id)
);
create table if not exists gq_private.gq_supplier_item_batch_payers_v50(
 batch_id uuid not null references gq_private.gq_supplier_item_batches_v50(id) on delete cascade,
 buyer_key text not null check(length(buyer_key) between 8 and 20),
 charged_quote_id uuid not null references public.gq_quotes(id) on delete cascade,
 amount integer not null check(amount between 0 and 1000000),
 primary key(batch_id,buyer_key)
);
create index if not exists gq_supplier_item_batch_payer_quote_v50
 on gq_private.gq_supplier_item_batch_payers_v50(charged_quote_id);
create table if not exists gq_private.gq_supplier_fee_baselines_v50(
 quote_id uuid primary key references public.gq_quotes(id) on delete cascade,
 original_amount integer not null check(original_amount between 0 and 1000000)
);
alter table gq_private.gq_supplier_item_batches_v50 enable row level security;
alter table gq_private.gq_supplier_item_batch_items_v50 enable row level security;
alter table gq_private.gq_supplier_item_batch_payers_v50 enable row level security;
alter table gq_private.gq_supplier_fee_baselines_v50 enable row level security;
revoke all on gq_private.gq_supplier_item_batches_v50 from public,anon,authenticated;
revoke all on gq_private.gq_supplier_item_batch_items_v50 from public,anon,authenticated;
revoke all on gq_private.gq_supplier_item_batch_payers_v50 from public,anon,authenticated;
revoke all on gq_private.gq_supplier_fee_baselines_v50 from public,anon,authenticated;


-- gq_private.gq_recalculate_supplier_fee_v50(uuid)
CREATE OR REPLACE FUNCTION gq_private.gq_recalculate_supplier_fee_v50(p_quote_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_base integer;v_current bigint;
begin
 select original_amount into v_base
 from gq_private.gq_supplier_fee_baselines_v50 where quote_id=p_quote_id;
 if not found then return;end if;
 select v_base+coalesce(sum(p.amount),0) into v_current
 from gq_private.gq_supplier_item_batch_payers_v50 p
 where p.charged_quote_id=p_quote_id;
 if v_current>1000000 then raise exception
 '선택한 주문의 도매 배송비 총액이 100만원을 초과해요.' using errcode='22023';end if;
 update public.gq_quotes
 set supplier_shipping_total=v_current::integer,supplier_shipping_people=1
 where id=p_quote_id;
end $function$;
revoke all on function gq_private.gq_recalculate_supplier_fee_v50(uuid) from public,anon,authenticated;

-- gq_admin_cancel_supplier_item_batch_v50(uuid)
CREATE OR REPLACE FUNCTION public.gq_admin_cancel_supplier_item_batch_v50(p_batch_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_batch record;v_quote_id uuid;v_ids uuid[];
begin
 if auth.uid() is null or not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 select * into v_batch from gq_private.gq_supplier_item_batches_v50
 where id=p_batch_id for update;
 if not found then raise exception '배송비 배분 내역이 없어요.' using errcode='22023';end if;
 if v_batch.ordered_at is not null then
  raise exception '이미 도매 발주한 거래처 배분은 취소할 수 없어요.' using errcode='22023';
 end if;
 select coalesce(array_agg(distinct p.charged_quote_id),'{}'::uuid[]) into v_ids
 from gq_private.gq_supplier_item_batch_payers_v50 p where p.batch_id=p_batch_id;
 for v_quote_id in select unnest(v_ids) order by 1 loop
  perform 1 from public.gq_quotes where id=v_quote_id for update;
 end loop;
 delete from gq_private.gq_supplier_item_batches_v50 where id=p_batch_id;
 for v_quote_id in select unnest(v_ids) order by 1 loop
  perform gq_private.gq_recalculate_supplier_fee_v50(v_quote_id);
 end loop;
 return true;
end $function$;
revoke all on function gq_admin_cancel_supplier_item_batch_v50(uuid) from public,anon,authenticated;
grant execute on function public.gq_admin_cancel_supplier_item_batch_v50(uuid) to authenticated;

-- gq_admin_create_supplier_item_batch_v50(uuid[],integer)
CREATE OR REPLACE FUNCTION public.gq_admin_create_supplier_item_batch_v50(p_item_ids uuid[], p_total integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_size integer:=coalesce(cardinality(p_item_ids),0);
 v_row record;v_store_id uuid;v_count integer:=0;
 v_keys text[]:=array[]::text[];v_phone text;
 v_people integer;v_base integer;v_extra integer;v_index integer:=0;
 v_batch_id uuid;v_quote_id uuid;v_amount integer;
 v_supplier text;v_key text;
begin
 if auth.uid() is null or not public.gq_is_admin() then
  raise exception '관리자만 도매배송비를 배분할 수 있어요.' using errcode='42501';
 end if;
 if v_size<1 or v_size>300 or p_total is null or p_total<0 or p_total>1000000 then
  raise exception '같은 거래처 상품을 1~300개 선택하고 배송비 총액을 입력해 주세요.' using errcode='22023';
 end if;
 if array_position(p_item_ids,null) is not null or
  (select count(distinct id) from unnest(p_item_ids) as id)<>v_size then
  raise exception '중복된 상품이 선택됐어요. 선택을 확인해 주세요.' using errcode='22023';
 end if;
 for v_row in
  select i.id,i.quote_id,i.fulfillment,i.supplier_ordered_at,
   q.status,q.supplier_ordered_at as quote_ordered_at,q.contact,
   p.store_id,s.name as store_name
  from public.gq_quote_items i
  join public.gq_quotes q on q.id=i.quote_id
  join public.gq_products p on p.id=i.product_id
  join public.gq_stores s on s.id=p.store_id
  where i.id=any(p_item_ids)
  order by i.id
  for update of i,q
 loop
  v_count:=v_count+1;
  if v_store_id is null then
   v_store_id:=v_row.store_id;v_supplier:=v_row.store_name;
  elsif v_store_id<>v_row.store_id then
   raise exception '서로 다른 도매 거래처 상품이 함께 선택됐어요. 거래처별로 각각 배분해 주세요.' using errcode='22023';
  end if;
  if v_row.status='cancelled' or v_row.fulfillment='sold_out'
    or v_row.supplier_ordered_at is not null or v_row.quote_ordered_at is not null then
   raise exception '취소·품절·발주 완료 상품은 다시 배분할 수 없어요.' using errcode='22023';
  end if;
  if exists(
   select 1 from gq_private.gq_supplier_item_batch_items_v50 b
   where b.item_id=v_row.id
  ) or exists(
   select 1 from gq_private.gq_supplier_shipping_members_v47 legacy
   where legacy.quote_id=v_row.quote_id
  ) then
   raise exception '이미 배송비 배분에 포함된 상품이 있어요. 중복 배분할 수 없어요.' using errcode='22023';
  end if;
  v_phone:=regexp_replace(coalesce(v_row.contact,''),'[^0-9]','','g');
  if length(v_phone)<8 or length(v_phone)>20 then
   raise exception '선택한 주문의 연락처가 올바르지 않아요.' using errcode='22023';
  end if;
  if not(v_phone=any(v_keys)) then v_keys:=array_append(v_keys,v_phone);end if;
 end loop;
 if v_count<>v_size then
  raise exception '상품이 삭제되거나 거래처 연결이 해제됐어요. 새로고침해 주세요.' using errcode='22023';
 end if;
 v_people:=cardinality(v_keys);
 if v_people<1 or v_people>100 then
  raise exception '한 번에 최대 100명의 구매자를 배분할 수 있어요.' using errcode='22023';
 end if;

 -- Avoid charging the same buyer twice while their supplier's
 -- previous shipping batch is still awaiting procurement.
 for v_key in select key from unnest(v_keys) as key order by key loop
  perform pg_advisory_xact_lock(hashtextextended(v_store_id::text||':'||v_key,0));
  if exists (
   select 1
   from gq_private.gq_supplier_item_batches_v50 b
   join gq_private.gq_supplier_item_batch_payers_v50 payer
    on payer.batch_id=b.id
   where b.store_id=v_store_id and b.ordered_at is null
    and payer.buyer_key=v_key
  ) then
   raise exception '이 거래처에 이미 배송비를 배분한 구매자가 있어요. 기존 배분을 취소하고 상품을 함께 선택해 주세요.'
   using errcode='22023';
  end if;
 end loop;
 insert into gq_private.gq_supplier_item_batches_v50(store_id,total,people)
 values(v_store_id,p_total,v_people) returning id into v_batch_id;
 insert into gq_private.gq_supplier_item_batch_items_v50(batch_id,item_id)
 select v_batch_id,unnest(p_item_ids);

 v_base:=p_total/v_people;
 v_extra:=mod(p_total,v_people);
 for v_key in select key from unnest(v_keys) as key order by key loop
  v_index:=v_index+1;
  v_amount:=v_base+case when v_index<=v_extra then 1 else 0 end;
  select min(i.quote_id) into v_quote_id
  from public.gq_quote_items i join public.gq_quotes q on q.id=i.quote_id
  where i.id=any(p_item_ids)
   and regexp_replace(coalesce(q.contact,''),'[^0-9]','','g')=v_key;
  if v_quote_id is null then raise exception '배분할 주문을 찾지 못했어요.';end if;
  insert into gq_private.gq_supplier_fee_baselines_v50(quote_id,original_amount)
   select q.id,q.supplier_shipping_share
   from public.gq_quotes q where q.id=v_quote_id
   on conflict(quote_id) do nothing;
  insert into gq_private.gq_supplier_item_batch_payers_v50
   (batch_id,buyer_key,charged_quote_id,amount)
  values(v_batch_id,v_key,v_quote_id,v_amount);
  perform gq_private.gq_recalculate_supplier_fee_v50(v_quote_id);
 end loop;
 return jsonb_build_object(
  'id',v_batch_id,'supplier',v_supplier,'people',v_people,'total',p_total,
  'selected_items',v_size,'supplier_id',v_store_id);
end $function$;
revoke all on function gq_admin_create_supplier_item_batch_v50(uuid[],integer) from public,anon,authenticated;
grant execute on function public.gq_admin_create_supplier_item_batch_v50(uuid[],integer) to authenticated;

-- gq_admin_list_supplier_item_batches_v50()
CREATE OR REPLACE FUNCTION public.gq_admin_list_supplier_item_batches_v50()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if auth.uid() is null or not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',b.id,'store_id',b.store_id,'supplier',s.name,
  'total',b.total,'people',b.people,'ordered_at',b.ordered_at,
  'created_at',b.created_at,
  'item_ids',(
   select coalesce(jsonb_agg(j.item_id order by j.item_id),'[]'::jsonb)
   from gq_private.gq_supplier_item_batch_items_v50 j where j.batch_id=b.id),
  'payers',(
   select coalesce(jsonb_agg(jsonb_build_object(
    'buyer_key',p.buyer_key,'charged_quote_id',p.charged_quote_id,
    'amount',p.amount) order by p.buyer_key),'[]'::jsonb)
   from gq_private.gq_supplier_item_batch_payers_v50 p where p.batch_id=b.id)
 ) order by b.created_at desc,b.id),'[]'::jsonb)
 into v_result
 from gq_private.gq_supplier_item_batches_v50 b
 join public.gq_stores s on s.id=b.store_id;
 return v_result;
end $function$;
revoke all on function gq_admin_list_supplier_item_batches_v50() from public,anon,authenticated;
grant execute on function public.gq_admin_list_supplier_item_batches_v50() to authenticated;

-- gq_admin_mark_supplier_item_batch_ordered_v50(uuid)
CREATE OR REPLACE FUNCTION public.gq_admin_mark_supplier_item_batch_ordered_v50(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_batch record;v_item record;v_payer record;v_quote public.gq_quotes%rowtype;
 v_roots uuid[];v_quote_id uuid;
 v_due bigint;v_net bigint;v_total_due bigint;v_total_net bigint;
 v_active integer;v_missing integer;v_processed integer:=0;
 v_quote_total integer:=0;v_time timestamptz:=clock_timestamp();
begin
 if auth.uid() is null or not public.gq_is_admin() then
  raise exception '관리자만 도매 발주 완료를 처리할 수 있어요.' using errcode='42501';
 end if;
 select * into v_batch from gq_private.gq_supplier_item_batches_v50
 where id=p_batch_id for update;
 if not found then raise exception '도매배송비 배분을 찾지 못했어요.' using errcode='22023';end if;
 if v_batch.ordered_at is not null then
  raise exception '이미 도매 발주 완료 처리한 거래처예요.' using errcode='22023';
 end if;

 for v_item in
  select i.id,i.quote_id,i.supplier_ordered_at,i.fulfillment,q.status,
    q.cancel_requested_at,q.delivery_change_requested_at,q.workflow_stage,
    q.supplier_ordered_at as quote_ordered_at
  from gq_private.gq_supplier_item_batch_items_v50 bi
  join public.gq_quote_items i on i.id=bi.item_id
  join public.gq_quotes q on q.id=i.quote_id
  where bi.batch_id=p_batch_id order by i.id for update of i,q
 loop
  if v_item.status<>'confirmed' then
   raise exception '해당 거래처 상품이 포함된 주문의 최종 확정이 필요해요.' using errcode='22023';
  end if;
  if v_item.supplier_ordered_at is not null or
    v_item.quote_ordered_at is not null or
    v_item.fulfillment='sold_out' or
    coalesce(v_item.workflow_stage,'new') not in ('new','preparing') then
   raise exception '이미 발주하거나 품절·배송 처리된 상품이 포함돼 있어요.' using errcode='22023';
  end if;
  if v_item.cancel_requested_at is not null or
    v_item.delivery_change_requested_at is not null then
   raise exception '구매자의 취소·배송지 변경 요청을 먼저 처리해 주세요.' using errcode='22023';
  end if;
  v_processed:=v_processed+1;
 end loop;
 if v_processed=0 then raise exception '선택된 거래처 상품이 없어요.' using errcode='22023';end if;

 for v_payer in
  select * from gq_private.gq_supplier_item_batch_payers_v50
  where batch_id=p_batch_id order by buyer_key
 loop
  select coalesce(array_agg(distinct coalesce(q.bundle_parent_id,q.id)),'{}'::uuid[])
   into v_roots
  from gq_private.gq_supplier_item_batch_items_v50 bi
  join public.gq_quote_items i on i.id=bi.item_id
  join public.gq_quotes q on q.id=i.quote_id
  where bi.batch_id=p_batch_id
   and regexp_replace(coalesce(q.contact,''),'[^0-9]','','g')=v_payer.buyer_key;
  if cardinality(v_roots)=0 then
   raise exception '해당 구매자의 주문을 찾을 수 없어요.' using errcode='22023';
  end if;
  v_total_due:=0;v_total_net:=0;
  for v_quote in
   select q.* from public.gq_quotes q
   where (q.id=any(v_roots) or q.bundle_parent_id=any(v_roots))
    and q.status<>'cancelled'
   order by q.id for update of q
  loop
   if v_quote.status<>'confirmed' then
    raise exception '입금 확인 전 모든 묶음 주문의 최종 확정이 필요해요.' using errcode='22023';
   end if;
   if v_quote.cancel_requested_at is not null or
     v_quote.delivery_change_requested_at is not null then
    raise exception '취소·수령방식 변경 요청을 먼저 처리해 주세요.' using errcode='22023';
   end if;
   select count(*) filter(where i.fulfillment<>'sold_out'),
     count(*) filter(where i.fulfillment<>'sold_out' and i.unit_price is null),
     coalesce(sum(case when i.fulfillment<>'sold_out'
       then coalesce(i.unit_price,0)::bigint*i.quantity else 0 end),0)
   into v_active,v_missing,v_due
   from public.gq_quote_items i where i.quote_id=v_quote.id;
   if v_active=0 or v_missing>0 then
    raise exception '미입력 가격 또는 전체 품절 상품이 있어 입금을 확인할 수 없어요.' using errcode='22023';
   end if;
   if v_quote.delivery_method='courier' and v_quote.bundle_parent_id is null
      and v_quote.shipping_fee is null then
    raise exception '고객 수령 배송비가 확정되지 않은 주문이 있어요.' using errcode='22023';
   end if;
   v_due:=v_due+v_quote.supplier_shipping_share::bigint+
    case when v_quote.delivery_method='courier'
      and v_quote.bundle_parent_id is null then coalesce(v_quote.shipping_fee,0)::bigint
     else 0 end;
   v_total_due:=v_total_due+v_due;
   v_total_net:=v_total_net+v_quote.amount_paid::bigint-v_quote.amount_refunded::bigint;
   v_quote_total:=v_quote_total+1;
  end loop;
  if v_total_net<v_total_due then
   raise exception '입금 미완료 구매자가 있어요. 묶음 주문의 총 입금액과 결제액을 확인해 주세요.' using errcode='22023';
  end if;
 end loop;

 update public.gq_quote_items i
 set supplier_ordered_at=v_time
 from gq_private.gq_supplier_item_batch_items_v50 bi
 where bi.item_id=i.id and bi.batch_id=p_batch_id;

 -- The quote becomes "supplier ordered" only when ALL active products in
 -- that quote (including other suppliers) have been ordered.
 for v_quote_id in
  select distinct i.quote_id
  from gq_private.gq_supplier_item_batch_items_v50 bi
  join public.gq_quote_items i on i.id=bi.item_id
  where bi.batch_id=p_batch_id order by i.quote_id
 loop
  if exists(select 1 from public.gq_quote_items i
   where i.quote_id=v_quote_id and i.fulfillment<>'sold_out')
   and not exists(select 1 from public.gq_quote_items i
   where i.quote_id=v_quote_id and i.fulfillment<>'sold_out'
    and i.supplier_ordered_at is null) then
    update public.gq_quotes
    set supplier_ordered_at=v_time,
     workflow_stage='preparing',workflow_updated_at=v_time
    where id=v_quote_id and status='confirmed'
     and coalesce(workflow_stage,'new') in ('new','preparing')
     and supplier_ordered_at is null;
  end if;
 end loop;
 update gq_private.gq_supplier_item_batches_v50
 set ordered_at=v_time where id=p_batch_id;

 return jsonb_build_object('ordered',true,
  'supplier_id',v_batch.store_id,'items',v_processed,'people',v_batch.people);
end $function$;
revoke all on function gq_admin_mark_supplier_item_batch_ordered_v50(uuid) from public,anon,authenticated;
grant execute on function public.gq_admin_mark_supplier_item_batch_ordered_v50(uuid) to authenticated;
