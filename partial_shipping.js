/* MINIYENA partial courier shipments v118: received items first, remaining items stay pending. */
(function(){
'use strict';
let overlay=null,active=null;
const escapeHtml=x=>String(x==null?'':x).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
function sentQty(itemId,history){
 return (Array.isArray(history)?history:[]).reduce((n,p)=>n+(Array.isArray(p.items)?p.items:[]).filter(i=>i.item_id===itemId).reduce((k,i)=>k+Math.max(0,Number(i.quantity)||0),0),0);
}
function arrivedQty(item){return item.fulfillment==='received'||item.fulfillment==='delivered'?Number(item.quantity)||0:Math.max(0,Number(item.received_qty)||0);}
function forOrder(q,history){
 return (Array.isArray(history)?history:[]).filter(p=>(p.items||[]).some(i=>i.quote_id===q.id||!i.quote_id&&(q.items||[]).some(row=>row.id===i.item_id)));
}
function carrierLink(carrier,tracking){
 const s=String(tracking||'').replace(/[\s-]/g,'');
 return /^(롯데택배|롯데|롯데글로벌로지스|lotte|lotteglobal)$/i.test(String(carrier||'').replace(/\s+/g,''))&&/^[A-Za-z0-9]+$/.test(s)
  ?'https://www.lotteglogis.com/home/reservation/tracking/linkView?InvNo='+encodeURIComponent(s):'';
}
function shipmentDate(value){
 const parsed=Date.parse(String(value||''));
 if(!Number.isFinite(parsed))return '';
 const parts=Object.fromEntries(new Intl.DateTimeFormat('en-GB',{
  timeZone:'Asia/Seoul',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'
 }).formatToParts(new Date(parsed)).map(x=>[x.type,x.value]));
 return parts.month+'.'+parts.day+' '+parts.hour+':'+parts.minute;
}
function shipmentEvents(parcel){
 const records=parcel.tracking_events||parcel.events;
 if(!Array.isArray(records))return [];
 return records.filter(e=>e&&typeof e==='object'&&!Array.isArray(e)).map((e,index)=>{
  const time=String(e.time||'');
  const epoch=Date.parse(time);
  return {time,epoch:Number.isFinite(epoch)?epoch:null,index,
   label:String(e.label||e.state||e.status||'배송 처리'),
   place:String(e.location||e.place||''),
   detail:String(e.detail||e.description||'')};
 }).sort((a,b)=>a.epoch===null&&b.epoch===null?a.index-b.index:
  a.epoch===null?1:b.epoch===null?-1:b.epoch-a.epoch||a.index-b.index).slice(0,40);
}
function shipmentStatus(parcel,fallback){
 const s=String(parcel.tracking_status_code||parcel.status_code||'').toUpperCase();
 return s==='DELIVERED'?'배송 완료':s==='OUT_FOR_DELIVERY'?'배송 출발':
  s==='IN_TRANSIT'?'배송 중':s==='AT_PICKUP'?'집하 완료':
  s==='EXCEPTION'?'배송 확인 필요':fallback||'송장 등록';
}
function eventRow(event){
 const date=shipmentDate(event.time);
 const detail=[event.place,event.detail].filter(Boolean).filter((x,i,arr)=>i===0||x!==arr[0]).join(' · ');
 return '<li class="my-shipping-event"><span class="my-shipping-dot" aria-hidden="true"></span>'+
  '<span class="my-shipping-event-body"><strong>'+escapeHtml(event.label)+'</strong>'+
  (detail?'<small>'+escapeHtml(detail)+'</small>':'')+'</span>'+
  (date?'<time>'+escapeHtml(date)+'</time>':'')+'</li>';
}
function buyerShippingCard(q,records){
 if(!records.length)return '';
 style(); // Buyer pages need the same injected stylesheet as the administrator tools.
 const cards=records.map((p,index)=>{
  const carrier=String(p.carrier||'택배');
  const number=String(p.tracking_number||'');
  const href=carrierLink(carrier,number);
  const events=shipmentEvents(p);
  const status=shipmentStatus(p,p._fallback_status);
  const newest=events[0];
  const latestLabel=String(p.tracking_status_label||'').trim()||newest?.label||'';
  const date=shipmentDate(p.created_at);
  const lines=(p.items||[]).filter(i=>!i.quote_id||i.quote_id===q.id);
  const qty=lines.reduce((n,i)=>n+Math.max(0,Number(i.quantity)||0),0);
  const history=events.length?'<div class="my-shipping-events"><div class="my-shipping-subtitle">배송 이력 <small>'+events.length+'건</small></div>'+
    '<ol class="my-shipping-list">'+events.slice(0,3).map(eventRow).join('')+'</ol>'+
    (events.length>3?'<details class="my-shipping-extra"><summary>이전 이동 기록 '+(events.length-3)+'건 더보기</summary><ol class="my-shipping-list">'+events.slice(3).map(eventRow).join('')+'</ol></details>':'')+
    '</div>':'<div class="my-shipping-noevents">택배사 이동 이력 확인 중 · 최신 정보는 배송조회에서 확인할 수 있어요.</div>';
  const itemDetails=records.length>1&&lines.length?
   '<details class="my-shipping-items"><summary>이 송장에 포함된 상품 '+qty+'개</summary><ul>'+
   lines.map(i=>'<li>'+escapeHtml(i.name||q.items?.find(x=>x.id===i.item_id)?.product_name||'상품')+
    ' · '+escapeHtml([i.color,i.size].filter(Boolean).join(' / '))+' ×'+Math.max(0,Number(i.quantity)||0)+'</li>').join('')+'</ul></details>':'';
  return '<div class="my-shipping-parcel">'+
   '<div class="my-shipping-top"><strong>'+escapeHtml(status)+'</strong>'+
   (records.length>1?'<span>'+(index+1)+'번째 발송</span>':date?'<time>'+escapeHtml(date)+' 등록</time>':'')+'</div>'+
   '<div class="my-shipping-invoice"><div class="my-shipping-number"><b>'+escapeHtml(carrier)+'</b><span>'+escapeHtml(number)+'</span></div>'+
   (href?'<a class="my-shipping-link" href="'+href+'" target="_blank" rel="noopener noreferrer">배송조회 ↗</a>':'')+'</div>'+
   (latestLabel&&!events.length&&status!=='배송 완료'?'<p class="my-shipping-current">최근 이동 · '+escapeHtml(latestLabel)+
    (p.tracking_event_time?' <span>'+escapeHtml(shipmentDate(p.tracking_event_time))+'</span>':'')+'</p>':'')+
   history+itemDetails+'</div>';
 }).join('');
 return '<section class="buyer-shipment-card my-shipping-card" aria-label="배송 현황">'+
  '<div class="my-shipping-heading"><h3>배송 현황</h3>'+(records.length>1?'<small>송장 '+records.length+'건</small>':'')+'</div>'+
  cards+'</section>';
}
function parcelHistory(q,history,buyer=false){
 const records=forOrder(q,history);
 if(!records.length)return '';
 if(buyer)return buyerShippingCard(q,records);
 return '<div class="partial-history"><b>부분발송 기록 '+records.length+'건</b>'+
  records.map(p=>{
   const name=escapeHtml(p.carrier||'택배'),number=escapeHtml(p.tracking_number||''),url=carrierLink(p.carrier,p.tracking_number);
   return '<div class="partial-history-package"><strong>'+name+' '+number+'</strong>'+
     (url?'<a href="'+url+'" target="_blank" rel="noopener noreferrer">배송조회 ↗</a>':'')+'</div>';
  }).join('')+'</div>';
}
function singleBuyerMarkup(q,completed){
 if(!q||!q.tracking_number)return '';
 const invoice=String(q.tracking_number||'').replace(/[\s-]/g,'');
 const snap=q.shipment_tracking;
 const matches=!!snap&&String(snap.tracking_number||'').replace(/[\s-]/g,'')===invoice;
 const parcel={carrier:q.tracking_carrier||'택배',tracking_number:q.tracking_number,
  tracking_status_code:matches?snap.status_code:'',
  tracking_status_label:matches?snap.status:'',
  tracking_event_time:matches?snap.event_time:'',
  tracking_events:matches?snap.events:[],
  _fallback_status:completed?'배송 완료':'배송 중'};
 return buyerShippingCard(q,[parcel]);
}
// Same compact tracking timeline for administrators; only pass verified
// carrier data from the admin's existing shipment lookup. No synthetic events.
function adminTrackingMarkup(q,history,verifiedSnapshot){
 if(!q)return '';
 const parcels=forOrder(q,history).map(p=>({...p,_fallback_status:
   p.tracking_status_code==='DELIVERED'?'배송 완료':'배송 중'}));
 const invoice=String(q.tracking_number||'').replace(/[\s-]/g,'');
 if(invoice){
  const snap=verifiedSnapshot&&String(verifiedSnapshot.tracking_number||'').replace(/[\s-]/g,'')===invoice?
   verifiedSnapshot:null;
  const direct={
   carrier:q.tracking_carrier||'택배',
   tracking_number:q.tracking_number,
   tracking_status_code:snap?.status_code||'',
   tracking_status_label:snap?.status||'',
   tracking_event_time:snap?.event_time||'',
   tracking_checked_at:snap?.fetched_at||'',
   tracking_events:Array.isArray(snap?.events)?snap.events:[],
   _fallback_status:q.workflow_stage==='completed'?'배송 완료':'배송 중'
  };
  const existing=parcels.find(p=>String(p.tracking_number||'').replace(/[\s-]/g,'')===invoice);
  if(existing){
   if(!(existing.tracking_events||[]).length&&direct.tracking_events.length)
    existing.tracking_events=direct.tracking_events;
   if(!existing.tracking_status_label)existing.tracking_status_label=direct.tracking_status_label;
   if(!existing.tracking_status_code)existing.tracking_status_code=direct.tracking_status_code;
  }else parcels.push(direct);
 }
 if(!parcels.length)return '';
 parcels.sort((a,b)=>String(b.created_at||'').localeCompare(String(a.created_at||'')));
 return buyerShippingCard(q,parcels);
}
function buyerMarkup(q){
 if(!q||!Array.isArray(q.partial_parcels)||!q.partial_parcels.length)return '';
 const total=(q.items||[]).filter(i=>i.fulfillment!=='sold_out').reduce((n,i)=>n+Math.max(0,Number(i.quantity)||0),0);
 const sent=(q.items||[]).reduce((n,i)=>n+Math.min(Math.max(0,Number(i.quantity)||0),sentQty(i.id,q.partial_parcels)),0);
 return '<div class="partial-buyer-box">'+parcelHistory(q,q.partial_parcels,true)+
  (sent<total?'<p class="buyer-shipment-awaiting">미발송 '+(total-sent)+'개 · 입고 후 배송 예정</p>':'')+'</div>';
}
function buyerItemStatus(q,item){
 const n=sentQty(item.id,q?.partial_parcels);
 if(!n)return '';
 const total=Math.max(0,Number(item.quantity)||0);
 return '<div class="tiny partial-item-tag">📦 '+n+'개 먼저 발송'+(n<total?' · '+(total-n)+'개 남음':'')+'</div>';
}
function adminBlock(q,history,ready,stage){
 if(!q||q.status!=='confirmed'||q.delivery_method!=='courier')return '';
 const hist=forOrder(q,history),sent=hist.length>0;
 const eligible=(q.items||[]).filter(i=>i.fulfillment!=='sold_out'&&i.fulfillment!=='delivered')
  .reduce((n,i)=>n+Math.max(0,arrivedQty(i)-sentQty(i.id,history)),0);
 const open=['new','preparing'].includes(stage);
 return '<div class="partial-admin-entry">'+
  (open?'<button type="button" class="btn block partial-open" data-action="open-partial-shipping" data-id="'+escapeHtml(q.id)+'">'+
  '📦 입고된 상품 먼저 발송'+(eligible?' · '+eligible+'개 가능':'')+'</button>'+
  '<p class="smallnote">지금 입고된 상품만 1차 송장에 등록하고, 나머지는 입고대기로 남겨요. 판매가·기존 배송비는 변경하지 않아요.</p>':'')+
  (sent?parcelHistory(q,history):'')+'</div>';
}
function bundleBlock(group,history){
 if(!Array.isArray(group)||group.length<2)return '';
 if(group.some(q=>q.status!=='confirmed'))return '';
 const eligible=group.some(q=>q.delivery_method==='courier'&&['new','preparing'].includes(q.workflow_stage||'new')&&
  (q.items||[]).some(i=>arrivedQty(i)>sentQty(i.id,history)));
 const entries=group.map(q=>parcelHistory(q,history)).filter(Boolean).join('');
 return '<div class="partial-bundle-entry">'+(eligible?'<button type="button" class="btn block secondary" data-action="open-partial-shipping" data-id="'+escapeHtml(group[0].id)+'">📦 입고된 상품 먼저 부분발송</button>':'')+
  entries+'</div>';
}
function style(){
 if(document.getElementById('partial-shipping-css'))return;
 const el=document.createElement('style');el.id='partial-shipping-css';
 el.textContent='.partial-admin-entry,.partial-bundle-entry{margin:10px 0;padding:12px 0;border-top:1px solid #eee}.partial-open{width:100%;padding:12px 8px;background:#1d1d1d;color:#fff}.partial-history{margin:10px 0;padding:12px;background:#f8f8f8;border-radius:10px}.partial-history>b{display:block;font-size:13px;margin-bottom:9px}.partial-history-package{padding:11px 0;border-top:1px solid #e8e8e8}.partial-history-package:first-of-type{border-top:0}.partial-history-package>div{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap}.partial-history-package strong{font-size:12px}.partial-history-package span{font-size:11px;color:#888}.partial-history-package small{display:block;font-size:11px;color:#555;margin-top:5px;line-height:1.6}.partial-history-package a{display:block;font-size:12px;color:#254c8d;margin-top:6px;text-decoration:underline}.partial-buyer-box{margin:14px 0}.partial-buyer-box>p{font-size:12px;color:#666;line-height:1.6;margin:8px}.partial-item-tag{font-weight:700;color:#377050!important}.ps-mask{position:fixed;inset:0;z-index:100700;background:#0009;display:flex;align-items:flex-end;justify-content:center}.ps-dialog{width:min(100%,700px);max-height:92dvh;background:#fff;border-radius:18px 18px 0 0;box-sizing:border-box;padding:17px 18px max(18px,env(safe-area-inset-bottom));color:#222;display:flex;flex-direction:column;gap:10px}.ps-head{display:flex;align-items:center;justify-content:space-between}.ps-head h2{font-size:19px;margin:0}.ps-close{width:38px;height:38px;background:#f5f5f5;border:none;border-radius:8px;font-size:22px}.ps-lead,.ps-footer{font-size:12px;color:#666;line-height:1.6;margin:0}.ps-list{overflow-y:auto;min-height:0;max-height:46dvh;border-top:1px solid #eee;border-bottom:1px solid #eee}.ps-item{display:flex;align-items:center;gap:10px;padding:12px 2px;border-bottom:1px solid #eee}.ps-item input[type=checkbox]{width:19px;height:19px;flex-shrink:0}.ps-item span{flex:1;min-width:0}.ps-item strong{display:block;font-size:13px;line-height:1.5}.ps-item small{display:block;font-size:11px;color:#777;margin-top:3px}.ps-item input[type=number]{width:55px;padding:8px 4px;border:1px solid #ddd;border-radius:7px;text-align:center;font-size:14px}.ps-fields{display:flex;gap:8px}.ps-fields label{flex:1;min-width:0;font-size:12px;font-weight:750}.ps-fields input{box-sizing:border-box;width:100%;font-size:14px;border-radius:7px;border:1px solid #ddd;padding:11px 9px;margin-top:5px}.ps-bulk{padding:13px;border:1px solid #bbb;border-radius:9px;background:#f8f8f8;color:#222;font-size:13px;font-weight:800;cursor:pointer}.ps-submit{padding:15px;background:#171717;color:white;border:none;border-radius:9px;font-size:14px;font-weight:850}.ps-submit:disabled{opacity:.5}.ps-awaiting{font-size:11px;color:#8b633f;padding:8px 0}.ps-history{max-height:21dvh;overflow-y:auto}.ps-summary{font-size:12px;font-weight:800;color:#222}.ps-loading{padding:18px;text-align:center;color:#666}.ps-alert{font-size:12px;color:#a34242}@media(min-width:740px){.ps-mask{align-items:center}.ps-dialog{border-radius:18px}}';
 el.textContent+=
 '.buyer-shipment-card{border:1px solid #e6e6e6;border-radius:14px;padding:16px;background:#fff;margin:10px 0}'+
 '.buyer-shipment-heading{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:12px}'+
 '.buyer-shipment-heading strong{font-size:17px}.buyer-shipment-heading small{font-size:12px;color:#888}'+
 '.buyer-shipment-entry{padding:12px 0;border-top:1px solid #ededed}'+
 '.buyer-shipment-summary{display:flex;justify-content:space-between;align-items:center;gap:10px}'+
 '.buyer-shipment-summary b{display:block;font-size:14px}.buyer-shipment-summary small{display:block;font-size:12px;color:#777;letter-spacing:.1px;margin-top:2px}'+
 '.buyer-shipment-status{font-size:12px;font-weight:800;white-space:nowrap}'+
 '.buyer-shipment-link{display:inline-flex;margin-top:11px;padding:11px 16px;background:#242426;color:#fff!important;border-radius:8px;text-decoration:none!important;font-size:13px;font-weight:800;gap:8px;align-items:center}'+
 '.buyer-shipment-unavailable{display:block;color:#888;margin-top:8px;font-size:12px}'+
 '.buyer-shipment-lines{margin-top:13px;padding-top:10px;border-top:1px solid #f0f0f0}'+
 '.buyer-shipment-lines summary{font-size:12px;color:#777;cursor:pointer}'+
 '.buyer-shipment-lines ul{padding-left:18px;margin:8px 0 0;color:#555;font-size:12px;line-height:1.7;overflow-wrap:anywhere}'+
 '.partial-buyer-box{margin:14px 0}.buyer-shipment-awaiting{font-size:12px;color:#666;margin:5px 0 0;line-height:1.6}';

 el.textContent+=
 '.my-shipping-card{margin:14px 0 4px!important;padding:16px!important;border:1px solid #e7e7e7!important;border-radius:14px!important;box-sizing:border-box;background:#fff}'+
 '.my-shipping-card *{box-sizing:border-box}.my-shipping-heading{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:10px}'+
 '.my-shipping-heading h3{font-size:16px;font-weight:850;margin:0}.my-shipping-heading small{font-size:12px;color:#888}'+
 '.my-shipping-parcel{padding:13px 0;border-top:1px solid #ededed}.my-shipping-heading + .my-shipping-parcel{border-top:0;padding-top:2px}.my-shipping-parcel:last-child{padding-bottom:0}'+
 '.my-shipping-top{display:flex;justify-content:space-between;align-items:center;gap:10px;margin:0 0 9px}.my-shipping-top strong{font-size:13px;color:#247552}.my-shipping-top span,.my-shipping-top time{font-size:11px;color:#999}'+
 '.my-shipping-invoice{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:9px;min-width:0}'+
 '.my-shipping-number{display:flex;align-items:baseline;flex-wrap:wrap;gap:6px 9px;min-width:0;overflow-wrap:anywhere}.my-shipping-number b{font-size:13px;font-weight:800}.my-shipping-number span{font-size:13px;color:#484848;font-variant-numeric:tabular-nums;letter-spacing:.2px}'+
 '.my-shipping-card .my-shipping-link{display:inline-flex!important;margin:0!important;padding:6px 9px!important;border:1px solid #ddd!important;border-radius:7px!important;background:#fff!important;color:#252525!important;font-size:12px!important;line-height:1.3!important;font-weight:750!important;text-decoration:none!important;white-space:nowrap}'+
 '.my-shipping-current{margin:9px 0 0;font-size:12px;color:#555;line-height:1.5}.my-shipping-current span{font-size:11px;color:#888;white-space:nowrap}'+
 '.my-shipping-events{margin-top:12px;padding:12px 12px 4px;border-radius:10px;background:#f8f8f8}'+
 '.my-shipping-subtitle{font-size:12px;font-weight:800;display:flex;align-items:center;gap:6px;margin-bottom:8px}.my-shipping-subtitle small{font-size:11px;font-weight:500;color:#888}'+
 '.my-shipping-list{list-style:none!important;padding:0!important;margin:0!important}.my-shipping-event{position:relative;display:flex;align-items:flex-start;gap:9px;padding:7px 0!important;margin:0!important;border:0!important;min-width:0}'+
 '.my-shipping-dot{width:7px;height:7px;border-radius:50%;background:#b4b4b4;flex:0 0 7px;margin-top:6px}.my-shipping-event:first-child .my-shipping-dot{background:#247552}'+
 '.my-shipping-event-body{flex:1;min-width:0;overflow-wrap:anywhere}.my-shipping-event-body strong{display:block;font-size:12px;font-weight:800;color:#333;line-height:1.45}.my-shipping-event-body small{display:block;font-size:11px;color:#888;line-height:1.45;margin-top:2px}'+
 '.my-shipping-event time{font-size:10px;color:#888;white-space:nowrap;line-height:1.8;font-variant-numeric:tabular-nums}'+
 '.my-shipping-extra{border-top:1px solid #eaeaea;padding:8px 0 3px;margin-top:4px}.my-shipping-extra>summary,.my-shipping-items>summary{cursor:pointer;font-size:11px;color:#666;font-weight:650}'+
 '.my-shipping-extra .my-shipping-list{margin-top:7px!important}.my-shipping-items{margin-top:10px;border-top:1px solid #ededed;padding-top:10px}.my-shipping-items ul{padding-left:16px;margin:8px 0 0;font-size:11px;color:#777;line-height:1.7;overflow-wrap:anywhere}'+
 '.my-shipping-noevents{margin:10px 0 0;font-size:11px;color:#888;line-height:1.45}.partial-buyer-box{margin:10px 0!important}.partial-buyer-box>.buyer-shipment-awaiting{margin:6px 2px 0!important;font-size:12px;color:#666}';
 document.head.append(el);
}
function close(){overlay?.remove();overlay=null;active=null;}
async function open(ctx){
 if(!ctx||!ctx.isAdmin||!ctx.rpc||!ctx.quote)throw Error('관리자 전용 부분배송 기능이에요.');
 close();style();
 overlay=document.createElement('div');overlay.className='ps-mask';
 overlay.innerHTML='<section class="ps-dialog" role="dialog" aria-modal="true" aria-label="입고된 상품 먼저 발송"><div class="ps-head"><h2>📦 입고된 상품 먼저 발송</h2><button class="ps-close" aria-label="닫기">×</button></div><div class="ps-content ps-loading">발송 가능한 입고 상품 확인 중…</div></section>';
 document.body.append(overlay);
 overlay.addEventListener('click',e=>{if(e.target===overlay||e.target.closest('.ps-close'))close();});
 const rootId=ctx.bundleRootId(ctx.quote);
 const group=ctx.quotes.filter(q=>q.status==='confirmed'&&q.delivery_method==='courier'&&ctx.bundleRootId(q)===rootId);
 if(!group.length){close();throw Error('주문 목록이 바뀌었어요. 새로고침해 주세요.');}
 try{
  const history=await ctx.rpc('gq_admin_list_partial_parcels_v118',{},true);
  if(!overlay)return;
  const already=Array.isArray(history)?history:[];
  const possible=group.flatMap(q=>(q.items||[]).filter(i=>i.fulfillment==='received'||(i.fulfillment==='ordered'&&Number(i.received_qty||0)>0))
   .map(i=>({q,i,limit:Math.max(0,arrivedQty(i)-sentQty(i.id,already))})).filter(x=>x.limit>0 && ['new','preparing'].includes(q.workflow_stage||'new')));
  const waiting=group.flatMap(q=>(q.items||[]).filter(i=>i.fulfillment!=='sold_out'&&i.fulfillment!=='delivered'&&
   Math.max(0,Number(i.quantity)||0)>sentQty(i.id,already)+Math.max(0,arrivedQty(i)-sentQty(i.id,already))));
  const prev=group.map(q=>parcelHistory(q,already)).filter(Boolean).join('');
  const body=overlay.querySelector('.ps-content');body.className='ps-content';
  body.innerHTML='<p class="ps-lead"><b>'+escapeHtml(ctx.quote.buyer_name||ctx.quote.recipient_name)+'</b> · '+group.length+'건 묶음 / 지금 입고된 상품 중 원하는 것만 선택하세요. <b>미입고 상품은 포함되지 않아요.</b></p>'+
   '<div class="ps-list">'+(possible.length?possible.map(({q,i,limit})=>
    '<label class="ps-item"><input type="checkbox" data-item="'+escapeHtml(i.id)+'"><span><strong>'+escapeHtml(i.store_name)+' · '+escapeHtml(i.product_name)+'</strong><small>'+escapeHtml(i.color)+' / '+escapeHtml(i.size)+' · 발송 가능 '+limit+'개'+(group.length>1?' · '+escapeHtml(q.buyer_name):'')+'</small></span>'+
    '<input type="number" aria-label="'+escapeHtml(i.product_name)+' 발송 수량" data-qty="'+escapeHtml(i.id)+'" value="'+limit+'" min="1" max="'+limit+'" inputmode="numeric"></label>'
    ).join(''):'<p class="ps-loading">지금 부분발송할 수 있는 입고완료 상품이 없어요.</p>')+'</div>'+
   (waiting.length?'<p class="ps-awaiting">아직 입고되지 않은 상품 '+waiting.length+'종은 기존 주문에 남겨둘게요.</p>':'')+
   (possible.length?(ctx.openBulk?'<button type="button" class="ps-bulk">📄 택배 송장 엑셀 만들기</button>':'')+'<div class="ps-fields"><label>택배사<input class="ps-carrier" maxlength="60" value="롯데택배" required></label><label>송장번호<input class="ps-tracking" inputmode="numeric" maxlength="80" placeholder="운송장번호" required></label></div>'+
   '<div class="ps-summary">선택한 상품 <span class="ps-count"></span></div>'+
   '<button class="ps-submit" type="button">선택한 상품만 배송 중 등록</button>'+
   '<p class="ps-footer">선택한 상품만 송장에 연결돼요. 나머지 상품·입금액·기존 택배비는 변경하지 않으며 추가 택배비도 자동 청구하지 않아요.</p>':'')+
   (prev?'<details class="ps-history"><summary>이전 부분발송 기록</summary>'+prev+'</details>':'');
  const update=()=>{
   const chosen=[...body.querySelectorAll('input[data-item]:checked')].map(cb=>({id:cb.dataset.item,qty:body.querySelector('input[data-qty="'+cb.dataset.item+'"]')}));
   const valid=chosen.length>0&&chosen.every(x=>Number.isInteger(Number(x.qty?.value))&&Number(x.qty.value)>=1&&Number(x.qty.value)<=Number(x.qty.max));
   const qty=chosen.reduce((n,x)=>n+Number(x.qty?.value||0),0);
   const count=body.querySelector('.ps-count');if(count)count.textContent=chosen.length+'종 · '+qty+'개';
   const button=body.querySelector('.ps-submit');if(button)button.disabled=!valid;
  };
  body.addEventListener('input',update);body.addEventListener('change',update);update();
  const bulk=body.querySelector('.ps-bulk');if(bulk)bulk.addEventListener('click',()=>{close();ctx.openBulk();});
  const send=body.querySelector('.ps-submit');
  if(send)send.addEventListener('click',async()=>{
   if(send.disabled||!overlay||!body.isConnected)return;
   const lines=[...body.querySelectorAll('input[data-item]:checked')].map(box=>{
    const x=body.querySelector('input[data-qty="'+box.dataset.item+'"]');
    return {item_id:box.dataset.item,quantity:Number(x?.value)};
   });
   if(!lines.length||lines.some(x=>!Number.isInteger(x.quantity)||x.quantity<1||x.quantity>20)){
    alert('발송 수량을 확인해 주세요.');return;
   }
   const carrier=body.querySelector('.ps-carrier')?.value.trim()||'';
   const tracking=body.querySelector('.ps-tracking')?.value.trim()||'';
   if(!carrier||!/^[A-Za-z0-9 -]{4,80}$/.test(tracking)){alert('택배사와 송장번호를 확인해 주세요.');return;}
   const qty=lines.reduce((n,x)=>n+x.quantity,0);
   if(!confirm('송장 '+tracking+'\n입고완료 '+lines.length+'종 · '+qty+'개만 먼저 발송 처리할까요?\n\n남은 상품은 입고대기로 유지하며, 추가 택배비는 자동 청구하지 않습니다.'))return;
   send.disabled=true;send.textContent='송장 등록 중…';
   try{
    await ctx.rpc('gq_admin_create_partial_parcel_v118',{p_root_quote_id:rootId,p_carrier:carrier,p_tracking_number:tracking,p_lines:lines},true);
    close();await ctx.reload();ctx.notify('선택한 상품 '+qty+'개만 부분 발송 처리했어요. 나머지는 입고 대기예요.');
   }catch(err){send.disabled=false;send.textContent='선택한 상품만 배송 중 등록';alert(err?.message||'부분배송 등록에 실패했어요.');}
  });
 }catch(err){if(overlay){overlay.querySelector('.ps-content').innerHTML='<p class="ps-alert">부분배송 정보를 확인하지 못했어요. 새로고침 후 다시 시도해 주세요.</p>';throw err;}}
}
window.MiniPartialShipping={open,adminBlock,bundleBlock,buyerMarkup,singleBuyerMarkup,adminTrackingMarkup,buyerItemStatus,sentQty,parcelHistory};
})();