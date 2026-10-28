-- MINIYENA v51: Emails when already published quote prices change.
-- New quote statuses still use v45 notifications; item-price and shipping-price
-- updates in quoted/confirmed orders are grouped into one queued email
-- after 90 seconds of inactivity. No email is queued for draft requests.
--
-- Resend will reject a Gmail, Naver or other shared mailbox as the sender
-- with HTTP 403. Prevent further futile send attempts and display a clear
-- administrator warning. A verified sender domain is still required.
-- This file contains NO API keys or customer addresses.
--
-- Queue deduplication while pending:
create unique index if not exists gq_email_one_pending_amount_change_v51
 on gq_private.gq_email_outbox_v45(kind,object_id,event)
 where status='pending' and event in ('quote_updated','order_amount_updated');

-- gq_private.gq_sender_domain_needs_verification_v51(text)
CREATE OR REPLACE FUNCTION gq_private.gq_sender_domain_needs_verification_v51(p_email text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
 select lower(split_part(coalesce(p_email,''),'@',2)) in
  ('gmail.com','googlemail.com','naver.com','daum.net','hanmail.net',
   'kakao.com','outlook.com','hotmail.com','live.com','yahoo.com','icloud.com');
$function$;
revoke all on function gq_private.gq_sender_domain_needs_verification_v51(text) from public,anon,authenticated;

-- gq_private.gq_queue_amount_change_v51(uuid)
CREATE OR REPLACE FUNCTION gq_private.gq_queue_amount_change_v51(p_quote_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_status text;v_recipient text;v_event text;
begin
 select status,customer_email into v_status,v_recipient
 from public.gq_quotes where id=p_quote_id;
 if not found or v_recipient is null or v_status not in ('quoted','confirmed') then return;end if;
 v_event:=case v_status when 'quoted' then 'quote_updated' else 'order_amount_updated' end;
 -- Prevent multiple edits in quick succession from producing multiple emails.
 perform pg_advisory_xact_lock(hashtextextended('gq_amount_email:'||p_quote_id::text,0));

 -- If the original quote announcement is still queued, that email already
 -- links to the live price. It is sufficient, without a redundant update mail.
 if v_status='quoted' and exists(
   select 1 from gq_private.gq_email_outbox_v45 o
   where o.kind='quote' and o.object_id=p_quote_id
    and o.event='quote_ready' and o.status='pending'
 ) then return;end if;

 if v_status='confirmed' and exists(
   select 1 from gq_private.gq_email_outbox_v45 o
   where o.kind='quote' and o.object_id=p_quote_id
    and o.event='order_confirmed' and o.status='pending'
 ) then return;end if;

 insert into gq_private.gq_email_outbox_v45
  (kind,object_id,event,event_value,queued_at)
 values('quote',p_quote_id,v_event,v_status,clock_timestamp())
 on conflict(kind,object_id,event) where status='pending'
  and event in ('quote_updated','order_amount_updated')
 do update set queued_at=excluded.queued_at,payload=null,event_value=excluded.event_value;
end $function$;
revoke all on function gq_private.gq_queue_amount_change_v51(uuid) from public,anon,authenticated;

-- gq_private.gq_queue_item_price_change_v51()
CREATE OR REPLACE FUNCTION gq_private.gq_queue_item_price_change_v51()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.unit_price is distinct from old.unit_price then
  perform gq_private.gq_queue_amount_change_v51(new.quote_id);
 end if;
 return new;
end $function$;
revoke all on function gq_private.gq_queue_item_price_change_v51() from public,anon,authenticated;

-- gq_private.gq_queue_shipping_amount_change_v51()
CREATE OR REPLACE FUNCTION gq_private.gq_queue_shipping_amount_change_v51()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.shipping_fee is distinct from old.shipping_fee or
    new.supplier_shipping_share is distinct from old.supplier_shipping_share then
  perform gq_private.gq_queue_amount_change_v51(new.id);
 end if;
 return new;
end $function$;
revoke all on function gq_private.gq_queue_shipping_amount_change_v51() from public,anon,authenticated;

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
 -- Resend rejects public mailbox domains as senders (e.g. gmail.com, HTTP 403).
 -- Keep queued messages intact until the seller configures a verified domain.
 if gq_private.gq_sender_domain_needs_verification_v51(v_from) then return 0;end if;

 select decrypted_secret into v_key from vault.decrypted_secrets
 where id=v_secret_id;
 if v_key is null or v_key='' then return 0;end if;

 for v_row in
  select * from gq_private.gq_email_outbox_v45
  where status='pending' and attempts<3
    and (event not in ('quote_updated','order_amount_updated')
       or queued_at<=clock_timestamp()-interval '90 seconds')
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
     if v_row.event='quote_updated' then
      v_subject:='[미니예나] 견적 금액이 수정됐어요';
      v_message:='이미 안내드린 견적의 상품 가격 또는 배송비가 변경됐어요. 아래 주문조회 링크에서 최신 견적 금액과 결제 총액을 확인해 주세요. 이전 안내 금액 대신 변경된 금액을 기준으로 확인 부탁드려요.';
     elsif v_row.event='order_amount_updated' then
      v_subject:='[미니예나] 확정 주문 금액이 변경됐어요';
      v_message:='확정된 주문의 상품 가격 또는 배송비가 변경됐어요. 아래 주문조회 링크에서 변경 금액을 확인해 주세요. 이미 입금하셨다면 차액 및 환불 여부를 판매자에게 문의해 주세요.';
     elsif v_row.event='quote_ready' then
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
end $function$;
revoke all on function gq_private.gq_dispatch_customer_emails_v46() from public,anon,authenticated;

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
 if coalesce(p_enabled,false) and
  gq_private.gq_sender_domain_needs_verification_v51(v_email) then
  raise exception 'Resend에서는 Gmail·네이버 등 개인 메일 주소로 고객에게 발송할 수 없어요. 본인 소유의 도메인을 Resend에서 인증하고 그 도메인의 발신 이메일을 등록해 주세요.'
   using errcode='22023';
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
end $function$;
revoke all on function public.gq_admin_configure_email_v45(text,text,boolean) from public,anon,authenticated;
grant execute on function public.gq_admin_configure_email_v45(text,text,boolean) to authenticated;

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
   'needs_verified_domain',gq_private.gq_sender_domain_needs_verification_v51(v.from_email),
   'last_failure',(
    select case when o.last_error='HTTP 403'
       then 'Resend에서 발신 주소의 도메인 인증을 거부했어요 (HTTP 403).'
       else coalesce(o.last_error,'이메일 전송 요청 실패') end
    from gq_private.gq_email_outbox_v45 o where o.status='failed'
    order by o.queued_at desc,o.id desc limit 1),
   'last_failure_at',(
    select o.queued_at from gq_private.gq_email_outbox_v45 o
    where o.status='failed' order by o.queued_at desc,o.id desc limit 1),
   'pending',(select count(*) from gq_private.gq_email_outbox_v45 where status in ('pending','submitted')),
   'sent',(select count(*) from gq_private.gq_email_outbox_v45 where status='sent'),
   'failed',(select count(*) from gq_private.gq_email_outbox_v45 where status='failed'));
end $function$;
revoke all on function public.gq_admin_email_settings_v45() from public,anon,authenticated;
grant execute on function public.gq_admin_email_settings_v45() to authenticated;

-- Only real unit-price changes on already-announced quotes trigger this email.
drop trigger if exists gq_notify_item_price_change_v51 on public.gq_quote_items;
create trigger gq_notify_item_price_change_v51
 after update of unit_price on public.gq_quote_items
 for each row when(old.unit_price is distinct from new.unit_price)
 execute function gq_private.gq_queue_item_price_change_v51();

-- Changing the final customer shipping fee or supplier's share also changes
-- what the customer needs to pay and must be notified.
drop trigger if exists gq_notify_shipping_amount_change_v51 on public.gq_quotes;
create trigger gq_notify_shipping_amount_change_v51
 after update of shipping_fee,supplier_shipping_total,supplier_shipping_people
 on public.gq_quotes
 for each row execute function gq_private.gq_queue_shipping_amount_change_v51();
