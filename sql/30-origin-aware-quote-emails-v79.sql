-- v79: retain the existing link for existing customers; record the originating public URL for new quotes.
ALTER TABLE public.gq_quotes
 ADD COLUMN IF NOT EXISTS notification_origin text NOT NULL DEFAULT 'https://nostaljian.github.io/gonggu/';
ALTER TABLE public.gq_quotes
 DROP CONSTRAINT IF EXISTS gq_quotes_notification_origin_v79_check;
ALTER TABLE public.gq_quotes
 ADD CONSTRAINT gq_quotes_notification_origin_v79_check CHECK (
  notification_origin IN ('https://nostaljian.github.io/gonggu/','https://miniyena.pages.dev/')
 );
CREATE OR REPLACE FUNCTION public.gq_request_quote_v8(p_name text, p_baby_name text, p_contact text, p_note text, p_items jsonb, p_customer_key uuid, p_delivery_method text, p_recipient_name text, p_postal_code text, p_address_line1 text, p_address_line2 text, p_delivery_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_result jsonb; v_id uuid;
BEGIN
 IF p_delivery_method IS NULL OR p_delivery_method NOT IN ('pickup','courier') THEN
  RAISE EXCEPTION '수령방식을 선택해 주세요';
 END IF;
 IF p_delivery_method='courier' THEN
  IF char_length(btrim(coalesce(p_recipient_name,''))) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION '받는 사람 이름을 입력해 주세요'; END IF;
  IF btrim(coalesce(p_postal_code,'')) !~ '^[0-9]{5}$' THEN RAISE EXCEPTION '우편번호 5자리를 입력해 주세요'; END IF;
  IF char_length(btrim(coalesce(p_address_line1,''))) NOT BETWEEN 4 AND 250 THEN RAISE EXCEPTION '택배 받을 주소를 입력해 주세요'; END IF;
  IF char_length(coalesce(p_address_line2,''))>250 OR char_length(coalesce(p_delivery_note,''))>200 THEN RAISE EXCEPTION '배송 상세정보가 너무 길어요'; END IF;
 END IF;
 SELECT public.gq_request_quote_v7(p_name,p_baby_name,p_contact,p_note,p_items,p_customer_key) INTO v_result;
 v_id := (v_result->>'id')::uuid;
 UPDATE public.gq_quotes SET
  delivery_method=p_delivery_method,
  recipient_name=CASE WHEN p_delivery_method='courier' THEN btrim(p_recipient_name) ELSE NULL END,
  postal_code=CASE WHEN p_delivery_method='courier' THEN btrim(p_postal_code) ELSE NULL END,
  address_line1=CASE WHEN p_delivery_method='courier' THEN btrim(p_address_line1) ELSE NULL END,
  address_line2=CASE WHEN p_delivery_method='courier' THEN nullif(btrim(coalesce(p_address_line2,'')),'') ELSE NULL END,
  delivery_note=CASE WHEN p_delivery_method='courier' THEN nullif(btrim(coalesce(p_delivery_note,'')),'') ELSE NULL END,
  shipping_fee=CASE WHEN p_delivery_method='courier' THEN 3000 ELSE 0 END,
  notification_origin=CASE WHEN
    (nullif(current_setting('request.headers',true),'')::jsonb->>'origin')='https://miniyena.pages.dev'
    THEN 'https://miniyena.pages.dev/' ELSE 'https://nostaljian.github.io/gonggu/' END
 WHERE id=v_id AND lookup_token=(v_result->>'token')::uuid;
 RETURN v_result;
END;
$function$;
CREATE OR REPLACE FUNCTION gq_private.gq_dispatch_customer_emails_v52()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_state record;
 v_config record;
 v_result record;
 v_row record;
 v_response_status text;
 v_mail text;
 v_name text;
 v_product text;
 v_token uuid;
 v_subject text;
 v_message text;
 v_link text;
 v_origin text;
 v_body text;
 v_event text;
 v_opt record;
 v_request bigint;
 v_submitted integer := 0;
begin
 -- Webhook must use the same nonpublic secret and deployment URL as the existing admin notifications.
 select endpoint_url,shared_secret,enabled into v_config
 from gq_private.notification_config where id=1;
 select * into v_state from gq_private.gq_gmail_state_v52 where singleton for update;
 if not coalesce(v_config.enabled,false) or
    coalesce(v_config.endpoint_url,'') !~ '^https://script[.]google[.]com/macros/s/[^/]+/exec$' then
   return 0;
 end if;

 -- Reconcile completed asynchronous Gmail responses, not just HTTP 200.
 for v_row in
   select o.id,o.attempts,r.status_code,r.content,r.error_msg,r.timed_out
   from gq_private.gq_email_outbox_v45 o
   join net._http_response r on o.net_request_id=r.id
   where o.status='submitted' and o.submitted_at<clock_timestamp()-interval '15 seconds'
   for update of o skip locked
 loop
   v_response_status := '';
   if v_row.content is not null then
     v_response_status := case
       when strpos(v_row.content,'"customer_email_sent"')>0 then 'customer_email_sent'
       when strpos(v_row.content,'"customer_email_duplicate"')>0 then 'customer_email_duplicate'
       when strpos(v_row.content,'"unsupported"')>0 then 'unsupported'
       when strpos(v_row.content,'"unauthorized"')>0 then 'unauthorized'
       when strpos(v_row.content,'"daily_quota_exceeded"')>0 then 'daily_quota_exceeded'
       when strpos(v_row.content,'"busy_retry_later"')>0 then 'busy_retry_later'
       when strpos(v_row.content,'"customer_email_error"')>0 then 'customer_email_error'
       when strpos(v_row.content,'"invalid_customer_email"')>0 then 'invalid_customer_email'
       else '' end;
   end if;
   if v_row.status_code between 200 and 299
      and v_response_status in ('customer_email_sent','customer_email_duplicate') then
     update gq_private.gq_email_outbox_v45
        set status='sent',sent_at=now(),last_error=null
      where id=v_row.id;
   elsif v_response_status in ('unsupported','unauthorized') then
     update gq_private.gq_email_outbox_v45
        set status='pending',attempts=0,submitted_at=null,net_request_id=null,
            last_error='Gmail 스크립트 배포 또는 보안키 확인 필요'
      where id=v_row.id;
     update gq_private.gq_gmail_state_v52
       set connected=false,last_probe_at=null,last_probe_request_id=null,
           last_probe_error='Gmail 스크립트 배포 또는 보안키 확인 필요'
       where singleton;
   else
     update gq_private.gq_email_outbox_v45
       set status=case when attempts<3 then 'pending' else 'failed' end,
           submitted_at=null,net_request_id=null,
           last_error=left(case
             when v_response_status<>'' then v_response_status
             when v_row.timed_out then 'Gmail 요청 시간 초과'
             else coalesce(v_row.error_msg,'HTTP '||coalesce(v_row.status_code::text,'응답 없음')) end,250)
       where id=v_row.id;
   end if;
 end loop;

 -- A response that never arrived can be retried; Apps Script deduplicates by outbox ID.
 update gq_private.gq_email_outbox_v45
   set status=case when attempts<3 then 'pending' else 'failed' end,
       last_error='Gmail 응답 시간 초과',net_request_id=null,submitted_at=null
 where status='submitted' and submitted_at<now()-interval '4 minutes'
   and not exists(select 1 from net._http_response r where r.id=net_request_id);

 -- The Google Apps Script deployment must explicitly confirm the customer-mail version.
 if not coalesce(v_state.connected,false) then
   if v_state.last_probe_request_id is not null
      and v_state.last_probe_at<now()-interval '15 seconds' then
     select r.status_code,coalesce(r.content,'') as content,r.error_msg
       into v_result from net._http_response r
       where r.id=v_state.last_probe_request_id;
     if found then
       if v_result.status_code between 200 and 299
          and strpos(v_result.content,'"customer_email_ready"')>0 then
         update gq_private.gq_gmail_state_v52
         set connected=true,connected_at=now(),last_probe_error=null
         where singleton;
         v_state.connected := true;
       else
         update gq_private.gq_gmail_state_v52
          set last_probe_error=case
              when strpos(v_result.content,'"unsupported"')>0
                 then 'Apps Script 고객메일 코드 배포가 필요해요.'
              when strpos(v_result.content,'"daily_quota_exceeded"')>0
                 then '현재 Gmail 일일 발송 한도가 소진됐어요.'
              else 'Gmail 연결 확인 응답 오류' end,
              last_probe_request_id=null
         where singleton;
       end if;
     elsif v_state.last_probe_at<now()-interval '2 minutes' then
       update gq_private.gq_gmail_state_v52
       set last_probe_request_id=null,last_probe_error='Gmail 연결 확인 응답 시간 초과'
       where singleton;
     end if;
   end if;
   if not coalesce(v_state.connected,false) then
     select * into v_state from gq_private.gq_gmail_state_v52 where singleton;
     if v_state.last_probe_request_id is null and
       (v_state.last_probe_at is null or v_state.last_probe_at<now()-interval '3 minutes') then
       v_request := net.http_post(
         url:=v_config.endpoint_url,
         body:=jsonb_build_object('secret',v_config.shared_secret,'event','customer_email_probe'),
         headers:='{"Content-Type":"application/json"}'::jsonb,
         timeout_milliseconds:=12000);
       update gq_private.gq_gmail_state_v52
         set last_probe_request_id=v_request,last_probe_at=now()
        where singleton;
     end if;
     return 0;
   end if;
 end if;

 -- Respect the existing automatic customer notification enable setting.
 if not (select enabled from gq_private.gq_email_settings_v45 where singleton) then
   return 0;
 end if;

 for v_row in
   select * from gq_private.gq_email_outbox_v45
   where status='pending' and attempts<3
     and (event not in ('quote_updated','order_amount_updated','order_options_updated')
       or queued_at<clock_timestamp()-interval '90 seconds')
   order by queued_at,id limit 12 for update skip locked
 loop
   begin
     v_mail:=null;v_name:=null;v_product:=null;v_token:=null;v_link:=null;
     v_subject:=null;v_message:=null;
     -- A polymorphic RECORD cannot safely be dereferenced before a row type
     -- has been assigned. Initialize a typed empty row every iteration.
     select null::text as status, null::text as old_color,
       null::text as old_size,null::integer as old_quantity,
       null::text as requested_color,null::text as requested_size,
       null::integer as requested_quantity,null::text as decision_note,
       null::text as product_name into v_opt;
     if v_row.kind='quote' then
       select q.customer_email,q.buyer_name,q.lookup_token,q.baby_name,q.notification_origin
          into v_mail,v_name,v_token,v_product,v_origin
        from public.gq_quotes q where q.id=v_row.object_id;
       if v_row.event in ('purchase_now_admin','purchase_later_admin','purchase_next_admin','purchase_hold_admin','cancel_withdrawn_admin','item_option_request_admin','item_option_withdrawn_admin') then
         select from_email into v_mail from gq_private.gq_email_settings_v45 where singleton;
         v_link:='https://nostaljian.github.io/gonggu/?page=admin';
       end if;
       if v_token is not null and v_link is null then
         v_link:=coalesce(nullif(v_origin,''),'https://nostaljian.github.io/gonggu/')||'?page=track&id='||
                   v_row.object_id::text||'&token='||v_token::text;
       end if;
       if v_row.event in ('item_option_request_admin','item_option_decision_customer','item_option_withdrawn_admin') then
         select r.status,r.old_color,r.old_size,r.old_quantity,
            r.requested_color,r.requested_size,r.requested_quantity,
            r.decision_note,i.product_name into v_opt
         from gq_private.gq_option_change_requests_v61 r
         join public.gq_quote_items i on i.id=r.item_id
         where r.id=v_row.event_value::uuid and r.quote_id=v_row.object_id;
       end if;
       if v_row.event='item_option_request_admin' then
         v_subject:='[미니예나] '||coalesce(v_name,'구매자')||'님 주문 옵션 변경 요청';
         v_message:='상품: '||coalesce(v_opt.product_name,'상품')||E'\n'||
          '기존: '||v_opt.old_color||' / '||v_opt.old_size||' ×'||v_opt.old_quantity::text||E'\n'||
          '요청: '||v_opt.requested_color||' / '||v_opt.requested_size||' ×'||v_opt.requested_quantity::text||
          E'\n\n관리자 주문 카드에서 승인 또는 반려해 주세요.';
       elsif v_row.event='item_option_withdrawn_admin' then
         v_subject:='[미니예나] '||coalesce(v_name,'구매자')||'님 옵션변경 요청 취소';
         v_message:='상품: '||coalesce(v_opt.product_name,'상품')||E'\n'||
           '취소된 요청: '||v_opt.requested_color||' / '||v_opt.requested_size||
           ' ×'||v_opt.requested_quantity::text||'개'||E'\n'||
           '기존 주문: '||v_opt.old_color||' / '||v_opt.old_size||
           ' ×'||v_opt.old_quantity::text||'개'||E'\n\n'||
           '구매자가 옵션변경 요청을 취소했습니다. 승인·반려할 필요가 없고 기존 주문은 그대로 유지됩니다.';
       elsif v_row.event='item_option_decision_customer' then
         v_subject:='[미니예나] 상품 옵션 변경 요청 '||
          case when v_opt.status='approved' then '승인' else '반려' end||' 안내';
         v_message:='['||coalesce(v_opt.product_name,'상품')||'] 요청하신 옵션 변경이 '||
          case when v_opt.status='approved' then '승인되어 주문 내역에 반영됐어요.' else '반려됐어요.' end||
          E'\n요청: '||v_opt.requested_color||' / '||v_opt.requested_size||' ×'||v_opt.requested_quantity::text||
          case when v_opt.decision_note<>'' then E'\n안내: '||v_opt.decision_note else '' end||
          E'\n\n아래 주문조회 링크에서 확인해 주세요.';
       elsif v_row.event='cancel_rejected_customer' then
         v_subject:='[미니예나] 취소 요청 반려 안내';
         v_message:='요청하신 취소가 반려되어 기존 주문이 유지됩니다. 주문조회에서 진행 상태를 확인해 주세요.';
       elsif v_row.event='cancel_withdrawn_admin' then
         v_subject:='[미니예나] '||coalesce(v_name,'구매자')||'님 취소 요청 철회';
         v_message:='구매자가 취소 요청을 철회했어요. 기존 견적과 주문은 그대로 유지됩니다.';
       elsif v_row.event='purchase_now_admin' then
         v_subject:='[미니예나] '||coalesce(v_name,'구매자')||'님 이번 회차 구매 희망';
         v_message:='이번 회차에 구매하겠다고 선택했어요. 도매배송비 배분 시 이 구매자를 포함해 주세요.';
       elsif v_row.event in ('purchase_later_admin','purchase_next_admin') then
         v_subject:='[미니예나] '||coalesce(v_name,'구매자')||'님 다음 회차 구매 선택';
         v_message:='이번 회차에는 주문하지 않고 다음 회차에 구매하겠다고 선택했어요. 이번 배송비 계산에서 제외해 주세요.';
       elsif v_row.event='purchase_hold_admin' then
         v_subject:='[미니예나] '||coalesce(v_name,'구매자')||'님 구매 보류';
         v_message:='구매 시점을 정하지 않고 보류를 선택했어요. 이번 배송비 계산에서 제외해 주세요.';
       elsif v_row.event='quote_received' then
         v_subject:='[미니예나] 견적 신청이 접수됐어요';
         v_message:='견적 신청이 정상 접수됐어요. 관리자 확인 후 안내드릴게요. 아래 링크에서 신청 상태를 확인할 수 있어요.';
       elsif v_row.event='quote_updated' then
         v_subject:='[미니예나] 견적 금액이 수정됐어요';
         v_message:='견적의 상품 가격 또는 배송비가 변경됐어요. 최신 견적 금액과 결제 총액을 확인해 주세요.';
       elsif v_row.event='order_amount_updated' then
         v_subject:='[미니예나] 확정 주문 금액이 변경됐어요';
         v_message:='확정된 주문 금액이 변경됐어요. 이미 입금하셨다면 판매자에게 차액을 문의해 주세요.';
       elsif v_row.event='order_options_updated' then
         v_subject:='[미니예나] 주문 상품 옵션이 수정됐어요';
         v_message:='주문하신 상품의 색상·사이즈 또는 수량이 수정됐어요. 아래 링크에서 최신 주문 내역과 결제금액을 확인해 주세요.';
       elsif v_row.event='quote_ready' then
         v_subject:=case when gq_private.gq_quote_is_1688_v71(v_row.object_id)
          then '[미니예나] 1688 견적 확인 후 주문을 확정해 주세요'
          else '[미니예나] 상품 견적과 구매 회차를 확인해 주세요' end;
         v_message:=case when gq_private.gq_quote_is_1688_v71(v_row.object_id)
          then '1688 상품 견적이 준비됐어요. 구매 회차 선택 없이 최종 결제금액을 확인하고 바로 주문을 확정할 수 있어요.'
          else '상품 견적이 준비됐어요. 아래 링크에서 이번 회차 구매, 다음 회차 구매 또는 보류를 선택해 주세요. 도매배송비와 최종 결제금액은 구매 의사를 모은 다음 안내해 드려요.' end;
       elsif v_row.event='quote_shipping_ready' then
         v_subject:='[미니예나] 배송비 및 최종 결제금액이 정해졌어요';
         v_message:='이번 회차 배송비가 계산됐어요. 아래 링크에서 최종 결제금액을 확인하고 주문을 확정해 주세요.';
       elsif v_row.event='order_confirmed' then
         v_subject:='[미니예나] 최종 주문이 확정됐어요';
         v_message:='최종 주문이 확정됐어요. 아래 링크에서 주문 진행 상황을 확인해 주세요.';
       elsif v_row.event='order_cancelled' then
         v_subject:='[미니예나] 주문 취소 안내';
         v_message:='주문 상태가 취소로 변경됐어요. 문의가 필요하면 판매자에게 연락해 주세요.';
       elsif v_row.event='order_progress' then
         v_event:=case v_row.event_value
           when 'new' then '주문 접수'
           when 'preparing' then '상품 준비 중'
           when 'pickup_ready' then '픽업 대기 중'
           when 'shipped' then '배송 중'
           when 'completed' then '수령·배송 완료'
           when 'soldout_closed' then '품절·환불 정산 완료'
           when 'item_received' then '상품 입고 완료'
           when 'item_sold_out' then '주문 상품 품절'
           when 'item_reverted' then '상품 입고 상태 변경'
           when 'item_ordered' then '도매 발주 진행'
           when 'item_options' then '상품 옵션·수량 변경'
           when 'delivery_changed' then '수령방식 변경 승인'
           when 'delivery_rejected' then '수령방식 변경 반려'
           when 'payment_updated' then '입금 확인금액 변경'
           when 'refund_updated' then '환불 처리금액 변경'
           when 'tracking_updated' then '운송장 정보 변경'
           when 'fee_updated' then '배송비·최종 결제금액 변경'
           else '진행 상태 변경' end;
         v_subject:='[미니예나] 주문 진행 상태: '||v_event;
         v_message:='주문 진행 상태가 '||v_event||'(으)로 변경됐어요. 아래 링크에서 확인해 주세요.';
       end if;
     elsif v_row.kind='product_request' then
       select r.customer_email,r.customer_name,r.product_name
          into v_mail,v_name,v_product
       from public.gq_product_requests r where r.id=v_row.object_id;
       v_link:='https://nostaljian.github.io/gonggu/?page=shop';
       if v_row.event='product_received' then
         v_subject:='[미니예나] 상품 등록 신청이 접수됐어요';
         v_message:='신청하신 상품 ['||coalesce(v_product,'상품')||']의 등록 요청이 접수됐어요. 관리자 확인 후 결과를 안내드릴게요.';
       elsif v_row.event='product_approved' then
         v_subject:='[미니예나] 신청하신 상품이 등록됐어요';
         v_message:='신청하신 상품 ['||coalesce(v_product,'상품')||']의 등록이 완료됐어요.';
       elsif v_row.event='product_rejected' then
         v_subject:='[미니예나] 상품 등록 신청 결과 안내';
         v_message:='신청하신 상품 ['||coalesce(v_product,'상품')||']은 이번에 등록되지 않았어요. 자세한 내용은 판매자에게 문의해 주세요.';
       end if;
     end if;
     if nullif(btrim(coalesce(v_mail,'')),'') is null then
       update gq_private.gq_email_outbox_v45
         set status='skipped',last_error='수신 이메일 없음'
       where id=v_row.id;
       continue;
     end if;
     -- Only inspect the option RECORD for option events.
     if v_row.event in ('item_option_request_admin','item_option_decision_customer','item_option_withdrawn_admin') then
       if v_opt is null then
         update gq_private.gq_email_outbox_v45 set status='skipped',last_error='옵션 요청 기록 없음' where id=v_row.id;
         continue;
       end if;
       if v_opt.product_name is null then
         update gq_private.gq_email_outbox_v45 set status='skipped',last_error='옵션 요청 기록 없음' where id=v_row.id;
         continue;
       end if;
     end if;
     -- Skip stale request emails when request is already withdrawn/processed.
     if v_row.event='item_option_request_admin' and v_opt.status<>'pending' then
       update gq_private.gq_email_outbox_v45 set status='skipped',
         last_error='이미 처리·취소된 옵션 변경 요청' where id=v_row.id;
       continue;
     end if;
     if v_subject is null or v_link is null then
       update gq_private.gq_email_outbox_v45
         set status='skipped',last_error='알림 종류 또는 주문 조회 정보 없음'
       where id=v_row.id;
       continue;
     end if;
     if v_row.event in ('purchase_now_admin','purchase_later_admin','purchase_next_admin','purchase_hold_admin','item_option_request_admin','item_option_withdrawn_admin') then
       v_body:='[미니예나 관리자 알림]'||E'\n\n'||
        '구매자: '||coalesce(v_name,'미확인')||E'\n'||
        '아기: '||coalesce(v_product,'미입력')||E'\n'||
        '견적번호: '||v_row.object_id::text||E'\n\n'||
        v_message||E'\n\n관리자 화면: '||v_link;
     else
     v_body:=coalesce(nullif(btrim(v_name),''),'고객')||'님, 안녕하세요.'||E'\n\n'||
       v_message||E'\n\n'||
       '확인 링크: '||v_link||E'\n\n'||
       '이 메일은 미니예나에서 신청하신 견적·주문 또는 상품등록 상태 안내입니다.'||E'\n'||
       '신청한 적이 없다면 이 메일을 무시해 주세요.';
     end if;
     v_request:=net.http_post(
       url:=v_config.endpoint_url,
       body:=jsonb_build_object(
         'secret',v_config.shared_secret,'event','customer_email',
         'mail_id',v_row.id,'to',v_mail,'subject',v_subject,'body',v_body),
       headers:='{"Content-Type":"application/json"}'::jsonb,
       timeout_milliseconds:=12000);
     update gq_private.gq_email_outbox_v45
       set status='submitted',net_request_id=v_request,
           submitted_at=clock_timestamp(),attempts=attempts+1,last_error=null
       where id=v_row.id;
     v_submitted:=v_submitted+1;
   exception when others then
     update gq_private.gq_email_outbox_v45
       set status='failed',attempts=attempts+1,last_error=left(sqlerrm,250)
     where id=v_row.id;
   end;
 end loop;
 return v_submitted;
end
$function$;
