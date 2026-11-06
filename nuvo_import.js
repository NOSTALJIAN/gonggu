/* MINIYENA: import tracking numbers from a Nuvo A-type XLSX; shipped units are server-validated. */
(function(){
'use strict';
function parseXML(value){
 const d=new DOMParser().parseFromString(value,'application/xml');
 if(d.getElementsByTagName('parsererror').length)throw Error('엑셀 파일이 올바르지 않아요.');
 return d;
}
async function readNuvo(file){
 if(!file||file.size>15000000)throw Error('15MB 이하의 xlsx 파일을 선택해 주세요.');
 const data=new Uint8Array(await file.arrayBuffer());
 if(data.length<22)throw Error('엑셀 파일이 손상되었어요.');
 const view=new DataView(data.buffer),u16=p=>view.getUint16(p,true),u32=p=>view.getUint32(p,true),decode=new TextDecoder();
 let eocd=-1;
 for(let p=data.length-22;p>=Math.max(0,data.length-65558);p--){if(u32(p)===0x06054b50){eocd=p;break;}}
 if(eocd<0)throw Error('xlsx 형식의 파일만 지원해요.');
 const files=new Map();let pos=u32(eocd+16),count=u16(eocd+10);
 if(count>2000)throw Error('엑셀 파일의 항목이 너무 많아요.');
 for(let i=0;i<count;i++){
  if(pos+46>data.length||u32(pos)!==0x02014b50)throw Error('엑셀 파일 구조가 잘못됐어요.');
  const method=u16(pos+10),size=u32(pos+20),expanded=u32(pos+24),n=u16(pos+28),extra=u16(pos+30),comment=u16(pos+32),offset=u32(pos+42);
  if(pos+46+n>data.length)throw Error('엑셀 파일이 손상되었어요.');
  files.set(decode.decode(data.subarray(pos+46,pos+46+n)),{method,size,expanded,offset});
  pos+=46+n+extra+comment;
 }
 async function read(path,optional=false){
  const item=files.get(path);
  if(!item){if(optional)return '';throw Error('누보 A타입 엑셀의 첫 번째 시트를 찾지 못했어요.');}
  if(item.expanded>12000000)throw Error('엑셀 파일 용량이 너무 커요.');
  const p=item.offset;
  if(p+30>data.length||u32(p)!==0x04034b50)throw Error('엑셀 파일이 손상되었어요.');
  const start=p+30+u16(p+26)+u16(p+28),part=data.slice(start,start+item.size);
  if(part.length!==item.size)throw Error('엑셀 파일이 손상되었어요.');
  if(item.method===0)return decode.decode(part);
  if(item.method!==8||typeof DecompressionStream==='undefined')throw Error('이 엑셀은 최신 크롬 브라우저에서 열어 주세요.');
  try{
   const inflated=await new Response(new Blob([part]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer();
   if(inflated.byteLength>12000000)throw Error('엑셀 파일 용량이 너무 커요.');
   return decode.decode(inflated);
  }catch(e){throw Error('엑셀 압축을 해제하지 못했어요. 누보에서 다시 저장해 주세요.');}
 }
 const strings=await read('xl/sharedStrings.xml',true);
 const shared=strings?[...parseXML(strings).getElementsByTagNameNS('*','si')].map(n=>[...n.getElementsByTagNameNS('*','t')].map(t=>t.textContent||'').join('')):[];
 const sheet=parseXML(await read('xl/worksheets/sheet1.xml'));
 const rows=[...sheet.getElementsByTagNameNS('*','row')].slice(0,1100).map(row=>{
  const o={};
  for(const cell of row.getElementsByTagNameNS('*','c')){
   const col=(cell.getAttribute('r')||'').match(/^[A-Z]+/)?.[0];if(!col)continue;
   const type=cell.getAttribute('t')||'';
   const value=type==='inlineStr'?[...cell.getElementsByTagNameNS('*','t')].map(n=>n.textContent||'').join(''):cell.getElementsByTagNameNS('*','v')[0]?.textContent||'';
   o[col]=String(type==='s'?shared[Number(value)]||'':value).trim();
  }
  return o;
 });
 if(rows.length<2)throw Error('엑셀에 주문 정보가 없어요.');
 const columns=rows[0],header=name=>Object.keys(columns).find(k=>String(columns[k]).replace(/\s/g,'')===name);
 const orderColumn=header('주문번호'),trackingColumn=header('운송장번호');
 if(!orderColumn||!trackingColumn)throw Error('주문번호와 운송장번호 열이 있는 누보 A타입 엑셀 파일을 올려 주세요.');
 return rows.slice(1).map(r=>({order:String(r[orderColumn]||'').trim().toUpperCase(),tracking:String(r[trackingColumn]||'').trim()})).filter(r=>r.order||r.tracking);
}
function attach(layer,batch,ctx){
 const button=layer.querySelector('[data-nuvo-download]');if(!button||!ctx||!ctx.isAdmin)return;
 const panel=document.createElement('div');panel.className='nuvo-import-panel';
 panel.innerHTML='<label class="nuvo-import-label">📥 누보 송장 엑셀 업로드 · 일괄 배송 중 등록<input type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" data-nuvo-import></label><p class="nuvo-import-result" role="status">송장번호가 입력된 누보 A타입 엑셀을 올리면, 입고된 상품만 등록해요.</p>';
 button.insertAdjacentElement('afterend',panel);
 const css=document.createElement('style');css.id='nuvo-import-styles';
 if(!document.getElementById(css.id)){
  css.textContent='.nuvo-import-panel{padding:10px 0;border-bottom:1px solid #e5e5e5}.nuvo-import-label{display:flex;flex-direction:column;gap:7px;align-items:center;border:1px dashed #aaa;background:#fafafa;padding:13px;border-radius:9px;text-align:center;font-weight:750;font-size:13px;cursor:pointer}.nuvo-import-label input{width:min(100%,340px);font-size:12px;font-weight:400}.nuvo-import-result{font-size:11px!important;color:#777!important;white-space:pre-line}';
  document.head.append(css);
 }
 const input=panel.querySelector('input'),result=panel.querySelector('.nuvo-import-result');
 input.addEventListener('change',async()=>{
  const file=input.files?.[0];if(!file)return;
  input.disabled=true;result.textContent='송장 파일 검사 중…';
  try{
   const rows=await readNuvo(file);
   const available=new Map(batch.ready.map(r=>['MY'+r.id.replace(/-/g,'').slice(0,16).toUpperCase(),r]));
   const chosen=[],used=new Set();
   for(const row of rows){
    if(!row.tracking)continue;
    const dest=available.get(row.order);
    if(!dest)throw Error('현재 발송 가능한 주문과 맞지 않는 주문번호가 있어요: '+row.order);
    if(used.has(row.order))throw Error('한 주문번호가 여러 번 있어요: '+row.order);
    if(!/^[A-Za-z0-9 -]{4,80}$/.test(row.tracking))throw Error('송장번호를 확인해 주세요: '+row.order);
    if(dest.items.some(i=>!Number.isInteger(i.quantity)||i.quantity<1||i.quantity>20))throw Error('상품별 발송 수량은 최대 20개예요: '+row.order);
    chosen.push({dest,tracking:row.tracking});used.add(row.order);
   }
   if(!chosen.length)throw Error('송장번호가 입력된 주문이 없어요.');
   if(chosen.length>100)throw Error('한 번에 100건 이하로 나눠 등록해 주세요.');
   const preview=chosen.slice(0,12).map(x=>(x.dest.root.recipient_name||x.dest.root.buyer_name)+' / '+x.dest.qty+'개 / '+x.tracking).join('\n');
   if(!confirm('롯데택배 '+chosen.length+'건을 배송 중으로 등록할까요?\n\n'+preview+(chosen.length>12?'\n외 '+(chosen.length-12)+'건':'')+'\n\n미입고 상품과 기존 배송비·입금액은 그대로 유지해요.')){
    result.textContent='등록을 취소했어요.';return;
   }
   let done=0;const failures=[];
   for(const {dest,tracking} of chosen){
    result.textContent='배송 중 등록 중… '+done+'/'+chosen.length+'건';
    try{
     await ctx.rpc('gq_admin_create_partial_parcel_v118',{p_root_quote_id:dest.id,p_carrier:'롯데택배',p_tracking_number:tracking,p_lines:dest.items.map(i=>({item_id:i.id,quantity:i.quantity}))},true);
     done++;
    }catch(e){failures.push((dest.root.recipient_name||dest.root.buyer_name)+': '+(e?.message||'등록 실패'));}
   }
   result.textContent='등록 완료 '+done+'건'+(failures.length?' · 실패 '+failures.length+'건\n'+failures.slice(0,8).join('\n'):' · 미입고 상품은 계속 입고 대기 중');
   if(done){await ctx.reload();ctx.notify('송장 '+done+'건을 등록했어요.');}
  }catch(e){result.textContent=e?.message||'엑셀 일괄등록에 실패했어요.';}
  finally{input.disabled=false;input.value='';}
 });
}
window.MiniNuvoImport={attach};
})();
