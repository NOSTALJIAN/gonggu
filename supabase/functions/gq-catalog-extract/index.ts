import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ALLOWED = new Set(["https://nostaljian.github.io", "https://miniyena.pages.dev"]);
const headers = (origin: string) => ({
  "Content-Type": "application/json; charset=utf-8",
  "Access-Control-Allow-Origin": ALLOWED.has(origin) ? origin : "https://miniyena.pages.dev",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});
const reply = (origin: string, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: headers(origin) });

const itemSchema = {
  type: "object", additionalProperties: false,
  properties: {
    name: { type: "string" },
    category: { type: "string", enum: ["바디수트","세트","상의","하의","아우터","원피스","스커트","모자","양말","악세서리","잡화",""] },
    wholesale_price: { type: ["integer", "null"] },
    colors: { type: "array", items: { type: "string" } },
    sizes: { type: "array", items: { type: "string" } },
    fabric: { type: "string" },
    note: { type: "string" },
    photo_box: { type: ["array", "null"], items: { type: "number" } }
  },
  required: ["name","category","wholesale_price","colors","sizes","fabric","note","photo_box"]
};
const schema = {
  type: "object", additionalProperties: false,
  properties: { products: { type: "array", items: itemSchema } },
  required: ["products"]
};

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin") || "";
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: headers(origin) });
  if (req.method !== "POST") return reply(origin, 405, { error: "지원하지 않는 요청입니다." });
  if (!ALLOWED.has(origin)) return reply(origin, 403, { error: "미니예나 관리자 사이트에서만 사용할 수 있어요." });
  const bearer = req.headers.get("authorization") || "";
  if (!/^Bearer \S+$/.test(bearer)) return reply(origin, 401, { error: "관리자 로그인이 필요해요." });
  const endpoint = Deno.env.get("SUPABASE_URL");
  const publishable = Deno.env.get("SUPABASE_ANON_KEY");
  if (!endpoint || !publishable) return reply(origin, 503, { error: "서버 인증 설정을 확인해 주세요." });
  try {
    const authorized = await fetch(endpoint + "/rest/v1/rpc/gq_is_admin", {
      method: "POST", headers: { "Authorization": bearer, "apikey": publishable, "Content-Type": "application/json" },
      body: "{}",
    });
    if (!authorized.ok || (await authorized.json()) !== true)
      return reply(origin, 403, { error: "관리자 권한을 확인하지 못했어요. 다시 로그인해 주세요." });
    const apiKey = Deno.env.get("OPENAI_API_KEY");
    if (!apiKey) return reply(origin, 503, { error: "AI 이미지 인식 키가 아직 설정되지 않았어요. Supabase Edge Function Secrets에 OPENAI_API_KEY를 등록해 주세요." });
    const payload = await req.json().catch(() => ({}));
    const imageData = payload?.image_data_url;
    if (typeof imageData !== "string" || imageData.length > 10500000 ||
        !/^data:image\/(?:jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/.test(imageData))
      return reply(origin, 400, { error: "이미지 파일을 확인해 주세요 (최대 약 7MB)." });
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 65000);
    let result: Response;
    try {
      result = await fetch("https://api.openai.com/v1/responses", {
        method: "POST", signal: controller.signal,
        headers: { "Authorization": "Bearer " + apiKey, "Content-Type": "application/json" },
        body: JSON.stringify({
          model: Deno.env.get("CATALOG_AI_MODEL") || "gpt-4.1-mini",
          store: false,
          max_output_tokens: 4600,
          input: [{ role: "user", content: [
            { type: "input_text", text:
              "이 이미지는 한국 유아동복 도매 카탈로그예요. 보이는 상품 1개당 products 한 항목을 반환하세요. 카탈로그의 이미지/명칭/도매 price/fabric/color/size를 정확히 연결하고, 없는 정보는 지어내지 말고 공백 또는 null로 두세요. 한국어로 작성. 상품 사진 부분의 경계 좌표 photo_box는 이미지 전체를 0~1000으로 정규화한 [좌,상,우,하]이며 반드시 상품 사진만 포함하고 설명 표, 테두리, 전화번호/회사 연락처는 제외하세요. 사진 부분을 특정할 수 없다면 null. 상품명은 원문 유지. 가격은 원 단위 정수. 크기 '6m12m18m'는 ['6m','12m','18m']으로 분리하세요. color의 쉼표 목록은 나누고 설명/모델명과 혼동하지 마세요. 상품별 사이즈에 공통 내용이 있으면 각 상품에 복사하세요. 의류 부위로 카테고리 분류. 설명이 적혀 있으면 note에 간단히 복사하되 연락처는 제외하세요. 빈 슬롯은 상품으로 만들지 마세요. 최대 24개." },
            { type: "input_image", image_url: imageData, detail: "high" }
          ]}],
          text: { format: { type: "json_schema", name: "wholesale_catalog", strict: true, schema } }
        })
      });
    } finally { clearTimeout(timer); }
    if (!result.ok) {
      console.warn("Catalog OCR upstream status", result.status);
      return reply(origin, 502, { error: result.status === 429 ? "AI 요청이 많아요. 잠시 후 다시 시도해 주세요." : "AI 사진 분석에 실패했어요. 관리자 AI 설정과 사용 한도를 확인해 주세요." });
    }
    const out = await result.json();
    const text = (out.output || []).flatMap((x: any) => x.content || []).find((x: any) => x.type === "output_text")?.text;
    if (typeof text !== "string") return reply(origin, 502, { error: "사진 분석 결과를 읽을 수 없어요. 다시 시도해 주세요." });
    const data = JSON.parse(text);
    const products = (Array.isArray(data.products) ? data.products : []).slice(0,24).map((row: any) => ({
      name: String(row.name || "").trim().slice(0,100),
      category: String(row.category || ""),
      wholesale_price: Number.isInteger(row.wholesale_price) && row.wholesale_price >= 0 && row.wholesale_price <= 100000000 ? row.wholesale_price : null,
      colors: (Array.isArray(row.colors) ? row.colors : []).filter((x: unknown) => typeof x === "string").map((x: string) => x.trim().slice(0,50)).filter(Boolean).slice(0,30),
      sizes: (Array.isArray(row.sizes) ? row.sizes : []).filter((x: unknown) => typeof x === "string").map((x: string) => x.trim().slice(0,30)).filter(Boolean).slice(0,30),
      fabric: String(row.fabric || "").trim().slice(0,200),
      note: String(row.note || "").trim().slice(0,1000),
      photo_box: Array.isArray(row.photo_box) && row.photo_box.length === 4 &&
        row.photo_box.every((x: unknown) => typeof x === "number" && Number.isFinite(x) && x >= 0 && x <= 1000) &&
        row.photo_box[2] > row.photo_box[0] && row.photo_box[3] > row.photo_box[1] ? row.photo_box : null
    })).filter((row: any) => row.name);
    return reply(origin, 200, { products });
  } catch (e) {
    console.error("Catalog OCR:", e instanceof Error ? e.message : "Unknown error");
    return reply(origin, 500, { error: "사진 분석 중 오류가 발생했어요. 다시 시도해 주세요." });
  }
});
