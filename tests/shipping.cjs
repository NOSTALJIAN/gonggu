const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const html=fs.readFileSync('index.html','utf8');
function setup(quotes=[],admin=true){
 const ctx=vm.createContext({});
 vm.runInContext(`const state=${JSON.stringify({quotes,admin})};
 const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 ${html.slice(html.indexOf('const trackingInfo='),html.indexOf('\nconst notif='))}
 ${html.slice(html.indexOf('function bundleRootId('),html.indexOf('function bundleWorkControls('))}
 globalThis.api={renderShipment,sharedShipment,bundledQuoteGroups};`,ctx);
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
test('optional enrichment can only change shipment fields',()=>{
 const ctx=vm.createContext({});
 vm.runInContext(html.slice(html.indexOf('function applyShippingDetails('),html.indexOf('async function loadAdminShipping('))+';globalThis.apply=applyShippingDetails;',ctx);
 const q={...root,amount_paid:50000};
 ctx.apply(q,{tracking_carrier:'롯데택배',tracking_number:'99999999',workflow_stage:'new',amount_paid:0,status:'cancelled'});
 assert.equal(q.tracking_number,'99999999');assert.equal(q.workflow_stage,'completed');assert.equal(q.amount_paid,50000);assert.equal(q.status,'confirmed');
});
test('all inline JavaScript and service workers parse',()=>{
 for(const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)){
  if(!/\bsrc\s*=/.test(match[1]))new vm.Script(match[2]);
 }
 for(const filename of ['sw.js','OneSignalSDKWorker.js'])new vm.Script(fs.readFileSync(filename,'utf8'));
});
