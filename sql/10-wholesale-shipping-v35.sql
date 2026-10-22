-- MINIYENA v35: upstream vendor-to-shop shipping, separated from shop-to-buyer delivery.
-- Legacy orders default to zero extra fee.
alter table public.gq_quotes
  add column if not exists supplier_shipping_total integer not null default 0,
  add column if not exists supplier_shipping_people integer not null default 1,
  add column if not exists supplier_shipping_share integer
    generated always as ((supplier_shipping_total + supplier_shipping_people - 1) / supplier_shipping_people) stored;
alter table public.gq_quotes
  add constraint gq_supplier_shipping_v35_range check (
    supplier_shipping_total between 0 and 1000000
    and supplier_shipping_people between 1 and 1000
  );

alter table public.gq_amount_changes drop constraint gq_amount_changes_field_name_check;
alter table public.gq_amount_changes add constraint gq_amount_changes_field_name_check
 check (field_name in ('unit_price','shipping_fee','supplier_shipping_share'));

create or replace function public.gq_validate_supplier_shipping_v35()
returns trigger language plpgsql security definer set search_path='' as $$
declare old_share integer; new_share integer;
begin
 if old.supplier_shipping_total is not distinct from new.supplier_shipping_total
    and old.supplier_shipping_people is not distinct from new.supplier_shipping_people then return new; end if;
 if old.status='cancelled' or not public.gq_is_admin() then
  raise exception '도매 배송비는 관리자만 수정할 수 있으며 취소된 주문에서는 변경할 수 없어요.'
   using errcode='42501';
 end if;
 old_share:=(old.supplier_shipping_total+old.supplier_shipping_people-1)/old.supplier_shipping_people;
 new_share:=(new.supplier_shipping_total+new.supplier_shipping_people-1)/new.supplier_shipping_people;
 if old.status in ('quoted','confirmed') and old_share is distinct from new_share then
  insert into public.gq_amount_changes(quote_id,changed_by,field_name,old_amount,new_amount)
   values(old.id,auth.uid(),'supplier_shipping_share',old_share,new_share);
  new.amount_changed_at=clock_timestamp();
 end if;
 return new;
end $$;
drop trigger if exists gq_validate_supplier_shipping_v35 on public.gq_quotes;
create trigger gq_validate_supplier_shipping_v35
 before update of supplier_shipping_total,supplier_shipping_people on public.gq_quotes
 for each row execute function public.gq_validate_supplier_shipping_v35();

create or replace function public.gq_admin_set_supplier_shipping_v35(p_quote_id uuid,p_total integer,p_people integer)
returns integer language plpgsql volatile security definer set search_path='' as $$
declare v_share integer;
begin
 if auth.uid() is null or not public.gq_is_admin() then
  raise exception '관리자만 도매 배송비를 설정할 수 있어요.' using errcode='42501';
 end if;
 if p_total is null or p_total<0 or p_total>1000000 or p_people is null
    or p_people<1 or p_people>1000 then
  raise exception '업체 배송비는 0~100만원, 분담 인원은 1~1000명으로 입력해 주세요.' using errcode='22023';
 end if;
 update public.gq_quotes set supplier_shipping_total=p_total,supplier_shipping_people=p_people
 where id=p_quote_id and status<>'cancelled'
 returning supplier_shipping_share into v_share;
 if not found then raise exception '주문을 찾지 못했거나 취소된 주문입니다.' using errcode='22023'; end if;
 return v_share;
end $$;
revoke all on function public.gq_admin_set_supplier_shipping_v35(uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.gq_admin_set_supplier_shipping_v35(uuid,integer,integer) to authenticated;

-- Only customer share is exposed from the token-protected quote lookup.
CREATE OR REPLACE FUNCTION public.gq_read_quote(p_quote_id uuid, p_lookup_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v public.gq_quotes%ROWTYPE; v_items jsonb; v_bundle boolean;
BEGIN
 SELECT * INTO v FROM public.gq_quotes WHERE id=p_quote_id AND lookup_token=p_lookup_token;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT coalesce(v.bundle_parent_id IS NOT NULL AND EXISTS(
   SELECT 1 FROM public.gq_quotes q2 WHERE q2.id=v.bundle_parent_id AND q2.status<>'cancelled'
 ),false) INTO v_bundle;
 SELECT COALESCE(jsonb_agg(
   jsonb_build_object('id',i.id,'store_name',i.store_name,'product_name',i.product_name,
    'color',i.color,'size',i.size,'quantity',i.quantity,
    'unit_price',CASE WHEN v.status IN ('quoted','confirmed','cancelled') THEN i.unit_price ELSE NULL END,
    'fulfillment',CASE WHEN v.status IN ('confirmed','cancelled') THEN i.fulfillment ELSE 'ordered' END)
    ORDER BY i.created_at,i.id),'[]'::jsonb)
 INTO v_items FROM public.gq_quote_items i WHERE i.quote_id=v.id;
 RETURN jsonb_build_object(
  'id',v.id,'buyer_name',v.buyer_name,'baby_name',v.baby_name,'status',v.status,
  'delivery_method',v.delivery_method,'recipient_name',v.recipient_name,'postal_code',v.postal_code,
  'address_line1',v.address_line1,'address_line2',v.address_line2,'delivery_note',v.delivery_note,
  'bundle_applied',v_bundle,'amount_changed_at',v.amount_changed_at,
  'workflow_stage',CASE WHEN v.status='confirmed' THEN coalesce(v.workflow_stage,'new') ELSE NULL END,
  'workflow_updated_at',CASE WHEN v.status='confirmed' THEN v.workflow_updated_at ELSE NULL END,
  'tracking_carrier',CASE WHEN v.status='confirmed' AND v.workflow_stage IN ('shipped','completed') THEN v.tracking_carrier ELSE NULL END,
  'tracking_number',CASE WHEN v.status='confirmed' AND v.workflow_stage IN ('shipped','completed') THEN v.tracking_number ELSE NULL END,
  'delivery_change_requested_at',v.delivery_change_requested_at,
  'delivery_change_rejected_at',v.delivery_change_rejected_at,
  'requested_delivery_method',v.requested_delivery_method,
  'requested_recipient_name',v.requested_recipient_name,
  'requested_postal_code',v.requested_postal_code,
  'requested_address_line1',v.requested_address_line1,
  'requested_address_line2',v.requested_address_line2,
  'requested_delivery_note',v.requested_delivery_note,
  'shipping_fee',CASE WHEN v.status IN ('quoted','confirmed','cancelled') THEN v.shipping_fee ELSE NULL END,
  'supplier_shipping_share',CASE WHEN v.status IN ('quoted','confirmed','cancelled') THEN v.supplier_shipping_share ELSE NULL END,
  'supplier_shipping_people',CASE WHEN v.status IN ('quoted','confirmed','cancelled') AND v.supplier_shipping_share>0 THEN v.supplier_shipping_people ELSE NULL END,
  'amount_paid',CASE WHEN v.status IN ('confirmed','cancelled') THEN v.amount_paid ELSE 0 END,
  'amount_refunded',CASE WHEN v.status IN ('confirmed','cancelled') THEN v.amount_refunded ELSE 0 END,
  'cancel_requested_at',v.cancel_requested_at,'cancel_reason',v.cancel_reason,
  'cancel_rejected_at',v.cancel_rejected_at,'created_at',v.created_at,'items',v_items
 );
END;
$function$;

notify pgrst,'reload schema';
