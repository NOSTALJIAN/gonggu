-- MINIYENA: Wholesale delivery fee shared by selected buyers, protected admin-only.
-- The existing quote workflow has a separate supplier-ordered milestone (not delivered).
-- In bundled orders a buyer's total due is compared to their combined net payment.
-- Create on a Supabase project after the existing gq_quotes / gq_quote_items schema.
alter table public.gq_quotes
 add column if not exists supplier_ordered_at timestamptz;

create table if not exists gq_private.gq_supplier_shipping_batches_v47(
 id uuid primary key default gen_random_uuid(),
 total integer not null check(total between 0 and 1000000),
 people integer not null check(people between 1 and 100),
 share integer not null check(share >= 0),
 created_at timestamptz not null default clock_timestamp(),
 ordered_at timestamptz
);
create table if not exists gq_private.gq_supplier_shipping_members_v47(
 batch_id uuid not null references gq_private.gq_supplier_shipping_batches_v47(id) on delete cascade,
 quote_id uuid not null unique references public.gq_quotes(id) on delete cascade,
 primary_order boolean not null default false,
 old_total integer not null,
 old_people integer not null,
 primary key(batch_id,quote_id)
);
create index if not exists gq_supplier_shipping_members_batch_v47
 on gq_private.gq_supplier_shipping_members_v47(batch_id);

alter table gq_private.gq_supplier_shipping_batches_v47 enable row level security;
alter table gq_private.gq_supplier_shipping_members_v47 enable row level security;
revoke all on gq_private.gq_supplier_shipping_batches_v47 from public,anon,authenticated;
revoke all on gq_private.gq_supplier_shipping_members_v47 from public,anon,authenticated;


-- gq_admin_cancel_supplier_shipping_batch_v47
CREATE OR REPLACE FUNCTION public.gq_admin_cancel_supplier_shipping_batch_v47(p_batch_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_batch record;v_member record;
begin
 if auth.uid() is null or not public.gq_is_admin() then
  raise exception '관리자만 배송비 배분을 취소할 수 있어요.' using errcode='42501';
 end if;
 select * into v_batch from gq_private.gq_supplier_shipping_batches_v47
 where id=p_batch_id for update;
 if not found then raise exception '배분 내역을 찾지 못했어요.' using errcode='22023';end if;
 if v_batch.ordered_at is not null then
  raise exception '도매 발주 완료된 배분은 취소할 수 없어요.' using errcode='22023';
 end if;
 for v_member in
  select m.*,q.supplier_ordered_at
  from gq_private.gq_supplier_shipping_members_v47 m
  join public.gq_quotes q on q.id=m.quote_id
  where m.batch_id=p_batch_id order by m.quote_id for update of q
 loop
  if v_member.supplier_ordered_at is not null then
   raise exception '이미 발주 완료된 주문이 포함돼 있어요.' using errcode='22023';
  end if;
  update public.gq_quotes
  set supplier_shipping_total=v_member.old_total,
      supplier_shipping_people=v_member.old_people
  where id=v_member.quote_id and status<>'cancelled';
 end loop;
 delete from gq_private.gq_supplier_shipping_batches_v47 where id=p_batch_id;
 return true;
end $function$;
revoke all on function public.gq_admin_cancel_supplier_shipping_batch_v47(uuid) from public,anon,authenticated;
grant execute on function public.gq_admin_cancel_supplier_shipping_batch_v47(uuid) to authenticated;

-- gq_admin_create_supplier_shipping_batch_v47
CREATE OR REPLACE FUNCTION public.gq_admin_create_supplier_shipping_batch_v47(p_root_quote_ids uuid[], p_total integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_count integer:=0;v_people integer;v_share integer;v_base integer;v_remainder integer;v_person_index integer:=0;v_current_share integer;
 v_root public.gq_quotes%rowtype;v_member public.gq_quotes%rowtype;
 v_root_id uuid;v_batch_id uuid;v_contact text;v_contacts text[]:=array[]::text[];
begin
 if auth.uid() is null or not public.gq_is_admin() then
  raise exception '관리자만 일괄 배송비를 설정할 수 있어요.' using errcode='42501';
 end if;
 v_people:=coalesce(cardinality(p_root_quote_ids),0);
 if v_people<1 or v_people>100 or p_total is null or p_total<0 or p_total>1000000 then
  raise exception '주문 1~100건을 선택하고 배송비 총액 0~100만원을 입력해 주세요.' using errcode='22023';
 end if;
 if array_position(p_root_quote_ids,null) is not null
   or (select count(distinct x) from unnest(p_root_quote_ids) as x)<>v_people then
  raise exception '중복되거나 잘못된 주문 선택이 있어요.' using errcode='22023';
 end if;
 for v_root in
  select * from public.gq_quotes
  where id=any(p_root_quote_ids) order by id for update
 loop
  if v_root.status='cancelled' or v_root.bundle_parent_id is not null then
   raise exception '취소 주문이나 묶음배송 추가 주문은 선택할 수 없어요. 대표 주문을 선택해 주세요.' using errcode='22023';
  end if;
  if v_root.supplier_ordered_at is not null then
   raise exception '이미 도매 발주 완료된 주문의 배송비는 다시 배분할 수 없어요.' using errcode='22023';
  end if;
  if not exists (select 1 from public.gq_quote_items i
   where i.quote_id=v_root.id and i.fulfillment<>'sold_out') then
   raise exception '상품이 모두 품절된 주문에는 배송비를 배분하지 않아요.' using errcode='22023';
  end if;
  v_contact:=regexp_replace(coalesce(v_root.contact,''),'[^0-9]','','g');
  if length(v_contact)<8 then
   raise exception '선택한 주문의 연락처를 확인해 주세요.' using errcode='22023';
  end if;
  if v_contact=any(v_contacts) then
   raise exception '같은 구매자의 주문이 여러 건 선택됐어요. 한 사람당 한 건만 체크해 주세요.' using errcode='22023';
  end if;
  v_contacts:=array_append(v_contacts,v_contact);
  v_count:=v_count+1;
 end loop;
 if v_count<>v_people then
  raise exception '일부 주문이 존재하지 않아요. 새로고침해 주세요.' using errcode='22023';
 end if;
 v_share:=(p_total+v_people-1)/v_people;
 v_base:=p_total/v_people;
 v_remainder:=mod(p_total,v_people);
 insert into gq_private.gq_supplier_shipping_batches_v47(total,people,share)
 values(p_total,v_people,v_share) returning id into v_batch_id;
 for v_root_id in select unnest(p_root_quote_ids) order by 1 loop
  v_person_index:=v_person_index+1;
  v_current_share:=v_base+case when v_person_index<=v_remainder then 1 else 0 end;
  for v_member in
   select * from public.gq_quotes q
   where (q.id=v_root_id or q.bundle_parent_id=v_root_id)
    and q.status<>'cancelled'
   order by q.id for update
  loop
   if v_member.supplier_ordered_at is not null then
    raise exception '이미 도매 발주 완료된 묶음 주문이 포함돼 있어요.' using errcode='22023';
   end if;
   if exists (select 1 from gq_private.gq_supplier_shipping_members_v47 m
     where m.quote_id=v_member.id) then
    raise exception '이미 배송비 배분에 포함된 주문이 있어요. 기존 배분을 취소하고 다시 시도해 주세요.' using errcode='22023';
   end if;
   insert into gq_private.gq_supplier_shipping_members_v47
    (batch_id,quote_id,primary_order,old_total,old_people)
   values(v_batch_id,v_member.id,v_member.id=v_root_id,
    v_member.supplier_shipping_total,v_member.supplier_shipping_people);
   if v_member.id=v_root_id then
    -- Every won is allocated exactly once. The first v_remainder buyers
    -- (by stable UUID order) pay one more won than the others.
    update public.gq_quotes set supplier_shipping_total=v_current_share,
      supplier_shipping_people=1 where id=v_member.id;
   else
    update public.gq_quotes set supplier_shipping_total=0,
      supplier_shipping_people=1 where id=v_member.id;
   end if;
  end loop;
 end loop;
 return jsonb_build_object('id',v_batch_id,'people',v_people,'total',p_total,'share',v_share);
end $function$;
revoke all on function public.gq_admin_create_supplier_shipping_batch_v47(uuid[],integer) from public,anon,authenticated;
grant execute on function public.gq_admin_create_supplier_shipping_batch_v47(uuid[],integer) to authenticated;

-- gq_admin_list_supplier_shipping_batches_v47
CREATE OR REPLACE FUNCTION public.gq_admin_list_supplier_shipping_batches_v47()
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
   'id',b.id,'total',b.total,'people',b.people,'share',b.share,
   'created_at',b.created_at,'ordered_at',b.ordered_at,
   'quote_ids',(
    select coalesce(jsonb_agg(m.quote_id order by m.quote_id),'[]'::jsonb)
    from gq_private.gq_supplier_shipping_members_v47 m where m.batch_id=b.id
   ),
   'root_quote_ids',(
    select coalesce(jsonb_agg(m.quote_id order by m.quote_id),'[]'::jsonb)
    from gq_private.gq_supplier_shipping_members_v47 m
    where m.batch_id=b.id and m.primary_order
   )
 ) order by b.created_at desc,b.id),'[]'::jsonb)
 into v_result
 from gq_private.gq_supplier_shipping_batches_v47 b;
 return v_result;
end $function$;
revoke all on function public.gq_admin_list_supplier_shipping_batches_v47() from public,anon,authenticated;
grant execute on function public.gq_admin_list_supplier_shipping_batches_v47() to authenticated;

-- gq_admin_mark_supplier_batch_ordered_v47
CREATE OR REPLACE FUNCTION public.gq_admin_mark_supplier_batch_ordered_v47(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_batch record;v_quote public.gq_quotes%rowtype;v_root_id uuid;
 v_missing integer;v_active integer;v_products bigint;v_customer_shipping integer;
 v_expected bigint;v_net bigint;v_count integer:=0;v_now timestamptz:=clock_timestamp();
begin
 if auth.uid() is null or not public.gq_is_admin() then
  raise exception '관리자만 도매 발주를 완료 처리할 수 있어요.' using errcode='42501';
 end if;
 select * into v_batch from gq_private.gq_supplier_shipping_batches_v47
 where id=p_batch_id for update;
 if not found then raise exception '배분 내역을 찾지 못했어요.' using errcode='22023';end if;
 if v_batch.ordered_at is not null then
  raise exception '이미 도매 발주 완료 처리된 묶음이에요.' using errcode='22023';
 end if;
 for v_quote in
  select q.* from public.gq_quotes q
  join gq_private.gq_supplier_shipping_members_v47 m on m.quote_id=q.id
  where m.batch_id=p_batch_id
  order by q.id for update of q
 loop
  if v_quote.status<>'confirmed' then
   raise exception '선택한 주문 중 고객이 최종 주문을 확정하지 않은 건이 있어요.' using errcode='22023';
  end if;
  if v_quote.cancel_requested_at is not null or
    v_quote.delivery_change_requested_at is not null then
   raise exception '취소·수령방식 변경 요청이 있는 주문을 먼저 처리해 주세요.' using errcode='22023';
  end if;
  if coalesce(v_quote.workflow_stage,'new') not in ('new','preparing') or
    v_quote.supplier_ordered_at is not null then
   raise exception '이미 출고됐거나 도매 발주 처리된 주문이 있어요.' using errcode='22023';
  end if;
  select count(*) filter(where fulfillment<>'sold_out'),
    count(*) filter(where fulfillment<>'sold_out' and unit_price is null),
    coalesce(sum(case when fulfillment<>'sold_out'
      then coalesce(unit_price,0)::bigint*quantity else 0 end),0)
  into v_active,v_missing,v_products
  from public.gq_quote_items where quote_id=v_quote.id;
  if v_active=0 or v_missing>0 then
   raise exception '가격 미입력 또는 전체 품절 주문은 도매 발주할 수 없어요.' using errcode='22023';
  end if;
  if v_quote.delivery_method='courier' and v_quote.bundle_parent_id is null
     and v_quote.shipping_fee is null then
   raise exception '고객 배송비가 확정되지 않은 주문이 있어요.' using errcode='22023';
  end if;
  v_customer_shipping:=case when v_quote.delivery_method='courier'
    and v_quote.bundle_parent_id is null
    then coalesce(v_quote.shipping_fee,0) else 0 end;
  v_expected:=v_products+v_customer_shipping+v_quote.supplier_shipping_share;
  -- For bundled orders, payments may be recorded as one payment on the root.
  v_count:=v_count+1;
 end loop;
 if v_count=0 then raise exception '배분에 포함된 주문이 없어요.' using errcode='22023';end if;

 for v_root_id in
  select m.quote_id from gq_private.gq_supplier_shipping_members_v47 m
  where m.batch_id=p_batch_id and m.primary_order order by m.quote_id
 loop
  select coalesce(sum(q.amount_paid::bigint-q.amount_refunded::bigint),0),
    coalesce(sum(
     (select coalesce(sum(i.unit_price::bigint*i.quantity),0)
       from public.gq_quote_items i
       where i.quote_id=q.id and i.fulfillment<>'sold_out')
      +case when q.delivery_method='courier' and q.bundle_parent_id is null
        then coalesce(q.shipping_fee,0)::bigint else 0 end
      +q.supplier_shipping_share::bigint
    ),0)
  into v_net,v_expected
  from public.gq_quotes q
  join gq_private.gq_supplier_shipping_members_v47 m on m.quote_id=q.id
  where m.batch_id=p_batch_id and (q.id=v_root_id or q.bundle_parent_id=v_root_id);
  if v_net<v_expected then
   raise exception '입금 미완료 구매자가 있어요. 묶음배송은 같은 구매자의 총 입금액을 합산해 확인해 주세요.' using errcode='22023';
  end if;
 end loop;
 -- supplier ordered != delivered; use the existing product-preparation stage.
 update public.gq_quotes q
 set supplier_ordered_at=v_now,
     workflow_stage='preparing',workflow_updated_at=v_now
 from gq_private.gq_supplier_shipping_members_v47 m
 where m.quote_id=q.id and m.batch_id=p_batch_id;
 update gq_private.gq_supplier_shipping_batches_v47
 set ordered_at=v_now where id=p_batch_id;
 return jsonb_build_object('ordered',true,'orders',v_count,'people',v_batch.people);
end $function$;
revoke all on function public.gq_admin_mark_supplier_batch_ordered_v47(uuid) from public,anon,authenticated;
grant execute on function public.gq_admin_mark_supplier_batch_ordered_v47(uuid) to authenticated;
