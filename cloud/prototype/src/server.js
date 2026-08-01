// HTTP＋MQTT 入口 —— 硬體對接：
//
//   ① 上行（接收）  POST /voice     硬體把 ASR 文字／按鍵事件送上來，同步拿到「立即要播的話」
//   ② 下行（push）  MQTT            裝置訂閱 jinsun/{serial}/cmd，server 有話要說就 publish
//                                   （急救逾時後的話、志工 ETA、裝置控制…）；broker 內嵌（aedes）
//   ②' 下行（模擬） GET  /commands  長輪詢＝瀏覽器模擬控制台 sim.html 與 curl 對測專用通道，
//                                   真韌體走 MQTT；enqueue 扇出、兩通道都會收到
//
// 韌體迴圈：開機 → 連上 WiFi → 連 broker 訂閱 jinsun/{serial}/cmd；每次喚醒+ASR 就
// POST /voice 並播回應。正式版對應 API Gateway + Lambda（上行）、AWS IoT Core（下行）。

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createOrchestrator } from './orchestrator.js';
import { createDownlink } from './downlink.js';
import { createMqttDownlink, createFanoutDownlink } from './mqtt.js';
import { createProgressWorker } from './progress.js';
import { createTravelSimulator } from './travel.js';
import { createElderLookup } from './elders.js';
import { llmInfo, currentProvider } from './llm/bedrock.js';

const PORT = process.env.PORT || 8787;

// 模擬硬體控制台：掛在「不好猜、不外連」的隱藏路徑，demo 用、評審不會撞到。
// 可用 SIM_PATH 覆蓋成你自己的密路徑。
const SIM_PATH = process.env.SIM_PATH || '/__sim-4f9a2c';
const SIM_FILE = join(dirname(fileURLToPath(import.meta.url)), '..', 'public', 'sim.html');

const longpoll = createDownlink();
const mqtt = await createMqttDownlink();
// enqueue 扇出：MQTT publish（真裝置）＋長輪詢佇列（sim.html／curl 對測），兩通道獨立投遞
const downlink = createFanoutDownlink(mqtt, longpoll);
const elders = createElderLookup();

// speak：Emergency Agent 逾時階梯／安撫要下發給裝置 → 扇出下行（MQTT push＋模擬器佇列）。
// 帶上長輩偏好語言，裝置端據此選國語／台語語音。
const orch = createOrchestrator({
  speak: async (elderKey, text) => {
    const lang = await elders.langOf(elderKey);
    downlink.enqueue(elderKey, { type: 'speak', text, lang });
  },
});

// 進度播報 worker：志工接單／接近（GPS ≤250m）／抵達 → 收音機主動念（走同一個扇出下行）。
const progress = createProgressWorker({ downlink });

// 志工移動模擬（demo）：接單後把志工座標沿路內插寫回資料庫 → 家屬地圖像 Uber 一樣看移動。
const travel = createTravelSimulator({});

// 硬體按鍵／相機事件 → 對應觸發語句（走同一條 orchestrator 管線）
const EVENT_TEXT = { sos: '救命', fall: '我跌倒了', fall_suspected: '我跌倒了' };

function readJson(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      try {
        resolve(JSON.parse(body || '{}'));
      } catch {
        resolve({});
      }
    });
  });
}

function parseQuery(url) {
  const q = url.split('?')[1] || '';
  return Object.fromEntries(new URLSearchParams(q));
}

/// 代打 ATEN TTS（與韌體 requestTTS 同格式：multipart 帶 text），回傳絕對 WAV url。
/// 依 lang 帶語音旗標；ATEN 需要 Referer 才不會被閘門擋。打不通回空字串。
const ATEN_TTS_URL =
  process.env.ATEN_TTS_URL || 'https://kws.oaselab.org/nutntweng/tts/aten/';
async function synthAten(text, lang) {
  if (typeof fetch !== 'function' || typeof FormData !== 'function') return '';
  const form = new FormData();
  form.append('text', text);
  form.append('lang', lang === 'taigi' ? 'taigi' : 'mandarin');
  const r = await fetch(ATEN_TTS_URL, {
    method: 'POST',
    headers: {
      Referer: 'https://kws.oaselab.org/nutntweng/',
      Accept: 'application/json',
    },
    body: form,
  });
  const body = await r.text();
  let j;
  try {
    j = JSON.parse(body);
  } catch {
    return '';
  }
  if (j && j.status === 'Success' && j.url) return j.url;
  return '';
}

const server = createServer(async (req, res) => {
  // CORS：讓社工後台（另一個 web app）內嵌的「硬體模擬」頁能跨埠呼叫本 server。
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'content-type');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  const send = (code, obj) => {
    res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(obj));
  };

  if (req.method === 'GET' && req.url === '/health') {
    // provider = 目前生效的供應商（社工後台可即時切換，見 app_settings.llm_provider）
    const provider = await currentProvider();
    return send(200, {
      ok: true,
      llm: { provider, ...llmInfo },
      dispatch: orch.dispatch.mode,
      mqtt: mqtt.mode,
    });
  }

  // 雲端 TTS 代理：長輩端網頁沒法直接打 ATEN（CORS＋Referer 閘門），由 server 代打，
  // 回傳可跨源播放的 WAV url。lang=mandarin/taigi（台語能否發音看 ATEN 支不支援）。
  // 打不通就回 502，前端會退回瀏覽器語音（國語），不會沒聲音。
  if (req.method === 'POST' && req.url.split('?')[0] === '/tts') {
    const b = await readBody(req);
    const text = (b.text || '').toString().trim();
    const lang = (b.lang || 'mandarin').toString();
    if (!text) return send(400, { error: 'no text' });
    try {
      const url = await synthAten(text, lang);
      if (!url) return send(502, { error: 'tts upstream unavailable' });
      return send(200, { url, lang });
    } catch (e) {
      return send(502, { error: String((e && e.message) || e) });
    }
  }

  // 隱藏的模擬硬體控制台（demo 用）
  if (req.method === 'GET' && req.url.split('?')[0] === SIM_PATH) {
    try {
      const html = await readFile(SIM_FILE);
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'x-robots-tag': 'noindex' });
      return res.end(html);
    } catch {
      return send(404, { error: 'not found' });
    }
  }

  // ① 上行：硬體 → server
  if (req.method === 'POST' && req.url === '/voice') {
    const { device_serial, elder_id, text, event } = await readJson(req);
    const utter = text || EVENT_TEXT[event];
    if (!utter || (!device_serial && !elder_id)) {
      return send(400, { error: 'need text|event and device_serial (or elder_id)' });
    }
    try {
      // 實體 SOS 鍵：不問診、立刻升級派遣
      const immediate = event === 'sos';
      // 相機／被動聲學偵測的跌倒（長輩沒開口）→ 安撫語不可謊稱「我聽到您說…」
      const passive = event === 'fall' || event === 'fall_suspected';
      const out = await orch.handle({ deviceSerial: device_serial, elderId: elder_id, text: utter, immediate, passive });
      out.lang = await elders.langOf(device_serial); // 同步回覆也帶語言，硬體 TTS 據此選語音
      console.log(`[voice] "${utter}"${immediate ? ' (SOS 立即升級)' : ''} → intent=${out.intent} lang=${out.lang}`);
      // reply 同步回給硬體立刻 TTS；action.command（如 volume_up）也回，由硬體執行
      return send(200, out);
    } catch (e) {
      console.error(e);
      return send(500, { error: String(e?.message || e) });
    }
  }

  // ②' 下行（模擬器／對測通道）：sim.html 與 curl 用的長輪詢；真韌體走 MQTT push
  if (req.method === 'GET' && req.url.startsWith('/commands')) {
    const { device_serial } = parseQuery(req.url);
    if (!device_serial) return send(400, { error: 'need device_serial' });
    const commands = await downlink.pull(device_serial);
    return send(200, { commands }); // 例：[{type:'speak',text:'…'},{type:'device',command:'volume_up'}]
  }

  send(404, { error: 'not found' });
});

server.listen(PORT, async () => {
  const mode = await orch.dispatch.ready();
  const _p = await currentProvider();
  console.log(`金孫語音 Agent server on :${PORT}  (llm=${_p}, dispatch=${mode})`);
  if (mode !== 'live') {
    console.log('⚠️  dispatch=dryrun：只印 log、不會寫進 Supabase → 三端不會亮。');
    console.log('    要讓三端亮：設 SUPABASE_SERVICE_KEY（secret key，非 anon）並 npm i @supabase/supabase-js');
  } else {
    console.log('✅ dispatch=live：緊急/需求會寫進 Supabase，家屬/志工/社工三端即時亮起。');
  }
  const progressMode = await progress.start();
  if (progressMode === 'live') {
    console.log('📢 進度播報 live：志工接單/接近門口/抵達 → 收音機主動念（依長輩偏好語言）。');
  }
  const travelMode = await travel.start();
  if (travelMode === 'live') {
    console.log('🛵 志工移動模擬 live：接單後家屬地圖即時看到志工沿路移動＋ETA 倒數（Uber 式）。');
  }
  if (mqtt.mode === 'live') {
    console.log(`📡 MQTT=live：broker on :${mqtt.port}，下行 push topic jinsun/{serial}/cmd（QoS 1、LWT 上下線）。`);
  } else if (mqtt.mode === 'client') {
    console.log(`📡 MQTT=client：外部 broker ${mqtt.url}，下行 push topic jinsun/{serial}/cmd（QoS 1）。裝置請連同一顆 broker。`);
  } else {
    console.log('⚠️  MQTT=off：下行只剩長輪詢（模擬器通道）。要啟用：npm i aedes（內嵌）或設 MQTT_URL＋npm i mqtt（外部 broker）。');
  }
  console.log(`🔧 模擬硬體控制台（隱藏、勿給評審）： http://localhost:${PORT}${SIM_PATH}`);
  console.log(`上行：curl -s localhost:${PORT}/voice -d '{"device_serial":"JS-0001","event":"sos"}'`);
  if (mqtt.mode === 'client') {
    console.log(`下行（真裝置/MQTT）：mosquitto_sub -L '${mqtt.url}/jinsun/JS-0001/cmd'`);
  } else {
    console.log(`下行（真裝置/MQTT）：mosquitto_sub -h localhost -p ${mqtt.port} -t 'jinsun/JS-0001/cmd' -v`);
  }
  console.log(`下行（模擬器/對測）：curl -s "localhost:${PORT}/commands?device_serial=JS-0001"`);
});
