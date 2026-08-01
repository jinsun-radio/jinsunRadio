// jinsun-voice — POST /voice 的 Lambda 版本。
//
// 與 cloud/prototype/src/server.js 的差異只有一處：
//   Emergency 的逾時階梯不再用行程內 setTimeout，改為 StartExecution 到 Step Functions，
//   executionArn 存進 DynamoDB 供後續「我沒事」解除時 StopExecution。
// 其餘 agents（intent / needs / conversation / device / memory）原封沿用。
//
// 契約完全不變（docs/requirements/hardware-integration.md §3）：
//   請求 { device_serial, text } | { device_serial, event }
//   回應 { reply, intent, action, lang }

import { SFNClient, StartExecutionCommand, StopExecutionCommand } from '@aws-sdk/client-sfn';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand } from '@aws-sdk/lib-dynamodb';

import { drain } from './shared/downlink.mjs';

import { classifyIntent } from './src/agents/intent.js';
import { createNeedsAgent } from './src/agents/needs.js';
import { createConversationAgent } from './src/agents/conversation.js';
import { createDeviceAgent } from './src/agents/device.js';
import { createMemoryAgent } from './src/agents/memory.js';
import { createDispatch } from './src/dispatch.js';
import { createElderLookup } from './src/elders.js';
import { currentProvider } from './src/llm/bedrock.js';
import {
  EMERGENCY_SCRIPT, EMERGENCY_WORDS, STANDDOWN_WORDS, firstHit,
} from './src/config/triggers.js';

const sfn = new SFNClient({});
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const LADDER_ARN = process.env.LADDER_ARN;
const SESSIONS = process.env.SESSIONS_TABLE;
const WAIT1_MS = Number(process.env.EMERGENCY_WAIT1_MS) || 8000;
const WAIT2_MS = Number(process.env.EMERGENCY_WAIT2_MS) || 12000;

// ASR 上游（POST /asr 用）。與 Supabase 版 whisper Edge Function 同一組預設值。
const ASR_ENDPOINT = process.env.ASR_ENDPOINT || 'https://llm-gateway.xcc.tw/v1/audio/transcriptions';
const ASR_MODEL = process.env.ASR_MODEL || 'paulpengtw/faster-whisper-Breeze-ASR-26';
const ASR_PAT = process.env.XCC_GATEWAY_PAT;

const dispatch = createDispatch();
const memory = createMemoryAgent();
const needs = createNeedsAgent({ createSupply: (o) => dispatch.createSupply(o) });
const conversation = createConversationAgent({ memory });
const device = createDeviceAgent();
const elders = createElderLookup();

// 硬體按鍵／相機事件 → 對應觸發語句（與 server.js 的 EVENT_TEXT 相同）
const EVENT_TEXT = { sos: '救命', fall: '我跌倒了', fall_suspected: '我跌倒了' };
// 活動類事件：不走問診鏈路，回 200 但無 reply
const ACTIVITY_EVENTS = new Set(['activity_report', 'inactivity_suspected']);

const json = (code, obj) => ({
  statusCode: code,
  headers: { 'content-type': 'application/json; charset=utf-8' },
  body: JSON.stringify(obj),
});

async function getSession(elderKey) {
  if (!SESSIONS) return null;
  const r = await ddb.send(new GetCommand({ TableName: SESSIONS, Key: { elderKey } }));
  return r.Item || null;
}

/** 起始急救對話：同步回 onStart，逾時階梯交給 Step Functions。 */
async function startEmergency({ elderKey, deviceSerial, elderId, text, keyword, passive }) {
  // 先讓三端知道「AI 正在確認」——不等 20 秒。寫失敗只記 log，不可中斷升級鏈路。
  let eventId;
  try {
    eventId = await dispatch.openAsking({ elderKey, deviceSerial, elderId, keyword, transcript: text });
  } catch (e) {
    console.error('[emergency] 寫「AI 詢問中」失敗，繼續走升級鏈路：', e?.message || e);
  }

  const lang = await elders.langOf(deviceSerial || elderKey);
  const reply = EMERGENCY_SCRIPT.onStart(keyword, { passive });

  // T0 = 長輩即將聽到第一句的時刻。用絕對時間戳，讓轉場開銷不累積（見 aws-architecture.md §4.1）
  const T0 = Date.now();
  const { executionArn } = await sfn.send(new StartExecutionCommand({
    stateMachineArn: LADDER_ARN,
    input: JSON.stringify({
      deviceSerial: deviceSerial || elderKey,
      // ⚠️ 一律用 ?? null，不可讓值是 undefined —— JSON.stringify 會直接把該 key 丟掉，
      // 而 ASL 的 `elderId.$: "$.elderId"` 找不到路徑就會讓整條 execution 失敗（States.Runtime）。
      // 裝置依契約不送 elder_id（靠 device_serial 反查），所以這裡「一定」是 undefined。
      elderId: elderId ?? null,
      eventId: eventId ?? null,
      lang: lang ?? 'mandarin',
      // Escalate 那步要用這兩個欄位把「AI 詢問中」那列升級掉並開派遣單
      keyword: keyword ?? '救命',
      transcript: text ?? '',
      step1At: new Date(T0 + WAIT1_MS).toISOString(),
      escalateAt: new Date(T0 + WAIT1_MS + WAIT2_MS).toISOString(),
      script: { step1: EMERGENCY_SCRIPT.ladder[0].say },
    }),
  }));

  if (SESSIONS) {
    await ddb.send(new PutCommand({
      TableName: SESSIONS,
      Item: {
        elderKey, executionArn, eventId, deviceSerial, keyword,
        startedAt: new Date(T0).toISOString(),
        expiresAt: Math.floor(T0 / 1000) + 3600,   // TTL：一小時後自動清
      },
    }));
  }
  return { reply, lang, action: { type: 'emergency_asking', executionArn } };
}

/** 長輩說「我沒事」→ 停掉整條升級鏈（跨行程有效，取代 clearTimeout）。 */
async function standdown(session) {
  try {
    await sfn.send(new StopExecutionCommand({
      executionArn: session.executionArn, cause: 'elder_standdown',
    }));
  } catch (e) {
    console.warn('[emergency] StopExecution 失敗（可能已結束）：', e?.message || e);
  }
  if (SESSIONS) await ddb.send(new DeleteCommand({ TableName: SESSIONS, Key: { elderKey: session.elderKey } }));
  return { reply: EMERGENCY_SCRIPT.onStanddown, action: { type: 'emergency_standdown' } };
}

/**
 * Step Functions 的 Escalate 步驟：20 秒逾時到了，真的開派遣單。
 *
 * 為什麼由這支 Lambda 兼任而不是另開一支：escalateEmergency 需要 Supabase 憑證，
 * 而這支已經有了。多一支就多一份 secret 要輪替、多一個 IAM role 要維護。
 * 它只負責「寫資料庫 + 決定要說什麼」，實際 publish 交給 jinsun-speak（權限邊界分開）。
 */
async function handleEscalate(input) {
  const { deviceSerial, elderId, eventId, keyword, transcript } = input;
  const result = await dispatch.escalateEmergency({
    deviceSerial, elderId, keyword: keyword || '救命', transcript, eventId,
  });
  // ⚠️ escalateEmergency 目前不回傳 etaMinutes（見 dispatch.js 註解），
  // 沒有就用通用安撫語 —— 絕不可捏造一個「大約 N 分鐘」的假數字給長輩。
  const eta = result?.etaMinutes;
  const text = eta
    ? `別擔心，志工已經在路上，大約 ${eta} 分鐘到，我會一直陪著您。`
    : EMERGENCY_SCRIPT.onEscalated;
  console.log(`[escalate] serial=${deviceSerial} event=${result?.eventId} task=${result?.taskId}`);
  return { text, eventId: result?.eventId ?? null, taskId: result?.taskId ?? null };
}

/**
 * POST /asr — 語音轉文字（上游：XCC Gateway 的 Breeze ASR，台灣國語／台語優化）。
 *
 * 請求 { audio_base64, filename?, mime?, prompt?, language? } → 回應 { text }。
 * 形狀刻意與 cloud/supabase/functions/whisper 一模一樣：前端 transcribeAudio 只有一份實作。
 *
 * 金鑰只存在 Lambda 環境變數，永遠不進前端封包——所以才需要這層代理，
 * 而不是讓瀏覽器直接打 Gateway。
 */
async function handleAsr(event) {
  if (!ASR_PAT) return json(500, { error: 'XCC_GATEWAY_PAT not configured' });

  let payload = {};
  try {
    payload = JSON.parse(
      event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf-8') : (event.body || '{}'),
    );
  } catch {
    return json(400, { error: 'invalid_json_body' });
  }

  const { audio_base64, filename, mime, prompt, language } = payload;
  if (!audio_base64) return json(400, { error: 'missing_audio_base64' });

  let bytes;
  try {
    bytes = Buffer.from(audio_base64, 'base64');
  } catch {
    return json(400, { error: 'bad_base64' });
  }
  if (bytes.length === 0) return json(400, { error: 'empty_audio' });

  const form = new FormData();
  form.append('file', new Blob([bytes], { type: mime || 'application/octet-stream' }), filename || 'audio.wav');
  form.append('model', ASR_MODEL);
  form.append('language', language || 'zh');
  form.append('response_format', 'json');
  if (prompt) form.append('prompt', prompt);

  let resp;
  try {
    // Lambda timeout 是 30 秒，這裡抓 25 秒——寧可自己回 502 說清楚，
    // 也不要讓整支 Lambda 被砍掉、前端只看到一個沒有 body 的 502。
    resp = await fetch(ASR_ENDPOINT, {
      method: 'POST',
      headers: { 'x-bf-vk': ASR_PAT },   // XCC Gateway 用 x-bf-vk 權杖，不是 Bearer
      body: form,
      signal: AbortSignal.timeout(25_000),
    });
  } catch (e) {
    console.error('[asr] upstream unreachable:', e?.message || e);
    return json(502, { error: 'upstream_unreachable', detail: String(e?.message || e) });
  }

  if (!resp.ok) {
    const detail = await resp.text();
    console.error(`[asr] upstream ${resp.status}: ${detail}`);
    return json(502, { error: 'asr_failed', status: resp.status, detail });
  }

  const data = await resp.json();
  const text = String(data.text ?? '').trim();
  console.log(`[asr] ${bytes.length}B → "${text}"`);
  return json(200, { text });
}

export const handler = async (event) => {
  // Step Functions 直接呼叫（非 API Gateway 事件）
  if (event?.__sfn === 'escalate') return handleEscalate(event);

  const method = event.requestContext?.http?.method || 'POST';
  const path = event.rawPath || '/voice';

  if (method === 'GET' && path === '/health') {
    // dispatch.mode 是懶惰 getter，要先 ready() 探測一次連線才會翻成 live
    // （server.js 在啟動時做這件事；Lambda 沒有啟動階段，所以在這裡做）
    const dispatchMode = await dispatch.ready();
    const provider = await currentProvider();
    return json(200, { ok: true, llm: provider, dispatch: dispatchMode, ladder: Boolean(LADDER_ARN) });
  }
  // CORS preflight。API Gateway 的自動 preflight 回應只在「沒有任何路由 match」時才啟動，
  // 而本 API 有一條 $default 路由（給 POST /voice 用）會 match 掉所有請求——包含
  // 三端瀏覽器對 /data/* 發的 OPTIONS。落到這裡若回 404，瀏覽器會判定 preflight
  // 失敗（規定必須 2xx）而根本不送出真正的請求；curl 測不到這條路徑，症狀是
  // 「API 用 curl 一切正常，網頁就是連不上」。CORS 標頭由 API Gateway 自己補。
  if (method === 'OPTIONS') return { statusCode: 204 };

  // 下行（模擬器／對測通道）：admin/?sim=1 的長輪詢。真韌體走 IoT Core MQTT push，
  // 不會打這條。對應 server.js:180 的 GET /commands，語義刻意保持一致。
  //
  // 為什麼要 hold：hardware_sim.dart 的輪詢迴圈**成功時沒有任何延遲**，靠 server
  // hold 住來節流。若這裡立刻回空陣列，模擬器會變成全速打 API Gateway 的忙迴圈。
  // hold 上限抓 10 秒（voice 的 Lambda timeout 是 30 秒，留足餘裕）。
  if (method === 'GET' && path === '/commands') {
    const serial = event.queryStringParameters?.device_serial;
    if (!serial) return json(400, { error: 'need device_serial' });
    const deadline = Date.now() + 10_000;
    for (;;) {
      const commands = await drain(serial);
      if (commands.length) return json(200, { commands });
      if (Date.now() >= deadline) return json(200, { commands: [] });
      await new Promise((r) => setTimeout(r, 700));
    }
  }

  // 語音轉文字代理。長輩端網頁（apps/elder_app）錄完音打這裡拿逐字稿，再自己送 POST /voice。
  // 與 Supabase 版的 whisper Edge Function 同契約（cloud/supabase/functions/whisper），
  // 兩套環境的前端共用 BackendClient.transcribeAudio 一支介面。
  //
  // 為什麼在這支 Lambda 而不是新開一支：它已經在 $default 路由後面、已經是前端信任的網域，
  // 多一支就多一個 IAM role 與一份 secret 要維護，而這裡只是「換個標頭轉發」。
  if (method === 'POST' && path === '/asr') return handleAsr(event);

  if (method !== 'POST' || path !== '/voice') return json(404, { error: 'not found' });

  let body = {};
  try { body = JSON.parse(event.body || '{}'); } catch { /* 保持空物件 */ }
  const { device_serial, elder_id, text, event: evt } = body;

  if (!device_serial && !elder_id) {
    return json(400, { error: 'need text|event and device_serial (or elder_id)' });
  }

  // 活動類事件：僅寫資料層，不產生語音回覆、不派遣
  if (ACTIVITY_EVENTS.has(evt)) {
    console.log(`[voice] activity event=${evt} serial=${device_serial}`);
    return json(200, { ok: true });
  }

  const utter = text || EVENT_TEXT[evt];
  if (!utter) return json(400, { error: 'need text|event and device_serial (or elder_id)' });

  const elderKey = elder_id || device_serial;
  const immediate = evt === 'sos';                       // 實體 SOS 鍵：不問診、立刻升級
  const passive = evt === 'fall' || evt === 'fall_suspected';  // 相機偵測：長輩沒開口，安撫語不可謊稱聽到

  try {
    memory.remember(elderKey, '');

    // 1) 急救對話進行中？先看是不是解除
    const session = await getSession(elderKey);
    if (session && firstHit(utter, STANDDOWN_WORDS)) {
      const r = await standdown({ ...session, elderKey });
      const lang = await elders.langOf(device_serial || elderKey);
      console.log(`[voice] "${utter}" → standdown`);
      return json(200, { ...r, intent: 'emergency', lang });
    }

    // 2) 分類
    const { intent, via } = await classifyIntent(utter);

    // 3) 分派
    if (intent === 'emergency') {
      const kw = firstHit(utter, EMERGENCY_WORDS) || '救命';

      if (immediate) {
        // SOS 鍵：跳過問診階梯，直接升級
        const result = await dispatch.escalateEmergency({
          elderKey, deviceSerial: device_serial, elderId: elder_id, keyword: kw, transcript: utter,
        });
        const eta = result?.etaMinutes;
        const reply = eta
          ? `別擔心，志工已經在路上，大約 ${eta} 分鐘到，我會一直陪著您。`
          : EMERGENCY_SCRIPT.onEscalated;
        const lang = await elders.langOf(device_serial || elderKey);
        console.log(`[voice] "${utter}" (SOS 立即升級) → intent=emergency`);
        return json(200, { reply, intent, action: { type: 'emergency_escalated', via }, lang });
      }

      const r = await startEmergency({
        elderKey, deviceSerial: device_serial, elderId: elder_id, text: utter, keyword: kw, passive,
      });
      console.log(`[voice] "${utter}" → intent=emergency ladder=started`);
      return json(200, { reply: r.reply, intent, action: { ...r.action, via }, lang: r.lang });
    }

    let r;
    if (intent === 'need') r = await needs.handle({ elderKey, deviceSerial: device_serial, elderId: elder_id, text: utter });
    else if (intent === 'device') r = await device.handle({ text: utter });
    else r = await conversation.handle({ elderKey, text: utter });

    const lang = await elders.langOf(device_serial || elderKey);
    console.log(`[voice] "${utter}" → intent=${intent} via=${via}`);
    return json(200, { reply: r.reply, intent: intent === 'general' ? 'general' : intent, action: { ...r.action, via }, lang });
  } catch (e) {
    console.error(e);
    return json(500, { error: String(e?.message || e) });
  }
};
