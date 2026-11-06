/* MINIYENA – Nuvo A-type(일반) shipping workbook export.
   Separate from checkout and payment logic. Does not mutate orders. */
(function(){
'use strict';
const HEADERS=['주문번호','받는사람','전화번호1','전화번호2','우편번호','주소','상품명1','상품상세1','수량(A타입)','배송메시지','운임구분','운임','운송장번호'];
let layer=null,previousOverflow='',selected=new Set(),context=null;
const h=v=>String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
const xml=v=>String(v==null?'':v).replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g,'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&apos;');
function receivedQty(i){const q=Math.max(0,Number(i.quantity)||0);return Math.min(q,Math.max(0,['received','delivered'].includes(i.fulfillment)?q:Number(i.received_qty)||0));}
function dispatchedQty(id,h){return (Array.isArray(h)?h:[]).reduce((n,p)=>n+(p.items||[]).filter(i=>i.item_id===id).reduce((x,i)=>x+Math.max(0,Number(i.quantity)||0),0),0);}
function shipments(ctx){
 const {quotes,bundleRootId,balanceDue,workflowStage,normalizeBuyerPhone,saleItems}=ctx;
 const history=ctx.partialHistory||[],roots=new Set();
 for(const q of quotes)if(q.status==='confirmed'&&q.delivery_method==='courier'&&['new','preparing'].includes(workflowStage(q))&&!String(q.tracking_number||'').trim())roots.add(bundleRootId(q));
 const ready=[],blocked=[];
 for(const id of roots){
  const group=quotes.filter(q=>q.status!=='cancelled'&&bundleRootId(q)===id);
  const root=group.find(q=>q.id===id)||group[0];if(!root)continue;
  const issues=[];
  // A partially received buyer group must not silently become an invoice-export candidate.
  // Separate receipt needs an explicit customer request acknowledged by the admin.
  if(group.some(q=>!ctx.canReleaseGroup?.(q)))issues.push('다른 상품 입고 대기 · 별도 수령 미승인');
  if(group.some(q=>q.status!=='confirmed'))issues.push('확정 전 주문 포함');
  if(group.some(q=>q.delivery_method!=='courier'))issues.push('수령방식 불일치');
  if(group.some(q=>!['new','preparing'].includes(workflowStage(q))||String(q.tracking_number||'').trim()))issues.push('이미 발송·송장 등록됨');
  if(group.some(q=>q.cancel_requested_at||q.delivery_change_requested_at))issues.push('취소·배송지 변경 요청');
  if(group.some(q=>balanceDue(q)>0))issues.push('미입금액 있음');
  const phone=normalizeBuyerPhone(root.contact);
  if(!phone)issues.push('전화번호 확인');
  if(!String(root.recipient_name||'').trim())issues.push('수령자 누락');
  if(!/^[0-9]{5}$/.test(String(root.postal_code||'').trim()))issues.push('우편번호 누락');
  if(String(root.address_line1||'').trim().length<4)issues.push('주소 누락');
  if(group.some(q=>q.id!==root.id&&q.contact&&normalizeBuyerPhone(q.contact)!==phone))issues.push('묶음 연락처 불일치');
  if(group.some(q=>q.id!==root.id&&q.postal_code&&String(q.postal_code).trim()!==String(root.postal_code||'').trim()))issues.push('묶음 우편번호 불일치');
  if(group.some(q=>q.id!==root.id&&q.address_line1&&String(q.address_line1).trim()!==String(root.address_line1||'').trim()))issues.push('묶음 주소 불일치');
  const original=group.flatMap(q=>saleItems(q));
  const items=original.filter(i=>i.fulfillment!=='sold_out'&&i.fulfillment!=='delivered').map(i=>Object.assign({},i,{quantity:Math.max(0,receivedQty(i)-dispatchedQty(i.id,history))})).filter(i=>i.quantity>0);
  const qty=items.reduce((n,i)=>n+i.quantity,0);
  const waiting=original.reduce((n,i)=>n+Math.max(0,(Number(i.quantity)||0)-dispatchedQty(i.id,history)),0)-qty;
  if(!qty)issues.push('현재 발송 가능한 입고 상품 없음');
  (issues.length?blocked:ready).push({id,root,group,items,qty,waiting:Math.max(0,waiting),issues});
 }
 const sort=(a,b)=>String(a.root.recipient_name||a.root.buyer_name||'').localeCompare(String(b.root.recipient_name||b.root.buyer_name||''),'ko');
 ready.sort(sort);blocked.sort(sort);
 // Physical delivery label: one row for a matching recipient/contact/exact destination.
 // The original quote/bundle groups remain independent for invoicing and tracking updates.
 const merged=new Map(),normalize=x=>String(x||'').normalize('NFKC').trim().replace(/\s+/g,' ');
 for(const part of ready){
  const x=part.root;
  const phone=String(normalizeBuyerPhone(x.contact)||'').replace(/[^0-9]/g,'');
  const key=[normalize(x.recipient_name),phone,normalize(x.postal_code),
   normalize(x.address_line1),normalize(x.address_line2)].join('|');
  if(!merged.has(key))merged.set(key,{...part,parts:[part],group:[...part.group],items:[...part.items],deliveryNotes:[...new Set(part.group.map(q=>normalize(q.delivery_note)).filter(Boolean))]});
  else{
   const target=merged.get(key);
   target.parts.push(part);target.group.push(...part.group);target.items.push(...part.items);target.deliveryNotes=[...new Set([...target.deliveryNotes,...part.group.map(q=>normalize(q.delivery_note)).filter(Boolean)])];
   target.qty+=part.qty;target.waiting+=part.waiting;
  }
 }
 return {ready:[...merged.values()].sort(sort),blocked};
}
function writeZip(files){
 const enc=new TextEncoder(),parts=[],central=[];let offset=0;
 function crc32(buf){let c=0xffffffff;for(const b of buf){c^=b;for(let i=0;i<8;i++)c=(c>>>1)^((c&1)?0xedb88320:0);}return (c^0xffffffff)>>>0;}
 for(const [name,value] of files){
  const filename=enc.encode(name),data=enc.encode(value),crc=crc32(data);
  const local=new Uint8Array(30+filename.length),v=new DataView(local.buffer);
  v.setUint32(0,0x04034b50,true);v.setUint16(4,20,true);
  v.setUint32(14,crc,true);v.setUint32(18,data.length,true);v.setUint32(22,data.length,true);v.setUint16(26,filename.length,true);
  local.set(filename,30);parts.push(local,data);
  const dir=new Uint8Array(46+filename.length),d=new DataView(dir.buffer);
  d.setUint32(0,0x02014b50,true);d.setUint16(4,20,true);d.setUint16(6,20,true);
  d.setUint32(16,crc,true);d.setUint32(20,data.length,true);d.setUint32(24,data.length,true);
  d.setUint16(28,filename.length,true);d.setUint32(42,offset,true);dir.set(filename,46);
  central.push(dir);offset+=local.length+data.length;
 }
 const centralAt=offset;
 for(const dir of central){parts.push(dir);offset+=dir.length;}
 const end=new Uint8Array(22),v=new DataView(end.buffer);
 v.setUint32(0,0x06054b50,true);v.setUint16(8,files.length,true);v.setUint16(10,files.length,true);
 v.setUint32(12,offset-centralAt,true);v.setUint32(16,centralAt,true);parts.push(end);
 return new Blob(parts,{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
}
function workbook(rows){
 const grid=[HEADERS,...rows],letters='ABCDEFGHIJKLM';
 const sheetRows=grid.map((row,r)=>'<row r="'+(r+1)+'">'+row.map((value,c)=>{
  if(value===null||value===undefined||value==='')return '';
  const cell=letters[c]+(r+1);
  return r>0&&c===8&&Number.isInteger(value)?'<c r="'+cell+'"><v>'+value+'</v></c>':
   '<c r="'+cell+'" t="inlineStr"><is><t xml:space="preserve">'+xml(value)+'</t></is></c>';
 }).join('')+'</row>').join('');
 const pre='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
 const types=pre+'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>';
 const rels=pre+'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>';
 const book=pre+'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';
 const bookRel=pre+'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>';
 const sheet=pre+'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:M'+grid.length+'"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><cols><col min="1" max="1" width="23" customWidth="1"/><col min="2" max="4" width="17" customWidth="1"/><col min="5" max="5" width="12" customWidth="1"/><col min="6" max="6" width="46" customWidth="1"/><col min="7" max="8" width="32" customWidth="1"/></cols><sheetData>'+sheetRows+'</sheetData></worksheet>';
 return writeZip([['[Content_Types].xml',types],['_rels/.rels',rels],['xl/workbook.xml',book],['xl/_rels/workbook.xml.rels',bookRel],['xl/worksheets/sheet1.xml',sheet]]);
}
function dataRow(r){
 const x=r.root,items=r.items,first=String(items[0].product_name||'상품').trim();
 const names=new Set(items.map(i=>String(i.product_name||'상품').trim()));
 const name=first+(names.size>1?' 외 '+(names.size-1)+'종':'');
 const detail=items.map(i=>String(i.product_name||'상품')+' '+[i.color,i.size].filter(Boolean).join('/')+' ×'+i.quantity).join(' ; ');
 const phone=context.normalizeBuyerPhone(x.contact).replace(/^([0-9]{3})([0-9]{3,4})([0-9]{4})$/,'$1-$2-$3');
 return ['MY'+r.id.replace(/-/g,'').slice(0,16).toUpperCase(),String(x.recipient_name||'').trim(),phone,'',
  String(x.postal_code||'').trim(),[x.address_line1,x.address_line2].filter(Boolean).join(' ').trim(),
  name,detail,1,String((r.deliveryNotes||[]).join(' / ')||x.delivery_note||'').trim(),'','',''];
}
function updateCount(){
 if(!layer)return;
 const n=layer.querySelector('[data-nuvo-count]'),btn=layer.querySelector('[data-nuvo-download]');
 if(n)n.textContent=selected.size+'건 선택';
 if(btn)btn.disabled=!selected.size;
 const boxes=[...layer.querySelectorAll('[data-nuvo-id]')];
 const allButton=layer.querySelector('[data-nuvo-all]');
 if(allButton)allButton.textContent=boxes.length>0&&selected.size===boxes.length?'전체 해제':'전체 선택';
 for(const input of boxes){
  input.checked=selected.has(input.dataset.nuvoId);
  input.closest('.nuvo-entry')?.classList.toggle('is-selected',input.checked);
 }
}
function ensureStyles(){
 if(document.getElementById('nuvo-shipping-styles'))return;
 const css=document.createElement('style');css.id='nuvo-shipping-styles';
 css.textContent=".nuvo-mask{position:fixed;inset:0;z-index:100500;background:#0009;display:flex;align-items:flex-end;justify-content:center}\n.nuvo-dialog{box-sizing:border-box;width:min(100%,680px);height:min(88dvh,760px);max-height:94dvh;background:#fff;border-radius:20px 20px 0 0;display:flex;flex-direction:column;color:#222;box-shadow:0 -8px 30px #0002;overflow:hidden;font-family:inherit}\n.nuvo-title{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:17px 18px 13px;border-bottom:1px solid #eee;flex-shrink:0}\n.nuvo-title h2{font-size:19px;letter-spacing:-.035em;margin:0;font-weight:850}\n.nuvo-title small{display:block;color:#888;font-size:11px;margin-top:3px}\n.nuvo-close{border:0;background:#f4f4f4;border-radius:12px;font-size:24px;color:#555;width:39px;height:39px;flex-shrink:0}\n.nuvo-body{flex:1;min-height:0;overflow-y:auto;overscroll-behavior:contain;padding:14px 17px 20px}\n.nuvo-summary{display:flex;justify-content:space-between;align-items:center;gap:8px;margin:0 0 8px}\n.nuvo-summary strong{font-size:17px;font-weight:850}\n.nuvo-summary span{font-size:12px;color:#777}\n.nuvo-hint{font-size:12px!important;line-height:1.5!important;color:#777!important;margin:0 0 16px!important}\n.nuvo-section-head{display:flex;align-items:center;justify-content:space-between;gap:8px;margin:0 0 8px}\n.nuvo-section-head strong{font-size:14px;font-weight:800}\n.nuvo-section-head button{border:1px solid #ddd;background:#fff;color:#333;border-radius:8px;padding:7px 10px;font-size:12px;min-height:34px}\n.nuvo-list{display:flex;flex-direction:column;gap:8px;min-height:0}\n.nuvo-entry{border:1px solid #e3e3e3;border-radius:13px;background:#fff;overflow:hidden}\n.nuvo-entry.is-selected{border-color:#333;background:#fcfcfc}\n.nuvo-entry-main{display:flex;align-items:flex-start;gap:11px;padding:14px 12px 12px;cursor:pointer}\n.nuvo-entry-main input{width:21px;height:21px;margin:2px 0 0;flex-shrink:0;accent-color:#242424}\n.nuvo-entry-copy{flex:1;min-width:0}\n.nuvo-entry-copy b{font-size:15px;display:block;font-weight:800}\n.nuvo-entry-copy small{display:block;font-size:12px;line-height:1.45;color:#666;margin-top:3px;overflow-wrap:anywhere}\n.nuvo-entry-items{border-top:1px solid #f0f0f0;padding:0 13px 0 44px}\n.nuvo-entry-items summary{font-size:11px;color:#777;cursor:pointer;padding:10px 0;list-style:none}\n.nuvo-entry-items summary:after{content:'⌄';margin-left:5px}\n.nuvo-entry-items[open] summary:after{content:'⌃'}\n.nuvo-entry-items div{font-size:11px;line-height:1.5;color:#666;border-top:1px solid #f1f1f1;padding:8px 0 12px;overflow-wrap:anywhere}\n.nuvo-empty{border:1px dashed #ddd;border-radius:12px;padding:20px 12px;color:#777;font-size:13px;text-align:center}\n.nuvo-skipped,.nuvo-help{margin-top:13px;border-top:1px solid #eee;padding-top:12px}\n.nuvo-skipped summary,.nuvo-help summary{font-size:12px;font-weight:750;color:#666;cursor:pointer;list-style:none}\n.nuvo-skipped summary:after,.nuvo-help summary:after{content:'⌄';float:right;color:#999}\n.nuvo-skipped[open] summary:after,.nuvo-help[open] summary:after{content:'⌃'}\n.nuvo-skipped div{padding:9px 0;border-bottom:1px solid #eee}\n.nuvo-skipped b{display:block;font-size:12px}\n.nuvo-skipped small{display:block;color:#ad5252;font-size:11px;line-height:1.5;margin-top:3px}\n.nuvo-help p{font-size:11px;line-height:1.6;color:#777;margin:10px 0 2px}\n.nuvo-footer{flex-shrink:0;padding:12px 17px max(15px,env(safe-area-inset-bottom));border-top:1px solid #e9e9e9;background:#fff;box-shadow:0 -4px 12px #00000005}\n.nuvo-download{display:block;width:100%;border:0;background:#222;color:#fff;border-radius:11px;padding:13px 9px;font-size:14px;font-weight:850;min-height:49px}\n.nuvo-download:disabled{background:#e4e4e4;color:#888}\n.nuvo-footer small{display:block;text-align:center;font-size:11px;color:#888;margin-top:7px}\n@media(min-width:760px){.nuvo-mask{align-items:center}.nuvo-dialog{height:min(83vh,720px);border-radius:18px}}";
 document.head.appendChild(css);
}
function close(){
 if(layer){layer.remove();layer=null;}document.body.style.overflow=previousOverflow;
 selected.clear();context=null;
}
function open(ctx){
 if(!ctx||!Array.isArray(ctx.quotes)||typeof ctx.bundleRootId!=='function')throw Error('관리자 주문 데이터를 불러오지 못했어요.');
 close();context=ctx;ensureStyles();const batch=shipments(ctx);
 selected=new Set(batch.ready.filter(r=>Array.isArray(ctx.preselectedIds)&&ctx.preselectedIds.includes(r.id)).map(r=>r.id));previousOverflow=document.body.style.overflow;
 layer=document.createElement('div');layer.className='nuvo-mask';layer.setAttribute('role','presentation');
 layer.innerHTML='<section class="nuvo-dialog" role="dialog" aria-modal="true" aria-label="미니예나 택배 일괄등록">'+
  '<div class="nuvo-title"><div><h2>택배 일괄등록</h2><small>미니예나 · 롯데택배 송장 엑셀</small></div><button type="button" class="nuvo-close" data-nuvo-close aria-label="닫기">×</button></div>'+
  '<div class="nuvo-body">'+
   '<div class="nuvo-summary"><strong>발송 가능 '+batch.ready.length+'건</strong><span>확인 필요 '+batch.blocked.length+'건</span></div>'+
   '<p class="nuvo-hint">이번에 실제 보낼 사람만 선택하세요. 같은 주소·연락처는 송장 1장으로 합쳐요.</p>'+
   '<div class="nuvo-section-head"><strong>발송 대상 선택</strong><button type="button" data-nuvo-all>전체 선택</button></div>'+
   '<div class="nuvo-list">'+(batch.ready.length?batch.ready.map(r=>
    '<article class="nuvo-entry"><label class="nuvo-entry-main"><input type="checkbox" data-nuvo-id="'+h(r.id)+'"><span class="nuvo-entry-copy"><b>'+h(r.root.recipient_name||r.root.buyer_name)+'</b><small>이번 발송 '+r.qty+'개 · 주문 '+r.group.length+'건'+(r.parts.length>1?' · 합배송 '+r.parts.length+'묶음':'')+'</small>'+(r.waiting?'<small>남은 미입고·미발송 '+r.waiting+'개</small>':'')+'</span></label>'+
    '<details class="nuvo-entry-items"><summary>상품 '+r.items.length+'종 확인</summary><div>'+h(r.items.map(i=>(i.product_name||'상품')+' '+[i.color,i.size].filter(Boolean).join('/')+' ×'+i.quantity).join(' · '))+'</div></details></article>'
   ).join(''):'<div class="nuvo-empty">현재 발송 가능한 주문이 없어요.</div>')+'</div>'+
   (batch.blocked.length?'<details class="nuvo-skipped"><summary>제외된 주문 '+batch.blocked.length+'건 · 이유 확인</summary>'+
    batch.blocked.map(r=>'<div><b>'+h(r.root.buyer_name||r.root.recipient_name)+'</b><small>'+h(r.issues.join(' · '))+'</small></div>').join('')+'</details>':'')+
   '<div data-nuvo-import-slot></div>'+
   '<details class="nuvo-help"><summary>송장 엑셀 작성 안내</summary><p>택배 수량(A타입)은 송장 장수라서 한 수령인당 1로 입력해요. 상품 개수는 상품상세에 표기되며, 택배 접수 후 운송장번호가 들어간 파일을 업로드하면 배송 중 상태로 반영할 수 있어요.</p></details>'+
  '</div>'+
  '<footer class="nuvo-footer"><button type="button" class="nuvo-download" data-nuvo-download><span data-nuvo-count>'+selected.size+'건 선택</span> · 송장 엑셀 다운로드</button><small>선택한 수령인만 다운로드해요 · 자동 출고되지 않아요</small></footer>'+
  '</section>';
 document.body.appendChild(layer);document.body.style.overflow='hidden';updateCount();
 if(window.MiniNuvoImport)window.MiniNuvoImport.attach(layer,batch,ctx);
 layer.addEventListener('click',e=>{
  if(e.target===layer||e.target.closest('[data-nuvo-close]')){close();return;}
  if(e.target.closest('[data-nuvo-all]')){const allSelected=batch.ready.length>0&&selected.size===batch.ready.length;if(allSelected)selected.clear();else{if(batch.ready.length>3&&!confirm('발송 후보 '+batch.ready.length+'건을 모두 선택할까요? 실제 택배 보낼 대상만 선택해 주세요.'))return;selected=new Set(batch.ready.map(r=>r.id));}updateCount();return;}
  if(e.target.closest('[data-nuvo-download]')){
   const chosen=batch.ready.filter(r=>selected.has(r.id));
   if(!chosen.length)return;
   if(chosen.length>1000){alert('한 번에 최대 1,000건까지 내보낼 수 있어요.');return;}
   const parcels=chosen.length,units=chosen.reduce((n,r)=>n+r.qty,0);
   const names=chosen.slice(0,18).map((r,i)=>(i+1)+'. '+(r.root.recipient_name||r.root.buyer_name)+' / '+r.qty+'개'+(r.parts.length>1?' / 합배송 '+r.parts.length+'묶음':'')).join('\n');
   if(!window.confirm('이번에 실제로 발송할 택배 '+parcels+'건 · 상품 '+units+'개가 맞나요?\n\n'+names+(parcels>18?'\n외 '+(parcels-18)+'건':'')+'\n\n확인하면 이 대상만 택배 엑셀 한 시트에 담아요.'))return;
   const file=workbook(chosen.map(dataRow)),url=URL.createObjectURL(file),a=document.createElement('a');
   a.href=url;a.download='미니예나_택배일괄등록_'+new Date(Date.now()+9*3600000).toISOString().slice(0,10).replace(/-/g,'')+'.xlsx';
   document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),3000);return;
  }
 });
 layer.addEventListener('change',e=>{const box=e.target.closest('[data-nuvo-id]');if(!box)return;if(box.checked)selected.add(box.dataset.nuvoId);else selected.delete(box.dataset.nuvoId);updateCount();});
}
window.MiniNuvoShipping={open,prepare:shipments};
})();
