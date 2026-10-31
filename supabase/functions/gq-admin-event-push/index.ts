import {createClient} from "npm:@supabase/supabase-js@2.57.0";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization,apikey,content-type","Access-Control-Allow-Methods":"POST,OPTIONS"};
const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{"Content-Type":"application/json",...cors}});
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response(null,{headers:cors});
 if(req.method!=="POST")return reply({error:"method"},405);
 const body=await req.json().catch(()=>({}));
 const id=String(body.quote_id||""),token=String(body.lookup_token||""),event=String(body.event||"");
 if(!/^[0-9a-f-]{36}$/i.test(id)||token.length<16||token.length>256)return reply({error:"invalid request"},400);
 if(!["purchase_intent","cancel_request","cancel_withdrawn","new_quote","option_change_request","option_change_withdrawn"].includes(event))return reply({error:"invalid event"},400);
 const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
 const {data:q,error}=await db.from("gq_quotes").select("id,created_at,lookup_token,purchase_intent,purchase_intent_at,cancel_requested_at,cancel_withdrawn_at,buyer_name,baby_name").eq("id",id).eq("lookup_token",token).maybeSingle();
 if(error||!q)return reply({error:"not found"},404);
 if(event==="option_change_request"||event==="option_change_withdrawn"){
  const rid=String(body.request_id||"");
  if(!/^[0-9a-f-]{36}$/i.test(rid))return reply({error:"invalid request"},400);
  const functionName=event==="option_change_withdrawn"?"gq_verify_option_withdrawn_push_v68":"gq_verify_option_request_push";
  const {data:verified,error:verifyError}=await db.rpc(functionName,{p_request_id:rid,p_quote_id:id,p_lookup_token:token});
  if(verifyError||verified!==true)return reply({error:"not verified"},403);
 }
 const when=event==="new_quote"?q.created_at:event==="purchase_intent"?q.purchase_intent_at:event==="cancel_withdrawn"?q.cancel_withdrawn_at:q.cancel_requested_at;
 if(event!=="option_change_request"&&event!=="option_change_withdrawn"&&(!when||Date.now()-new Date(when).getTime()>120000||Date.now()-new Date(when).getTime()< -30000))return reply({error:"no recent change"},409);
 const intent=q.purchase_intent;
 const msg=event==="option_change_withdrawn"?`${q.buyer_name||"구매자"} · ${q.baby_name||"아기"} — 옵션변경 요청을 취소했어요. 기존 주문은 그대로 유지됩니다.`:event==="option_change_request"?`${q.buyer_name||"구매자"} · ${q.baby_name||"아기"} — 최종 주문 옵션 변경 요청이 접수됐어요.`:event==="new_quote"?`${q.buyer_name||"구매자"} · ${q.baby_name||"아기"} — 새 견적 요청이 접수됐어요.`:event==="cancel_withdrawn"?"취소 요청을 철회했어요. 기존 주문은 유지됩니다.":event==="cancel_request"?"취소 요청이 접수됐어요.":intent==="buy_now"?"이번 회차 구매를 선택했어요.":intent==="next_round"?"다음 회차 구매를 선택했어요.":"구매를 보류했어요.";
 const apps=[{id:"4ecfc195-43f7-4108-b6d4-abb11164a504",key:Deno.env.get("ONESIGNAL_GITHUB_API_KEY")},{id:"74494ff1-8318-40fd-ab2c-4bf9017a8991",key:Deno.env.get("ONESIGNAL_CLOUDFLARE_API_KEY")}];
 const results=[];
 for(const app of apps){
  if(!app.key)continue;
  const res=await fetch("https://api.onesignal.com/notifications",{method:"POST",headers:{"Content-Type":"application/json",Authorization:"Key "+app.key},body:JSON.stringify({app_id:app.id,target_channel:"push",include_aliases:{miniyena_admin:["manager"]},headings:{en:"미니예나 관리자 알림"},contents:{en:msg},url:app.id===apps[1].id?"https://miniyena.pages.dev/":"https://nostaljian.github.io/gonggu/"})});
  const result=await res.text(); console.log("admin push",event,app.id,res.status,result.slice(0,1500)); results.push({ok:res.ok&&(()=>{try{const x=JSON.parse(result);return Number(x.recipients||0)>0}catch{return false}})()});
 }
 return reply({ok:results.some(x=>x.ok)});
});