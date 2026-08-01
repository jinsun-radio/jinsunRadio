// 可切換的 LLM 介面。三種供應商：
//   - mock    ：離線、免金鑰（讓狀態機與測試能跑）
//   - apikey  ：OpenAI 相容閘道（預設 XCC Gateway，與 ASR 同一把 x-bf-vk 金鑰）← 預設
//   - bedrock ：Amazon Bedrock（AWS；保留為選項，非預設）
//
// **供應商可由社工後台即時切換**：讀 Supabase `app_settings.llm_provider`（短快取），
// 讀不到才退回環境變數 `LLM_PROVIDER`，再退回 'apikey'。改設定免重新部署 server。
//
// 檔名沿用 bedrock.js 以相容既有 import；實際是通用 LLM 介面。

// 預設供應商：把 AWS 抽掉，預設走 api key 版本。
const ENV_PROVIDER = process.env.LLM_PROVIDER || 'apikey';

// 部署層強制指定，**優先於後台設定**。
// 為什麼需要它：`app_settings.llm_provider` 是所有部署共用的一個值，但各部署的能力不同——
// Lambda 有 AWS 憑證卻沒有 XCC 金鑰，Render 則相反。後台選了對方才有的供應商時，
// 這一端只會靜默退回 mock（長輩會收到罐頭回覆，且不易察覺）。
// 設了這個變數就跳過後台查詢，讓「這台機器實際做得到什麼」說了算。不設＝維持原本行為。
const FORCE_PROVIDER = process.env.LLM_PROVIDER_FORCE || '';

// ---- apikey（OpenAI 相容）----
const API_BASE = process.env.LLM_API_BASE || 'https://llm-gateway.xcc.tw/v1';
const API_KEY = process.env.LLM_API_KEY || process.env.XCC_GATEWAY_PAT || '';
// XCC Gateway 用 x-bf-vk 標頭；一般 OpenAI 相容服務設 LLM_API_AUTH=bearer 走 Authorization。
const API_AUTH = process.env.LLM_API_AUTH || 'x-bf-vk';
const API_MODEL = process.env.LLM_API_MODEL || 'gpt-5.6-luna';
const API_FAST_MODEL = process.env.LLM_API_FAST_MODEL || API_MODEL;

// ---- bedrock（AWS，保留為選項）----
const REGION = process.env.AWS_REGION || 'us-west-2';
const GATEWAY = process.env.BEDROCK_GATEWAY || 'standard';
const MODEL_ID =
  process.env.BEDROCK_MODEL_ID || 'us.anthropic.claude-sonnet-4-5-20250929-v1:0';
const FAST_MODEL_ID =
  process.env.BEDROCK_FAST_MODEL_ID || 'us.anthropic.claude-haiku-4-5-20251001-v1:0';

// ---- 供應商即時切換（Supabase app_settings）----
const SB_URL = process.env.SUPABASE_URL;
const SB_KEY =
  process.env.SUPABASE_SERVICE_KEY ||
  process.env.SUPABASE_SECRET_KEY ||
  process.env.SUPABASE_ANON_KEY ||
  '';
let _sbPromise = null;
function supa() {
  // 供應商設定存在資料層，兩套環境各有自己的 app_settings（見 ../db.js）
  _sbPromise ??= import('../db.js')
    .then(({ createDbClient }) => createDbClient())
    .then((c) => c || null)
    .catch(() => null);
  return _sbPromise;
}

let _cache = { value: null, at: 0 };
const CACHE_MS = 10_000;

/** 目前生效的供應商（後台設定優先，短快取，容錯退回）。 */
export async function currentProvider() {
  const now = Date.now();
  if (_cache.value && now - _cache.at < CACHE_MS) return _cache.value;
  // 部署層強制指定：跳過後台查詢（見檔頭 FORCE_PROVIDER 說明）
  if (FORCE_PROVIDER) {
    _cache = { value: FORCE_PROVIDER, at: now };
    return FORCE_PROVIDER;
  }
  let p = ENV_PROVIDER;
  const sb = await supa();
  if (sb) {
    try {
      const { data } = await sb
        .from('app_settings')
        .select('value')
        .eq('key', 'llm_provider')
        .maybeSingle();
      if (data?.value) p = String(data.value);
    } catch {
      /* 讀不到就用 env 預設 */
    }
  }
  // apikey 但沒金鑰 → 退回 mock，避免 demo 直接掛掉
  if (p === 'apikey' && !API_KEY) p = 'mock';
  _cache = { value: p, at: now };
  return p;
}

/**
 * 呼叫 LLM。
 * @param {object} o
 * @param {string} o.system  system prompt
 * @param {string} o.user    使用者文字
 * @param {boolean} [o.json] 是否要求回 JSON（回傳已 parse 的物件）
 * @param {boolean} [o.fast] 是否用快模型（意圖分類用）
 * @param {function} [o.mock] mock 模式下的回覆產生器 (userText) => string|object
 */
export async function llm({ system, user, json = false, fast = false, mock }) {
  const provider = await currentProvider();

  if (provider === 'mock') {
    const out = mock ? mock(user) : '（mock）好的。';
    return json && typeof out === 'string' ? safeJson(out) : out;
  }

  if (provider === 'apikey') {
    try {
      return await apikeyLlm({ system, user, json, fast });
    } catch (e) {
      // 設定錯（模型不存在／金鑰無效）不讓整台 server 掛掉，退回 mock 並記錄。
      console.warn(`[llm] apikey 失敗，暫退回 mock：${e?.message || e}`);
      const out = mock ? mock(user) : '（mock）好的。';
      return json && typeof out === 'string' ? safeJson(out) : out;
    }
  }

  // bedrock（AWS）
  try {
    const client = await bedrockClient();
    const res = await client.messages.create({
      model: fast ? FAST_MODEL_ID : MODEL_ID,
      max_tokens: 512,
      system,
      messages: [{ role: 'user', content: user }],
    });
    const text = res?.content?.find((b) => b.type === 'text')?.text ?? '';
    return json ? safeJson(text) : text;
  } catch (e) {
    // Bedrock 失敗（如 workshop 一時憑證過期 403）不讓 /voice 整個掛掉 → 退回 mock/規則，
    // 讓「手動觸發的需求/緊急」仍能靠 rule 分類＋ruleItem 抽取品項寫進 Supabase。
    console.warn(`[llm] bedrock 失敗，暫退回 mock：${e?.message || e}`);
    const out = mock ? mock(user) : '（mock）好的。';
    return json && typeof out === 'string' ? safeJson(out) : out;
  }
}

async function apikeyLlm({ system, user, json, fast }) {
  const headers = { 'Content-Type': 'application/json' };
  if (API_AUTH === 'bearer') headers['Authorization'] = `Bearer ${API_KEY}`;
  else headers['x-bf-vk'] = API_KEY;

  const body = {
    model: fast ? API_FAST_MODEL : API_MODEL,
    max_tokens: 512,
    messages: [
      { role: 'system', content: system },
      { role: 'user', content: user },
    ],
  };
  if (json) body.response_format = { type: 'json_object' };

  const res = await fetch(`${API_BASE}/chat/completions`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`${res.status} ${(await res.text()).slice(0, 200)}`);
  }
  const data = await res.json();
  const text = data?.choices?.[0]?.message?.content ?? '';
  return json ? safeJson(text) : text;
}

let _client = null;
async function bedrockClient() {
  if (_client) return _client;
  const sdk = await import('@anthropic-ai/bedrock-sdk');
  const Client = GATEWAY === 'mantle' ? sdk.AnthropicBedrockMantle : sdk.AnthropicBedrock;
  _client = new Client({ awsRegion: REGION });
  return _client;
}

function safeJson(s) {
  try {
    const m = String(s).match(/\{[\s\S]*\}/);
    return m ? JSON.parse(m[0]) : {};
  } catch {
    return {};
  }
}

// ⚠️ 只暴露「非機密」欄位。絕不回傳 ENV_PROVIDER/API_KEY 等原始 env 值——
// 若有人誤把金鑰塞進 LLM_PROVIDER，回傳它等於公開洩漏（/health 是公開端點）。
export const llmInfo = {
  apiBase: API_BASE,
  apiModel: API_MODEL,
  apiAuth: API_AUTH,
  hasApiKey: Boolean(API_KEY),
  bedrockModel: MODEL_ID,
  region: REGION,
};
