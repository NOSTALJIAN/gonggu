import {createClient} from "npm:@supabase/supabase-js@2.57.0";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization,apikey,content-type","Access-Control-Allow-Methods":"POST,OPTIONS"};
const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{"Content-Type":"application/json",...cors}});
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response(null,{headers:cors});
 if(req.method!=="POST")return reply({error:"method"},405);
 const url=Deno.env.get("SUPABASE_URL")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const db=createClient(url,service,{auth:{persistSession:false}});
 const secret=req.headers.get("x-gq-webhook-secret");
 let authorized=false;
 if(secret){
  const {data,error}=await db.rpc("gq_push_webhook_valid",{p_secret:secret});
  authorized=!error&&data===true;
 }else{
  const token=(req.headers.get("Authorization")||"").replace(/^Bearer /,"");
  if(token){
   const {data:{user}}=await db.auth.getUser(token);
   if(user){const {data}=await db.from("gq_admins").select("user_id").eq("user_id",user.id).maybeSingle();authorized=!!data}
  }
 }
 if(!authorized)return reply({error:"Unauthorized"},401);
 const apps=[
  {name:"github",id:"4ecfc195-43f7-4108-b6d4-abb11164a504",key:Deno.env.get("ONESIGNAL_GITHUB_API_KEY"),url:"https://nostaljian.github.io/gonggu/"},
  {name:"cloudflare",id:"74494ff1-8318-40fd-ab2c-4bf9017a8991",key:Deno.env.get("ONESIGNAL_CLOUDFLARE_API_KEY"),url:"https://miniyena.pages.dev/"}
 ];
 if(apps.every(a=>!a.key))return reply({error:"OneSignal secrets missing"},503);
 const {data:jobs,error}=await db.from("gq_push_outbox").select("id,customer_key,title,message,attempts").eq("state","pending").order("id").limit(30);
 if(error)return reply({error:"Outbox query failed"},500);
 let sent=0,failed=0,partiallySent=0,notSubscribed=0;
 for(const job of jobs||[]){
  const nextAttempt=Math.max(0,Number(job.attempts||0))+1;
  const {data:claimed}=await db.from("gq_push_outbox").update({state:"processing",attempts:nextAttempt}).eq("id",job.id).eq("state","pending").select("id").maybeSingle();
  if(!claimed)continue;
  let accepted=0;
  const errors:string[]=[];
  for(const app of apps){
   if(!app.key){errors.push(app.name+":missing API key");continue}
   try{
    const res=await fetch("https://api.onesignal.com/notifications",{method:"POST",headers:{"Content-Type":"application/json",Authorization:"Key "+app.key},
     body:JSON.stringify({app_id:app.id,target_channel:"push",include_aliases:{external_id:[job.customer_key]},
      headings:{en:job.title},contents:{en:job.message},url:app.url})});
    const body=await res.json().catch(()=>({}));
    // OneSignal can return HTTP 200 with id:"" and errors:["All included players are not subscribed"].
    // That is NOT a delivered notification.
    const acceptedHere=res.ok&&typeof body.id==="string"&&body.id.length>0;
    if(acceptedHere)accepted++;
    else {
     const detail=Array.isArray(body.errors)?body.errors.join(","):String(body.errors||body.message||"no subscription");
     errors.push(app.name+":"+res.status+" "+detail.slice(0,120));
    }
    console.log("buyer push result",job.id,app.name,acceptedHere?"accepted":"no active recipient / error",res.status);
   }catch(e){
    errors.push(app.name+":"+String(e).slice(0,150));
    console.warn("buyer push provider error",job.id,app.name,String(e).slice(0,150));
   }
  }
  const noRecipients=errors.length>0&&errors.every(e=>/not subscribed|no subscription|no active recipient/i.test(e));
  const nextState=accepted>0?"sent":"failed";
  const detail=errors.length?(accepted>0?"partial: ":"")+errors.join(" | "):null;
  const {error:saveError}=await db.from("gq_push_outbox").update({
    state:nextState,sent_at:accepted>0?new Date().toISOString():null,
    last_error:accepted===0&&noRecipients?"No active subscriptions: "+String(detail).slice(0,350):detail?.slice(0,450)||null
   }).eq("id",job.id);
  if(saveError)console.error("buyer push outbox state save failed",job.id,saveError.message);
  if(accepted>0){sent++;if(errors.length)partiallySent++}
  else{failed++;if(noRecipients)notSubscribed++}
 }
 return reply({processed:sent+failed,sent,failed,partiallySent,notSubscribed});
});