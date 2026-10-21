// Browser integration tests with intercepted API fixtures only; no live orders or API writes.
const { chromium }=require('playwright');
const assert=require('node:assert/strict');
const base=process.env.GONGGU_TEST_BASE_URL||'http://127.0.0.1:8000';
const rootId='00000000-0000-0000-0000-000000000001';
const childId='00000000-0000-0000-0000-000000000002';
const item={id:'test-item',product_name:'테스트 상품',store_name:'테스트 가게',quantity:1,unit_price:10000,fulfillment:'received',color:'크림',size:'S'};
const root={id:rootId,buyer_name:'테스트 구매자',baby_name:'테스트',status:'confirmed',delivery_method:'courier',workflow_stage:'completed',tracking_carrier:'롯데택배',tracking_number:'12345678',shipping_fee:3000,created_at:'2026-10-21T00:00:00Z',items:[item]};
const child={...root,id:childId,bundle_parent_id:rootId,workflow_stage:'shipped',tracking_carrier:null,tracking_number:null,shipping_fee:0,items:[{...item,id:'child-item'}]};
const details={tracking_carrier:'롯데택배',tracking_number:'12345678',shipment_tracking:{source:'delivery-tracker',carrier_id:'kr.lotte',tracking_number:'12345678',status:'테스트 조회 상태',events:[{time:'2026-10-21T12:00:00+09:00',location:{name:'테스트 API 위치'},status:{name:'테스트 API 이력'}}]}};
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.GONGGU_CHROMIUM_PATH||'/usr/bin/chromium',args:['--no-sandbox']});
 try{
  const context=await browser.newContext();
  const page=await context.newPage();const errors=[],calls=[];let missing=false;
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://**/*',async route=>{
   const req=route.request(),url=new URL(req.url());
   if(url.hostname==='cdn.onesignal.com')return route.fulfill({body:'',contentType:'text/javascript'});
   const name=url.pathname.split('/').pop();
   if(req.method()==='POST')calls.push(name);
   if(name==='gq_read_quote')return route.fulfill({json:{...child,workflow_stage:'preparing'}});
   if(name==='gq_is_admin')return route.fulfill({json:true});
   if(name==='gq_read_shipping_v26'||name==='gq_read_admin_shipping_v26'){
    if(missing)return route.fulfill({status:404,json:{code:'PGRST202',message:'Not installed'}});
    return route.fulfill({json:name==='gq_read_shipping_v26'?details:{[rootId]:details,[childId]:details}});
   }
   if(name==='gq_quotes')return route.fulfill({json:[root,child]});
   if(name==='gq_quote_items')return route.fulfill({json:[{...item,quote_id:rootId},{...item,id:'child-item',quote_id:childId}]});
   if(url.pathname.startsWith('/rest/v1/')&&req.method()==='GET')return route.fulfill({json:[]});
   throw Error('Unexpected external operation: '+req.method()+' '+url.pathname);
  });
  await page.goto(base+'/?page=track&id='+childId+'&token=test-token');
  await page.locator('.shipment-progress a').waitFor();
  assert.match(await page.locator('.shipment-progress a').getAttribute('href'),/InvNo=12345678$/);
  await page.locator('.shipment-history summary').click();
  assert.match(await page.locator('.shipment-history').innerText(),/테스트 API 위치/);
  assert.match(await page.locator('.shipment-history').innerText(),/테스트 API 이력/);
  await page.evaluate(()=>localStorage.setItem('gonggu-quote-v3-session',JSON.stringify({access_token:'fixture-only',expires_at:9999999999})));
  await page.goto(base+'/?page=admin');
  await page.locator('.bundle-flow .shipment-history summary').waitFor();
  assert.equal(await page.locator('.bundle-summary-card').count(),1);
  assert.equal(await page.locator('.ordercard').count(),0);
  await page.locator('[data-filter="flow_shipped"]').click();
  assert.equal(await page.locator('.bundle-summary-card').count(),1);
  assert.equal(await page.locator('.bundle-item').count(),2);
  assert.match(await page.locator('.bundle-flow a').getAttribute('href'),/InvNo=12345678$/);
  // An uninstalled optional RPC must leave the existing order view usable.
  missing=true;
  await page.goto(base+'/?page=track&id='+childId+'&token=test-token');
  await page.locator('[data-action="edit-delivery"]').waitFor();
  await page.waitForFunction(()=>!document.body.innerText.includes('견적을 불러오는 중'));
  assert.equal(await page.locator('.shipment-history').count(),0);
  assert.match(await page.locator('body').innerText(),/테스트 구매자/);
  assert.deepEqual(errors,[]);
  assert(calls.every(x=>['gq_read_quote','gq_is_admin','gq_read_shipping_v26','gq_read_admin_shipping_v26'].includes(x)));
  console.log('PASS: buyer shared invoice/history, admin mixed-stage bundle/filter, missing-RPC fallback, no JavaScript errors or write RPCs');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
