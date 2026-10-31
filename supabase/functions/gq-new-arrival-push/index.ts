import {createClient} from "npm:@supabase/supabase-js@2.57.0";
const headers={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization,apikey,content-type","Access-Control-Allow-Methods":"POST,OPTIONS"};
const respond=(x:unknown,status=200)=>new Response(JSON.stringify(x),{status,headers});
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response(null,{headers});
 if(req.method!=="POST")return respond({error:"Method not allowed"},405);
 try{
 const bearer=(req.headers.get("authorization")||"").replace(/^Bearer\s+/i,"");
 const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
 const {data:{user},error}=await db.auth.getUser(bearer);
 if(error||!user)return respond({error:"관리자 로그인이 필요해요."},401);
 const {data:admin,error:adminError}=await db.from("gq_admins").select("user_id").eq("user_id",user.id).maybeSingle();
 if(adminError||!admin)return respond({error:"관리자만 신상 알림을 보낼 수 있어요."},403);
 let input;try{input=await req.json()}catch{return respond({error:"잘못된 요청이에요."},400)}
 const title=String(input.title||"").trim(),message=String(input.message||"").trim();
 const ids=input.request_ids;
 if(!title||title.length>60||!message||message.length>200||!Array.isArray(ids)||ids.length!==2||!ids.every(x=>typeof x==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(x)))return respond({error:"제목·내용·발송 정보를 확인해 주세요."},400);
 const sites=[
 {name:"기존 주소",app:"4ecfc195-43f7-4108-b6d4-abb11164a504",secret:"ONESIGNAL_GITHUB_API_KEY",url:"https://nostaljian.github.io/gonggu/?page=shop"},
 {name:"새 주소",app:"74494ff1-8318-40fd-ab2c-4bf9017a8991",secret:"ONESIGNAL_CLOUDFLARE_API_KEY",url:"https://miniyena.pages.dev/?page=shop"}];
 const results=await Promise.all(sites.map(async(site,i)=>{
  const apiKey=Deno.env.get(site.secret);
  if(!apiKey)return {site:site.name,ok:false,error:"알림 서버 설정 확인 필요"};
  try{
   const result=await fetch("https://api.onesignal.com/notifications",{method:"POST",headers:{"Content-Type":"application/json",Authorization:"Key "+apiKey},body:JSON.stringify({app_id:site.app,included_segments:["Subscribed Users"],target_channel:"push",headings:{en:title},contents:{en:message},url:site.url,idempotency_key:ids[i]}),signal:AbortSignal.timeout(20000)});
   const data=await result.json();
   const noRecipients=result.ok&&!data.id&&JSON.stringify(data.errors||"").includes("not subscribed");
   if(noRecipients)return {site:site.name,ok:true,empty:true};
   if(!result.ok||data.errors||!data.id)return {site:site.name,ok:false,error:"발송 접수 실패"};
   return {site:site.name,ok:true,id:data.id};
  }catch{return {site:site.name,ok:false,error:"연결 지연 · 같은 내용으로 재시도해 주세요"}}
 }));
 return respond({ok:results.every(r=>r.ok),results});
 }catch{return respond({error:"알림 서버 연결을 확인해 주세요."},500)}
});