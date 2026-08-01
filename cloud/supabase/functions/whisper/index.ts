// 金孫收音機 — 語音輸入轉文字 Edge Function（ASR 代理）
//
// 用途：家屬↔志工聊天的「語音輸入」。前端錄音後把音檔（base64）丟給這支，
// 這支轉呼叫上游 ASR（預設 XCC Gateway 的 Breeze ASR，台灣中文/台語優化），
// 回傳純文字讓前端填入輸入框，使用者確認後再送出。
//
// 為什麼要有這支代理：上游金鑰是機密，只能存在後端 secret，
// 永遠不能放進 Flutter 前端封包。前端只認得 Supabase anon key。
//
// 上游（可用環境變數覆寫）：
//   ASR_ENDPOINT   預設 https://llm-gateway.xcc.tw/v1/audio/transcriptions
//   ASR_MODEL      預設 paulpengtw/faster-whisper-Breeze-ASR-26
//   XCC_GATEWAY_PAT  Gateway 存取權杖（送 x-bf-vk 標頭）  ← 必填
//
// 部署：
//   supabase functions deploy whisper --project-ref <ref>
//   supabase secrets set XCC_GATEWAY_PAT=... --project-ref <ref>
//   （可選）supabase secrets set ASR_MODEL=... ASR_ENDPOINT=... --project-ref <ref>
//
// 注意：這支只處理「使用者主動」的聊天語音輸入，與長輩端裝置的隱私邊界無關
// （裝置端影音永不上雲；見 docs/architecture.md）。

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

const ASR_ENDPOINT = Deno.env.get('ASR_ENDPOINT') ??
  'https://llm-gateway.xcc.tw/v1/audio/transcriptions';
const ASR_MODEL = Deno.env.get('ASR_MODEL') ??
  'paulpengtw/faster-whisper-Breeze-ASR-26';
const XCC_GATEWAY_PAT = Deno.env.get('XCC_GATEWAY_PAT');

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// base64 → bytes（前端用 dart:convert base64Encode 送上來）
function decodeBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }
  if (!XCC_GATEWAY_PAT) {
    return json({ error: 'XCC_GATEWAY_PAT not configured' }, 500);
  }

  let payload: {
    audio_base64?: string;
    filename?: string;
    mime?: string;
    // 提示詞：專有名詞、常用詞可放這，提高辨識率（選填）
    prompt?: string;
    // 語言碼；預設 zh（中文，含國台語音）。
    language?: string;
  };
  try {
    payload = await req.json();
  } catch (_) {
    return json({ error: 'invalid_json_body' }, 400);
  }

  const { audio_base64, filename, mime, prompt, language } = payload;
  if (!audio_base64) {
    return json({ error: 'missing_audio_base64' }, 400);
  }

  let bytes: Uint8Array;
  try {
    bytes = decodeBase64(audio_base64);
  } catch (_) {
    return json({ error: 'bad_base64' }, 400);
  }
  if (bytes.length === 0) {
    return json({ error: 'empty_audio' }, 400);
  }

  const form = new FormData();
  const blob = new Blob([bytes], { type: mime ?? 'application/octet-stream' });
  form.append('file', blob, filename ?? 'audio.webm');
  form.append('model', ASR_MODEL);
  form.append('language', language ?? 'zh');
  form.append('response_format', 'json');
  if (prompt) form.append('prompt', prompt);

  let resp: Response;
  try {
    resp = await fetch(ASR_ENDPOINT, {
      method: 'POST',
      // XCC Gateway 用 x-bf-vk 權杖（非 Bearer）
      headers: { 'x-bf-vk': XCC_GATEWAY_PAT },
      body: form,
    });
  } catch (e) {
    return json({ error: 'upstream_unreachable', detail: String(e) }, 502);
  }

  if (!resp.ok) {
    const detail = await resp.text();
    return json({ error: 'asr_failed', status: resp.status, detail }, 502);
  }

  const data = await resp.json();
  const text = (data.text ?? '').toString().trim();
  return json({ text });
});
