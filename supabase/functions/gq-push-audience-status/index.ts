import {createClient} from "npm:@supabase/supabase-js@2.57.0";
Deno.serve(async req=>{
 const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
 const {data:valid,error}=await db.rpc("gq_push_webhook_valid",{p_secret:req.headers.get("x-gq-webhook-secret")||""});
 if(error||valid!==true)return new Response("Unauthorized",{status:401});
 const apps=[["github","4ecfc195-43f7-4108-b6d4-abb11164a504","ONESIGNAL_GITHUB_API_KEY"],["cloudflare","74494ff1-8318-40fd-ab2c-4bf9017a8991","ONESIGNAL_CLOUDFLARE_API_KEY"]];
 const results=await Promise.all(apps.map(async([name,id,key])=>{
 const res=await fetch("https://api.onesignal.com/apps/"+id+"/segments?limit=300",{headers:{Authorization:"Key "+Deno.env.get(key)}});
 const body=await res.json();
 return {site:name,status:res.status,data:body};
 }));
 return Response.json(results);
});