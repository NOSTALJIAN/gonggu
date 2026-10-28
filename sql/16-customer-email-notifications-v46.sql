-- MINIYENA v45/v46 | Email recipients & automatic transactional notifications.
-- Production snapshot of installed server functions, preserved alongside the app.
-- Secret API keys are encrypted with Supabase Vault and never committed here.
-- Requirements: Supabase Vault, pg_net, pg_cron, verified Resend sender domain.
-- IMPORTANT: No email is sent until an admin enables it in the app settings.

alter table public.gq_quotes add column if not exists customer_email text;
alter table public.gq_product_requests add column if not exists customer_email text;

do $do$
begin
 if not exists(select 1 from pg_constraint where conname='gq_quote_customer_email_v45') then
  alter table public.gq_quotes add constraint gq_quote_customer_email_v45
  check(customer_email is null or(length(customer_email) between 5 and 254
   and customer_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,24}$'));
 end if;
 if not exists(select 1 from pg_constraint where conname='gq_request_customer_email_v45') then
  alter table public.gq_product_requests add constraint gq_request_customer_email_v45
  check(customer_email is null or(length(customer_email) between 5 and 254
   and customer_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,24}$'));
 end if;
end $do$;

create table if not exists gq_private.gq_email_settings_v45(
 singleton boolean primary key default true check(singleton),
 from_email text,
 enabled boolean not null default false,
 api_secret_id uuid,
 updated_at timestamptz not null default now()
);
insert into gq_private.gq_email_settings_v45(singleton) values(true)
on conflict(singleton) do nothing;
alter table gq_private.gq_email_settings_v45 enable row level security;
revoke all on gq_private.gq_email_settings_v45 from public,anon,authenticated;

create table if not exists gq_private.gq_email_outbox_v45(
 id bigint generated always as identity primary key,
 kind text not null check(kind in ('quote','product_request')),
 object_id uuid not null,
 event text not null,
 event_value text not null default '',
 status text not null default 'pending'
  check(status in ('pending','submitted','sent','failed','skipped')),
 attempts integer not null default 0,
 net_request_id bigint,
 queued_at timestamptz not null default clock_timestamp(),
 submitted_at timestamptz,
 sent_at timestamptz,
 last_error text,
 payload jsonb
);
alter table gq_private.gq_email_outbox_v45 add column if not exists payload jsonb;
alter table gq_private.gq_email_outbox_v45 enable row level security;
revoke all on gq_private.gq_email_outbox_v45 from public,anon,authenticated;
create index if not exists gq_email_outbox_pending_v45
 on gq_private.gq_email_outbox_v45(status,queued_at);


-- gq_private.gq_valid_customer_email_v45(text)
CREATE OR REPLACE FUNCTION gq_private.gq_valid_customer_email_v45(p_email text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare v text:=lower(btrim(coalesce(p_email,'')));
begin
 if v='' then return null; end if;
 if length(v)>254 or v !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,24}$' then
  raise exception '올바른 이메일 주소를 입력해 주세요.' using errcode='22023';
 end if;
 return v;
end $function$
revoke all on function gq_private.gq_valid_customer_email_v45(text) from public,anon,authenticated;

-- gq_request_quote_v45(text,text,text,text,jsonb,uuid,text,text,text,text,text,text,text,text)
CREATE OR REPLACE FUNCTION public.gq_request_quote_v45(p_name text, p_baby_name text, p_contact text, p_note text, p_items jsonb, p_customer_key uuid, p_delivery_method text, p_recipient_name text, p_postal_code text, p_address_line1 text, p_address_line2 text, p_delivery_note text, p_lookup_pin text, p_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; v_email text;
begin
 v_email:=gq_private.gq_valid_customer_email_v45(p_email);
 if v_email is null then raise exception '이메일 주소를 입력해 주세요.' using errcode='22023'; end if;
 v:=public.gq_request_quote_v29(p_name,p_baby_name,p_contact,p_note,p_items,
 p_customer_key,p_delivery_method,p_recipient_name,p_postal_code,
 p_address_line1,p_address_line2,p_delivery_note,p_lookup_pin);
 update public.gq_quotes set customer_email=v_email where id=(v->>'id')::uuid;
 if not found then raise exception '이메일 저장에 실패했어요.'; end if;
 return v;
end $function$
revoke all on function public.gq_request_quote_v45(text,text,text,text,jsonb,uuid,text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.gq_request_quote_v45(text,text,text,text,jsonb,uuid,text,text,text,text,text,text,text,text) to anon,authenticated;

-- gq_submit_product_request_v45(text,text,text,text,text,text[],text,text)
CREATE OR REPLACE FUNCTION public.gq_submit_product_request_v45(p_store_name text, p_product_name text, p_customer_name text, p_note text, p_photo_path text, p_extra_photo_paths text[], p_category text, p_email text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id uuid;v_email text;
begin
 v_email:=gq_private.gq_valid_customer_email_v45(p_email);
 if v_email is null then raise exception '이메일 주소를 입력해 주세요.' using errcode='22023'; end if;
 v_id:=public.gq_submit_product_request_v36(p_store_name,p_product_name,
 p_customer_name,p_note,p_photo_path,p_extra_photo_paths,p_category);
 update public.gq_product_requests set customer_email=v_email where id=v_id;
 if not found then raise exception '이메일 저장에 실패했어요.'; end if;
 return v_id;
end $function$
revoke all on function public.gq_submit_product_request_v45(text,text,text,text,text,text[],text,text) from public,anon,authenticated;
grant execute on function public.gq_submit_product_request_v45(text,text,text,text,text,text[],text,text) to anon,authenticated;

-- gq_admin_set_customer_email_v45(text,uuid,text)
CREATE OR REPLACE FUNCTION public.gq_admin_set_customer_email_v45(p_kind text, p_id uuid, p_email text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_email text;
begin
 if not public.gq_is_admin() then raise exception '관리자 권한이 필요해요.' using errcode='42501'; end if;
 v_email:=gq_private.gq_valid_customer_email_v45(p_email);
 if p_kind='quote' then
  update public.gq_quotes set customer_email=v_email where id=p_id;
 elsif p_kind='product_request' then
  update public.gq_product_requests set customer_email=v_email where id=p_id;
 else raise exception '대상 유형이 올바르지 않아요.' using errcode='22023';
 end if;
 if not found then raise exception '신청 또는 주문을 찾지 못했어요.' using errcode='22023'; end if;
 return true;
end $function$
revoke all on function public.gq_admin_set_customer_email_v45(text,uuid,text) from public,anon,authenticated;
grant execute on function public.gq_admin_set_customer_email_v45(text,uuid,text) to authenticated;

-- gq_admin_email_settings_v45()
CREATE OR REPLACE FUNCTION public.gq_admin_email_settings_v45()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v record;
begin
 if not public.gq_is_admin() then raise exception '관리자 권한이 필요해요.' using errcode='42501'; end if;
 select from_email,enabled,api_secret_id into v
 from gq_private.gq_email_settings_v45 where singleton;
 return jsonb_build_object('from_email',coalesce(v.from_email,''),
   'enabled',coalesce(v.enabled,false),
   'configured',v.api_secret_id is not null,
   'pending',(select count(*) from gq_private.gq_email_outbox_v45 where status in ('pending','submitted')),
   'sent',(select count(*) from gq_private.gq_email_outbox_v45 where status='sent'),
   'failed',(select count(*) from gq_private.gq_email_outbox_v45 where status='failed'));
end $function$
revoke all on function public.gq_admin_email_settings_v45() from public,anon,authenticated;
grant execute on function public.gq_admin_email_settings_v45() to authenticated;

-- gq_admin_configure_email_v45(text,text,boolean)
CREATE OR REPLACE FUNCTION public.gq_admin_configure_email_v45(p_from_email text, p_api_key text, p_enabled boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_email text; v_key text:=btrim(coalesce(p_api_key,'')); v_id uuid; v_secret_id uuid;
begin
 if not public.gq_is_admin() then raise exception '관리자 권한이 필요해요.' using errcode='42501'; end if;
 v_email:=gq_private.gq_valid_customer_email_v45(p_from_email);
 if coalesce(p_enabled,false) and v_email is null then
  raise exception '발신 이메일 주소를 입력해 주세요.' using errcode='22023';
 end if;
 select api_secret_id into v_id from gq_private.gq_email_settings_v45 where singleton for update;
 if v_key<>'' then
  if v_key !~ '^re_[A-Za-z0-9_]{12,128}$' then
   raise exception 'Resend API 키(re_로 시작)를 확인해 주세요.' using errcode='22023';
  end if;
  if v_id is null then
   select vault.create_secret(v_key,'miniyena_resend_api_key_v45','MINIYENA transactional emails') into v_id;
  else
   perform vault.update_secret(v_id,v_key);
  end if;
 end if;
 if coalesce(p_enabled,false) and v_id is null then
  raise exception 'Resend API 키를 먼저 등록해 주세요.' using errcode='22023';
 end if;
 update gq_private.gq_email_settings_v45
 set from_email=v_email,enabled=coalesce(p_enabled,false),
     api_secret_id=v_id,updated_at=now()
 where singleton;
 return true;
end $function$
revoke all on function public.gq_admin_configure_email_v45(text,text,boolean) from public,anon,authenticated;
grant execute on function public.gq_admin_configure_email_v45(text,text,boolean) to authenticated;

-- gq_private.gq_queue_quote_email_v45()
CREATE OR REPLACE FUNCTION gq_private.gq_queue_quote_email_v45()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_event text; v_value text:='';
begin
 if new.customer_email is null then return new; end if;
 if new.status is distinct from old.status then
  v_event:=case new.status
   when 'quoted' then 'quote_ready'
   when 'confirmed' then 'order_confirmed'
   when 'cancelled' then 'order_cancelled'
   else null end;
  v_value:=new.status;
 elsif new.status='confirmed' and new.workflow_stage is distinct from old.workflow_stage then
  v_event:='order_progress';v_value:=coalesce(new.workflow_stage,'new');
 end if;
 if v_event is not null then
  insert into gq_private.gq_email_outbox_v45(kind,object_id,event,event_value)
  values('quote',new.id,v_event,v_value);
 end if;
 return new;
end $function$
revoke all on function gq_private.gq_queue_quote_email_v45() from public,anon,authenticated;

-- gq_private.gq_queue_request_email_v45()
CREATE OR REPLACE FUNCTION gq_private.gq_queue_request_email_v45()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.customer_email is not null and new.status is distinct from old.status
  and new.status in ('approved','rejected') then
  insert into gq_private.gq_email_outbox_v45(kind,object_id,event,event_value)
  values('product_request',new.id,case new.status when 'approved' then 'product_approved' else 'product_rejected' end,new.status);
 end if;
 return new;
end $function$
revoke all on function gq_private.gq_queue_request_email_v45() from public,anon,authenticated;

-- gq_admin_queue_current_email_v45(text,uuid)
CREATE OR REPLACE FUNCTION public.gq_admin_queue_current_email_v45(p_kind text, p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_event text;v_value text;v_email text;v_status text;
begin
 if not public.gq_is_admin() then raise exception '관리자 권한이 필요해요.' using errcode='42501'; end if;
 if p_kind='quote' then
  select customer_email,status into v_email,v_status from public.gq_quotes where id=p_id;
  if not found then raise exception '주문을 찾지 못했어요.';end if;
  if v_status='requested' then raise exception '견적을 완료한 뒤 이메일을 보낼 수 있어요.';end if;
  v_event:=case v_status when 'quoted' then 'quote_ready' when 'confirmed' then 'order_confirmed' when 'cancelled' then 'order_cancelled' end;
  v_value:=v_status;
 elsif p_kind='product_request' then
  select customer_email,status into v_email,v_status from public.gq_product_requests where id=p_id;
  if not found then raise exception '상품등록 신청을 찾지 못했어요.';end if;
  if v_status='pending' then raise exception '상품 등록 여부를 처리한 뒤 이메일을 보낼 수 있어요.';end if;
  v_event:=case v_status when 'approved' then 'product_approved' when 'rejected' then 'product_rejected' end;
  v_value:=v_status;
 else raise exception '대상 유형이 올바르지 않아요.';end if;
 if v_email is null then raise exception '먼저 신청자의 이메일 주소를 등록해 주세요.';end if;
 if v_event is null then raise exception '발송할 상태가 없어요.';end if;
 insert into gq_private.gq_email_outbox_v45(kind,object_id,event,event_value)
 values(p_kind,p_id,v_event,v_value);
 return true;
end $function$
revoke all on function public.gq_admin_queue_current_email_v45(text,uuid) from public,anon,authenticated;
grant execute on function public.gq_admin_queue_current_email_v45(text,uuid) to authenticated;

-- gq_private.gq_dispatch_customer_emails_v46()
CREATE OR REPLACE FUNCTION gq_private.gq_dispatch_customer_emails_v46()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_from text; v_enabled boolean; v_secret_id uuid; v_key text;
 v_row record; v_email text; v_customer text; v_product text;
 v_lookup_token uuid; v_subject text; v_message text; v_link text;
 v_payload jsonb; v_request_id bigint; v_sent integer:=0; v_status text;
begin
 -- Reconcile asynchronous HTTP results. "Sent" means accepted by Resend's API,
 -- not guaranteed inbox delivery.
 update gq_private.gq_email_outbox_v45 o
 set status=case
  when r.status_code between 200 and 299 then 'sent'
  when o.attempts<3 and coalesce(r.status_code,0)>=500 then 'pending'
  when o.attempts<3 and r.timed_out then 'pending'
  else 'failed' end,
  sent_at=case when r.status_code between 200 and 299 then now() else null end,
  last_error=case when r.status_code between 200 and 299 then null
   else left(coalesce(r.error_msg,'HTTP '||r.status_code::text,'전송 응답 확인 실패'),250) end
 from net._http_response r
 where o.status='submitted' and o.net_request_id=r.id
  and o.submitted_at<now()-interval '20 seconds';

 update gq_private.gq_email_outbox_v45 o
 set status=case when attempts<3 then 'pending' else 'failed' end,
 last_error='네트워크 응답 시간 초과'
 where o.status='submitted' and o.submitted_at<now()-interval '4 minutes'
  and not exists(select 1 from net._http_response r where r.id=o.net_request_id);

 select from_email,enabled,api_secret_id
 into v_from,v_enabled,v_secret_id
 from gq_private.gq_email_settings_v45 where singleton;

 if not coalesce(v_enabled,false) or v_secret_id is null or v_from is null then return 0;end if;

 select decrypted_secret into v_key from vault.decrypted_secrets
 where id=v_secret_id;
 if v_key is null or v_key='' then return 0;end if;

 for v_row in
  select * from gq_private.gq_email_outbox_v45
  where status='pending' and attempts<3
  order by queued_at,id limit 12 for update skip locked
 loop
  begin
   v_payload:=v_row.payload;
   if v_payload is null then
    v_email:=null;v_customer:=null;v_product:=null;v_lookup_token:=null;v_link:=null;
    if v_row.kind='quote' then
     select q.customer_email,q.buyer_name,q.lookup_token
     into v_email,v_customer,v_lookup_token
     from public.gq_quotes q where q.id=v_row.object_id;
     if v_lookup_token is not null then
      v_link:='https://nostaljian.github.io/gonggu/?page=track&id='||
       v_row.object_id::text||'&token='||v_lookup_token::text;
     end if;
     if v_row.event='quote_ready' then
      v_subject:='[미니예나] 견적 안내가 준비됐어요';
      v_message:='요청하신 견적이 준비됐어요. 아래 개인 주문조회 링크에서 금액과 배송비를 확인하고 최종 주문을 진행해 주세요.';
     elsif v_row.event='order_confirmed' then
      v_subject:='[미니예나] 최종 주문이 확정됐어요';
      v_message:='최종 주문이 접수되고 확정됐어요. 진행 상황은 아래 링크에서 확인하실 수 있어요.';
     elsif v_row.event='order_cancelled' then
      v_subject:='[미니예나] 주문 취소 안내';
      v_message:='주문 상태가 취소로 변경됐어요. 관련 문의는 미니예나 판매자에게 연락해 주세요.';
     elsif v_row.event='order_progress' then
      v_status:=case v_row.event_value
       when 'new' then '상품 준비 전'
       when 'preparing' then '상품 준비 중'
       when 'pickup_ready' then '직접수령 대기'
       when 'shipped' then '배송 중'
       when 'completed' then '수령·배송 완료'
       when 'soldout_closed' then '품절·환불 정산 완료'
       else coalesce(nullif(v_row.event_value,''),'변경됨') end;
      v_subject:='[미니예나] 주문 진행 상태: '||v_status;
      v_message:='주문 진행 상태가 ['||v_status||'](으)로 변경됐어요. 자세한 정보는 아래 개인 주문조회 링크에서 확인해 주세요.';
     else
      update gq_private.gq_email_outbox_v45 set status='skipped',
       last_error='알 수 없는 주문 알림 유형' where id=v_row.id;
      continue;
     end if;
    elsif v_row.kind='product_request' then
     select r.customer_email,r.customer_name,r.product_name
     into v_email,v_customer,v_product
     from public.gq_product_requests r where r.id=v_row.object_id;
     v_link:='https://nostaljian.github.io/gonggu/?page=shop';
     if v_row.event='product_approved' then
      v_subject:='[미니예나] 신청하신 상품이 등록됐어요';
      v_message:='신청하신 상품 ['||coalesce(v_product,'상품')||']의 등록이 완료됐어요. 상품 공개 상태에 따라 쇼핑몰에서 확인하거나 주문할 수 있어요.';
     elsif v_row.event='product_rejected' then
      v_subject:='[미니예나] 상품 등록 신청 결과 안내';
      v_message:='신청하신 상품 ['||coalesce(v_product,'상품')||']은 이번에 등록되지 않았어요. 자세한 사항은 미니예나 판매자에게 문의해 주세요.';
     else
      update gq_private.gq_email_outbox_v45 set status='skipped',
       last_error='알 수 없는 상품 신청 알림 유형' where id=v_row.id;
      continue;
     end if;
    end if;
    if v_email is null then
     update gq_private.gq_email_outbox_v45 set status='skipped',
      last_error='수신 이메일 없음' where id=v_row.id;
     continue;
    end if;
    v_payload:=jsonb_build_object('from','MINIYENA <'||v_from||'>',
      'to',jsonb_build_array(v_email),'subject',v_subject,
      'text',coalesce(v_customer,'고객')||'님, 안녕하세요.'||E'\n\n'||
       v_message||E'\n\n'||
       coalesce('확인 링크: '||v_link||E'\n\n','')||
       '이 메일은 미니예나에서 신청하신 견적·주문 또는 상품 등록 상태 안내입니다.'||E'\n'||
       '신청한 적이 없다면 이 메일은 무시해 주세요.');
    update gq_private.gq_email_outbox_v45 set payload=v_payload where id=v_row.id;
   end if;
   v_request_id:=net.http_post(url:='https://api.resend.com/emails',
     body:=v_payload,
     headers:=jsonb_build_object('Content-Type','application/json',
       'Authorization','Bearer '||v_key,
       'Idempotency-Key','miniyena-email-'||v_row.id::text),
     timeout_milliseconds:=12000);
   update gq_private.gq_email_outbox_v45
   set status='submitted',net_request_id=v_request_id,
       submitted_at=clock_timestamp(),attempts=attempts+1,
       last_error=null
   where id=v_row.id;
   v_sent:=v_sent+1;
  exception when others then
   update gq_private.gq_email_outbox_v45
   set status='failed',attempts=attempts+1,last_error=left(SQLERRM,250)
   where id=v_row.id;
  end;
 end loop;
 return v_sent;
end $function$
revoke all on function gq_private.gq_dispatch_customer_emails_v46() from public,anon,authenticated;

-- gq_admin_retry_customer_emails_v46()
CREATE OR REPLACE FUNCTION public.gq_admin_retry_customer_emails_v46()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_count integer;
begin
 if not public.gq_is_admin() then
  raise exception '관리자 권한이 필요해요.' using errcode='42501';
 end if;
 update gq_private.gq_email_outbox_v45
 set status='pending',attempts=0,net_request_id=null,
  submitted_at=null,payload=null,last_error=null
 where status='failed';
 get diagnostics v_count=row_count;
 return v_count;
end $function$
revoke all on function public.gq_admin_retry_customer_emails_v46() from public,anon,authenticated;
grant execute on function public.gq_admin_retry_customer_emails_v46() to authenticated;

-- Event hooks: enqueue on genuine changes, not on email field edits.
drop trigger if exists gq_queue_quote_email_v45 on public.gq_quotes;
create trigger gq_queue_quote_email_v45
 after update of status,workflow_stage on public.gq_quotes
 for each row execute function gq_private.gq_queue_quote_email_v45();

drop trigger if exists gq_queue_request_email_v45 on public.gq_product_requests;
create trigger gq_queue_request_email_v45
 after update of status on public.gq_product_requests
 for each row execute function gq_private.gq_queue_request_email_v45();

create extension if not exists pg_cron with schema pg_catalog;
do $do$
begin
 if not exists(select 1 from cron.job where jobname='miniyena-customer-email-v46') then
  perform cron.schedule('miniyena-customer-email-v46','* * * * *',
   'select gq_private.gq_dispatch_customer_emails_v46()');
 end if;
end $do$;
