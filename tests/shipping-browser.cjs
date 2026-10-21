// Browser tests intercept every external request. Fixtures are not live shipment data.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const base=process.env.GONGGU_TEST_BASE_URL||'http://127.0.0.1:8000';
const buyerRPC='gq_lotte_tracking_for_quote_v25';
const adminRPC='gq_lotte_tracking_admin_v25';
const rootId='00000000-0000-0000-0000-000000000001';
const childId='00000000-0000-0000-0000-000000000002';
const fixtureToken='10000000-0000-0000-0000-000000000002';
const item={id:'test-item',product_name:'테스트 상품',store_name:'테스트 가게',quantity:1,unit_price:10000,fulfillment:'received',color:'크림',size:'S'};
const root={id:rootId,buyer_name:'테스트 구매자',baby_name:'테스트',status:'confirmed',delivery_method:'courier',workflow_stage:'completed',tracking_carrier:'롯데택배',tracking_number:'12345678',shipping_fee:3000,created_at:'2026-10-21T00:00:00Z',items:[item]};
const child={...root,id:childId,bundle_parent_id:rootId,workflow_stage:'shipped',tracking_carrier:'롯데택배',tracking_number:'1234-5678',shipping_fee:0,amount_paid:7000,amount_refunded:0,items:[{...item,id:'child-item'}]};
const childWithoutInvoice={...child,tracking_carrier:null,tracking_number:null};
// Table-column-shaped mock record. Successful production inner keys are not asserted verified.
const row={tracking_number:'12345678',checked_at:'2026-10-21T12:00:00+09:00',status_code:'IN_TRANSIT',status_label:'테스트 조회 상태',event_time:'2026-10-15T19:38:21+09:00',events:Array.from({length:10},(_,i)=>({time:'2026-10-15T19:38:21+09:00',place:'테스트 API 위치 '+(i+1),status:'집하',detail:'테스트 상세 '+(i+1)}))};
const trackURL=()=>base+'/?page=track&id='+childId+'&token='+fixtureToken;
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.GONGGU_CHROMIUM_PATH||'/usr/bin/chromium',args:['--no-sandbox']});
 try{
  const context=await browser.newContext({serviceWorkers:'block'});
  const page=await context.newPage();
  const errors=[],calls=[],unexpected=[];
  let buyerQuote={...child,workflow_stage:'preparing'};
  let buyerPayload=row;
  let adminChild=child;
  let adminPayload={'1234-5678':row};
  let unavailableStatus=null;
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://**/*',async route=>{
   const req=route.request(),url=new URL(req.url()),name=url.pathname.split('/').pop();
   if(url.hostname==='cdn.onesignal.com')return route.fulfill({body:'',contentType:'text/javascript'});
   if(req.method()==='POST')calls.push({name,body:req.postDataJSON(),authorization:!!req.headers().authorization});
   if(name==='gq_read_quote')return route.fulfill({json:buyerQuote});
   if(name==='gq_is_admin')return route.fulfill({json:true});
   if(name===buyerRPC||name===adminRPC){
    if(unavailableStatus)return route.fulfill({status:unavailableStatus,json:{code:unavailableStatus===404?'PGRST202':'42501',message:'Fixture lookup unavailable'}});
    return route.fulfill({json:name===buyerRPC?buyerPayload:adminPayload});
   }
   if(name==='gq_quotes'&&req.method()==='GET')return route.fulfill({json:[root,adminChild]});
   if(name==='gq_quote_items'&&req.method()==='GET')return route.fulfill({json:[{...item,quote_id:rootId},{...item,id:'child-item',quote_id:childId}]});
   if(url.pathname.startsWith('/rest/v1/')&&req.method()==='GET')return route.fulfill({json:[]});
   unexpected.push(req.method()+' '+url.pathname);
   return route.abort();
  });
  const gotoBuyer=async()=>{
   await page.goto(trackURL(),{waitUntil:'networkidle'});
   await page.locator('[data-action="edit-delivery"]').waitFor();
  };
  const gotoAdmin=async()=>{
   await page.goto(base+'/?page=admin',{waitUntil:'networkidle'});
   await page.locator('.bundle-summary-card').waitFor();
  };

  // Own normalized invoice matches a hyphenated order; preserve raw event time/detail.
  await gotoBuyer();
  await page.locator('.shipment-history summary').waitFor();
  assert.match(await page.locator('.shipment-progress a').getAttribute('href'),/InvNo=12345678$/);
  await page.locator('.shipment-history summary').click();
  assert.equal(await page.locator('.shipment-history tbody tr').count(),10);
  assert.match(await page.locator('.shipment-history summary').innerText(),/10건/);
  const history=await page.locator('.shipment-history').innerText();
  assert.match(history,/테스트 API 위치 1/);assert.match(history,/집하/);
  assert.match(history,/테스트 상세 1/);assert.match(history,/2026-10-15T19:38:21\+09:00/);
  assert.match(await page.locator('body').innerText(),/입금 확인: 7,000원/);
  assert(calls.filter(x=>x.name===buyerRPC).every(x=>x.body.p_quote_id===childId&&x.body.p_lookup_token===fixtureToken&&!x.authorization));
  assert.equal(calls.filter(x=>x.name===adminRPC).length,0);

  // Admin response is a map keyed by invoice; no arguments are sent to the existing RPC.
  await page.evaluate(()=>localStorage.setItem('gonggu-quote-v3-session',JSON.stringify({access_token:'fixture-only',expires_at:9999999999})));
  await gotoAdmin();
  await page.locator('.bundle-flow .shipment-history summary').waitFor();
  assert.equal(await page.locator('.bundle-summary-card').count(),1);
  assert.equal(await page.locator('.ordercard').count(),0);
  assert.equal(await page.locator('.bundle-flow .shipment-history tbody tr').count(),10);
  assert.doesNotMatch(await page.locator('.bundle-flow').innerText(),/서로 다른 송장번호/);
  await page.locator('[data-filter="flow_shipped"]').click();
  assert.equal(await page.locator('.bundle-summary-card').count(),1);
  assert.equal(await page.locator('.bundle-item').count(),2);
  assert.match(await page.locator('.bundle-flow a').getAttribute('href'),/InvNo=12345678$/);
  assert(calls.filter(x=>x.name===adminRPC).every(x=>x.authorization&&JSON.stringify(x.body)==='{}'));

  // Authorized admin may share the parent's invoice without mutating a child order.
  adminChild=childWithoutInvoice;
  const rowWithoutInvoice={...row};delete rowWithoutInvoice.tracking_number;
  adminPayload={'1234-5678':rowWithoutInvoice};
  await gotoAdmin();
  await page.locator('.bundle-flow .shipment-history summary').waitFor();
  assert.equal(await page.locator('.bundle-flow .shipment-history tbody tr').count(),10);

  // Logout then client-side buyer navigation retains JS order cache: it still must not leak.
  await page.locator('[data-tab="settings"]').click();
  await page.locator('[data-action="logout"]').click();
  await page.locator('form#login').waitFor();
  buyerQuote=childWithoutInvoice;buyerPayload=row;
  const adminCallsBefore=calls.filter(x=>x.name===adminRPC).length;
  await page.evaluate(({id,token})=>{
   history.pushState({},'',location.pathname+'?page=track&id='+id+'&token='+token);
   dispatchEvent(new PopStateEvent('popstate'));
  },{id:childId,token:fixtureToken});
  await page.waitForLoadState('networkidle');
  await page.locator('[data-action="edit-delivery"]').waitFor();
  assert.equal(await page.locator('.shipment-history').count(),0);
  assert.equal(await page.locator('.shipment-progress a').count(),0);
  assert.equal(calls.filter(x=>x.name===adminRPC).length,adminCallsBefore);

  // Neither a foreign invoice nor an unexpected buyer response envelope may be guessed.
  buyerQuote=child;buyerPayload={...row,tracking_number:'99999999'};
  await gotoBuyer();
  assert.equal(await page.locator('.shipment-history').count(),0);
  assert.match(await page.locator('.shipment-progress a').getAttribute('href'),/InvNo=12345678$/);
  buyerPayload={data:row};
  await gotoBuyer();
  assert.equal(await page.locator('.shipment-history').count(),0);

  // Missing own invoice + null response is a safe limitation, never parent-token fallback.
  buyerQuote=childWithoutInvoice;buyerPayload=null;
  await gotoBuyer();
  assert.equal(await page.locator('.shipment-history').count(),0);
  assert.equal(await page.locator('.shipment-progress a').count(),0);
  assert.equal(calls.filter(x=>x.name===adminRPC).length,adminCallsBefore);

  // Missing/denied optional RPC keeps the quote and official link usable; no v26 fallback.
  buyerQuote=child;buyerPayload=row;
  for(const status of [404,403]){
   unavailableStatus=status;
   await gotoBuyer();
   assert.equal(await page.locator('.shipment-history').count(),0);
   assert.match(await page.locator('body').innerText(),/테스트 구매자/);
   assert.match(await page.locator('.shipment-progress a').getAttribute('href'),/InvNo=12345678$/);
  }
  unavailableStatus=null;

  // Same normalized map key with conflicting history must not select an arbitrary snapshot.
  await page.evaluate(()=>localStorage.setItem('gonggu-quote-v3-session',JSON.stringify({access_token:'fixture-only',expires_at:9999999999})));
  adminPayload={'12345678':row,'1234-5678':{...row,status_label:'서로 다른 조회 결과'}};
  await gotoAdmin();
  assert.equal(await page.locator('.shipment-history').count(),0);

  assert.deepEqual(errors,[]);
  assert.deepEqual(unexpected,[]);
  const allowed=['gq_read_quote','gq_is_admin',buyerRPC,adminRPC];
  assert(calls.every(x=>allowed.includes(x.name)));
  assert(calls.filter(x=>x.name===buyerRPC).every(x=>x.body.p_quote_id===childId&&x.body.p_lookup_token===fixtureToken));
  console.log('PASS: v25 buyer/admin records,10 mapped events,hyphen normalization,shared admin bundle,cache isolation,foreign-invoice rejection,empty/error fallback; no write/v26 RPCs');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
