const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const html=fs.readFileSync('index.html','utf8');
function setup(quotes=[],admin=true,page=admin?'admin':'track'){
 const ctx=vm.createContext({});
 vm.runInContext(`const state=${JSON.stringify({quotes,admin,page})};
 const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 ${html.slice(html.indexOf('const trackingInfo='),html.indexOf('\nconst notif='))}
 ${html.slice(html.indexOf('function bundleRootId('),html.indexOf('function bundleWorkControls('))}
 ${html.slice(html.indexOf('function applyShippingDetails('),html.indexOf('async function loadAdminShipping('))}
 globalThis.api={renderShipment,sharedShipment,bundledQuoteGroups,v25TrackingSnapshot,indexV25AdminTracking,applyShippingDetails};`,ctx);
 return ctx.api;
}
const root={id:'root',delivery_method:'courier',status:'confirmed',workflow_stage:'completed',tracking_carrier:'롯데택배',tracking_number:'1234-5678',created_at:'2026-10-01'};
const child={...root,id:'child',bundle_parent_id:'root',workflow_stage:'shipped'};
test('official Lotte link and no invented history',()=>{
 const view=setup().renderShipment(root);
 assert.match(view,/https:\/\/www.lotteglogis.com\/home\/reservation\/tracking\/linkView\?InvNo=12345678/);
 assert.match(view,/rel="noopener noreferrer"/);
 assert.match(view,/제공된 배송이력이 없어요/);
 assert.doesNotMatch(view,/<tbody>/);
});
test('mixed stages and filtered children remain one complete bundle',()=>{
 const groups=setup([root,child]).bundledQuoteGroups([child]);
 assert.equal(groups.length,1);assert.equal(groups[0].length,2);assert.equal(groups[0][0].id,'root');
});
test('shared invoice without altering order or payment fields',()=>{
 const noInvoice={...child,tracking_number:null,tracking_carrier:null,amount_paid:20000};
 const api=setup([root,noInvoice]);
 assert.equal(api.sharedShipment(noInvoice).id,'root');
 assert.match(api.renderShipment(noInvoice),/InvNo=12345678/);
 assert.equal(noInvoice.amount_paid,20000);assert.equal(noInvoice.tracking_number,null);
});
test('conflicting invoices never inherit another shipment',()=>{
 const other={...child,tracking_number:'99999999'};
 assert.equal(setup([root,other]).sharedShipment(other).id,'child');
});
test('customer view never consults admin order cache',()=>{
 assert.equal(setup([root,child],false).sharedShipment(child).id,'child');
});
test('real snapshot contract escapes history and rejects wrong invoice',()=>{
 const q={...root,shipment_tracking:{source:'delivery-tracker',carrier_id:'kr.lotte',tracking_number:root.tracking_number,status:'이동 중',events:[{time:'2026-10-21T09:30:00+09:00',location:'<img onerror=alert(1)>',status:'간선상차'}]}};
 const view=setup().renderShipment(q);
 assert.match(view,/간선상차/);assert.match(view,/&lt;img/);assert.doesNotMatch(view,/<img/);
 q.shipment_tracking.tracking_number='different';
 assert.doesNotMatch(setup().renderShipment(q),/간선상차/);
});
test('other carriers and invalid invoice cannot generate Lotte links',()=>{
 assert.doesNotMatch(setup().renderShipment({...root,tracking_carrier:'다른 택배'}),/href=/);
 assert.doesNotMatch(setup().renderShipment({...root,tracking_number:'"><script>'}),/href=/);
});

test('Delivery Tracker nested events and formatted invoice numbers',()=>{
 const q={...root,shipment_tracking:{source:'delivery-tracker',carrier_id:'kr.lotte',tracking_number:'12345678',events:[{time:'2026-10-21T10:00:00+09:00',location:{name:'실제 응답 위치'},status:{name:'실제 응답 상태'}}]}};
 const view=setup().renderShipment(q);
 assert.match(view,/실제 응답 위치/);assert.match(view,/실제 응답 상태/);
});
test('foreign carrier snapshot cannot be labeled Lotte history',()=>{
 const q={...root,tracking_carrier:'다른 택배',shipment_tracking:{source:'delivery-tracker',carrier_id:'kr.lotte',tracking_number:'12345678',events:[{status:'잘못된 이력'}]}};
 assert.doesNotMatch(setup().renderShipment(q),/잘못된 이력/);
});
test('v25 enrichment preserves invoice, order and payment fields',()=>{
 const api=setup();const q={...root,amount_paid:50000};
 const snapshot=api.v25TrackingSnapshot({tracking_number:'12345678',status_label:'배송 중',events:[]},q.tracking_number);
 api.applyShippingDetails(q,snapshot);
 assert.equal(q.tracking_number,'1234-5678');assert.equal(q.workflow_stage,'completed');assert.equal(q.amount_paid,50000);
 assert.equal(q.shipment_tracking.tracking_number,'12345678');
 api.applyShippingDetails(q,api.v25TrackingSnapshot({tracking_number:'99999999',events:[]}));
 assert.equal(q.shipment_tracking.tracking_number,'12345678');
});
test('v25 raw time/place/status/detail and ten events map without fabrication',()=>{
 const api=setup();const row={tracking_number:'12345678',checked_at:'2026-10-21T00:00:00Z',events:Array.from({length:10},()=>({time:'2026-10-15T19:38:21+09:00',place:'집하점',status:'집하',detail:'실제 상세'}))};
 const snapshot=api.v25TrackingSnapshot(row,'1234-5678');
 assert.equal(snapshot.events.length,10);assert.equal(snapshot.events[0].location,'집하점');
 assert.equal(snapshot.events[0].status,'집하 · 실제 상세');assert.equal(snapshot.events[0].time,row.events[0].time);
 assert.equal(snapshot.fetched_at,row.checked_at);
 assert.equal(api.v25TrackingSnapshot(null),null);
 assert.equal(api.v25TrackingSnapshot({tracking_number:'12345678',events:'invalid'}),null);
 assert.equal(api.v25TrackingSnapshot({events:[]},'12345678'),null);
 assert.equal(api.v25TrackingSnapshot(row,'99999999'),null);
});
test('v25 admin invoice map normalizes identity and rejects ambiguity',()=>{
 const api=setup();const row={tracking_number:'12345678',events:[]};
 assert.equal(api.indexV25AdminTracking({'1234-5678':row}).size,1);
 assert.equal(api.indexV25AdminTracking({'1234-5678':{events:[]}}).size,1);
 assert.equal(api.indexV25AdminTracking({'1234-5678':{...row,tracking_number:'99999999'}}).size,0);
 assert.equal(api.indexV25AdminTracking({'1234-5678':row,'12345678':{...row,status_label:'different'}}).size,0);
 assert.equal(api.indexV25AdminTracking({'12345678':row,'1234-5678':{...row,tracking_number:'99999999'}}).size,0);
 assert.equal(api.indexV25AdminTracking([row]).size,0);
});
test('buyer page never inherits retained administrator cache',()=>{
 const noInvoice={...child,tracking_number:null,tracking_carrier:null};
 assert.equal(setup([root,noInvoice],true,'track').sharedShipment(noInvoice).id,'child');
});
test('mobile timeline displays short KST dates newest-first and escapes optional fields',()=>{
 const q={...root,shipment_tracking:{source:'delivery-tracker',carrier_id:'kr.lotte',
  tracking_number:'12345678',fetched_at:'2026-10-21T03:03:50.452056+00:00',
  events:[{time:'2026-10-15T19:38:21.000+09:00',location:'<img>',status:'집하',detail:'보내셨습니다'},
   {time:'2026-10-16T00:25:53.000+09:00',location:'중부권',status:'셔틀도착'},
   {time:'',location:'',status:'시간 미기재'}]}};
 const view=setup().renderShipment(q);
 assert.match(view,/class="shipment-timeline"/);
 assert.match(view,/10\.15 19:38/);
 assert.match(view,/10\.16 00:25/);
 assert.match(view,/10\.21 12:03 \(한국시간\)/);
 assert(view.indexOf('셔틀도착')<view.indexOf('집하'));
 assert(view.indexOf('집하')<view.indexOf('시간 미기재'));
 assert.match(view,/시간 미확인/);
 assert.match(view,/&lt;img&gt;/);
 assert.doesNotMatch(view,/<img>/);
 assert.doesNotMatch(view,/2026-10-15T19:38:21/);
 assert.doesNotMatch(view,/<table>/);
});

test('all inline JavaScript and service workers parse',()=>{
 for(const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)){
  if(!/\bsrc\s*=/.test(match[1]))new vm.Script(match[2]);
 }
 for(const filename of ['sw.js','OneSignalSDKWorker.js'])new vm.Script(fs.readFileSync(filename,'utf8'));
});
