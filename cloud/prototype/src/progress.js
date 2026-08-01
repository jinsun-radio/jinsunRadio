// 進度播報 Worker —— 讓收音機「主動」念出志工派遣進度。
//
// 為什麼需要它：志工接單／抵達是在志工 App 端寫進 Supabase 的，語音 Agent server 的
// 同步 /voice 迴圈收不到這個變化。這個 worker 訂閱 dispatch_tasks 的 Realtime 狀態變化，
// 在志工「接單(accepted)」「抵達(arrived)」時，反查長輩的 device_serial 與偏好語言，
// 透過下行通道 downlink 主動下發 speak 指令 → 收音機念出「志工○○大約○分鐘到，您再等一下喔」。
// 這補上了「感知→決策→行動→回報」閉環裡，長輩端唯一的主動出口。
//
// 另外訂閱 volunteers 的座標變化（志工 App 的 LocationPublisher 上報的真實 GPS）：
// 志工走到長輩家附近（預設 250 公尺）就先播一句「快到門口了，等一下會敲門」。
// 為什麼要這句：長輩獨居、聽到敲門會怕，也常沒聽見。arrived 那句是「人已經在門口」才念，
// 對行動慢的長輩太晚；提早幾十秒預告，長輩有時間走到門邊、也知道來的是我們派的人。
//
// 正式對應：DynamoDB Streams / EventBridge → Lambda → IoT Core 下發。

import { createDbClient } from './db.js';

const URL = process.env.SUPABASE_URL || 'https://ykfxmoubynnbhnburawl.supabase.co';
const KEY =
  process.env.SUPABASE_SERVICE_KEY ||
  process.env.SUPABASE_SECRET_KEY ||
  process.env.SUPABASE_ANON_KEY ||
  '';

/**
 * 進度播報開關（預設開）。設 `PROGRESS_WORKER=off` 可讓這台 server 不參與播報。
 *
 * 為什麼需要它：本 worker 是「同一個資料庫只能有一個」的角色——它訂閱 dispatch_tasks
 * 變化後主動對收音機發話。若同時有兩台 server 連同一個 Supabase（例如 Render 保底環境
 * 與 AWS 正式環境並存），兩邊都會反應同一筆變化，各自往自己的 broker 發，且各自維護
 * 去重狀態、互不知情。備援那台請設 off，只保留 /voice 的能力。
 */
const PROGRESS_ENABLED = (process.env.PROGRESS_WORKER || 'on').toLowerCase() !== 'off';

/** 「快到門口了」的播報距離門檻（公尺）。機車 18km/h 走 250m 約 50 秒，夠長輩走到門邊。 */
const APPROACH_METERS = Number(process.env.APPROACH_METERS) || 250;
/** 到場門檻（公尺）——與志工 App 的 isNearbyMeters 預設一致。這麼近就別再預告，直接等「到囉」。 */
const ARRIVE_METERS = Number(process.env.ARRIVE_METERS) || 60;
/**
 * 「路上每 N 分鐘再報一次進度」的間隔（毫秒），預設 10 分鐘。
 * 收音機語音只有三個時機：①出發 ②路上每 10 分鐘 ③到門口開門。其餘一律不下發，避免一直發 MQTT。
 */
const ENROUTE_INTERVAL_MS =
  Number(process.env.ENROUTE_SPEAK_MS) || 10 * 60 * 1000;

/** 兩座標的直線距離（公尺）。與 Dart 端 models.dart 的 haversine 同一套算法。 */
export function distanceMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(lat2 - lat1);
  const dLng = rad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * 依狀態產生要念給長輩的話。
 * **一律用正常中文（國語）書寫**；台語不在這裡翻——由裝置端 TTS 依下發的 lang
 * 自行把中文念成台語（見 hardware-integration.md）。所以文字內容與 lang 無關，
 * lang 只當作裝置端選語音的旗標。
 * 不使用長輩稱謂（專案已定案移除），一律以「您」相稱。
 */
export function speakText(status, { name, eta, kind } = {}) {
  const who = name ? `志工${name}` : '志工';
  // ③ 開門：到門口了（approaching 由 GPS 預告、arrived 由狀態，兩者擇一播一次即可）。
  if (status === 'arrived' || status === 'approaching') {
    if (kind === 'supply') {
      return `${who}到您家門口了，等一下會把東西送進來，您安心休息就好。`;
    }
    // 緊急（疑似跌倒/SOS）：先叫長輩「不要移動」——若剛跌倒，亂動可能加重傷勢，
    // 讓志工到場先扶、先看，比長輩自己爬起來安全。
    return `${who}已經到門口了！請先不要移動，馬上進來看您。`;
  }
  // ② 路上每 10 分鐘：只報還要多久，不加安撫贅句。
  if (status === 'enroute') {
    if (!eta) return `${who}還在路上，正在趕過來，您再等一下。`;
    return `${who}還在路上，大約還要${eta}分鐘到，您再等一下。`;
  }
  // ① 出發（accepted）：接單當下報一次。
  if (!eta) {
    return `${who}出發了，正在趕過來，您在家裡等一下。`;
  }
  if (kind === 'supply') {
    return `${who}出發了，大約${eta}分鐘把東西送到，您在家等一下。`;
  }
  return `${who}出發了，大約${eta}分鐘到，您在家裡等他就好。`;
}

/**
 * @param {object} deps
 * @param {{enqueue:(serial:string,cmd:object)=>void}} deps.downlink 下行佇列（與 server 共用同一個）
 * @param {(msg:string)=>void} [deps.log]
 * @param {object} [deps.client] 預先注入的 Supabase client（測試用；正式由 start() 自己建）
 */
export function createProgressWorker({ downlink, log = console.log, client = null }) {
  let sb = client;
  const announced = new Set(); // `${taskId}:${milestone}` 去重，避免同一時機重複播
  const enroute = new Map(); // taskId -> interval timer（路上每 10 分鐘）

  function stopEnroute(taskId) {
    const timer = enroute.get(taskId);
    if (timer) clearInterval(timer);
    enroute.delete(taskId);
  }

  // ③ 開門：approaching（GPS 預告）或 arrived（狀態）擇一，只播一次，並停掉「路上」定時。
  async function speakDoor(taskId, elderId, name, kind) {
    const key = `${taskId}:door`;
    if (announced.has(key)) return;
    announced.add(key);
    stopEnroute(taskId);
    const info = await elderInfo(elderId);
    if (!info) return;
    const text = speakText('arrived', { name, kind });
    downlink.enqueue(info.deviceSerial, { type: 'speak', text, lang: info.lang });
    log(`[progress] → ${info.deviceSerial}（${info.lang}）開門：「${text}」`);
  }

  async function elderInfo(elderId) {
    if (!elderId) return null;
    // 每次即時查，家屬在 App 改語言後立刻生效（低頻）。
    // select * 以相容尚未加 preferred_lang 欄位的舊 schema（fallback mandarin）
    const { data, error } = await sb.from('elders').select('*').eq('id', elderId).single();
    if (error || !data?.device_serial) return null;
    return {
      deviceSerial: data.device_serial,
      lang: data.preferred_lang || 'mandarin',
      lat: data.lat || 0,
      lng: data.lng || 0,
    };
  }

  // 收到一列 dispatch_tasks 變化 → 只在三個時機下發語音：出發 / 路上每10分鐘 / 開門。
  async function onTask(row) {
    const status = row?.status;
    const taskId = row?.id;
    if (!taskId) return;

    // 到場：播「開門」，並停掉路上定時。
    if (status === 'arrived') {
      await speakDoor(taskId, row.elder_id, row.assignee_name, row.kind);
      return;
    }
    // 結案／取消：清定時，不再出聲。
    if (status === 'resolved' || status === 'pending') {
      stopEnroute(taskId);
      return;
    }
    if (status !== 'accepted') return;

    // ① 出發：只在「首次進入 accepted」播一次（之後 eta 更新的 UPDATE 都被去重擋掉，不會一直重播）。
    const key = `${taskId}:depart`;
    if (announced.has(key)) return;
    announced.add(key);

    const info = await elderInfo(row.elder_id);
    if (!info) {
      log(`[progress] 找不到 elder=${row.elder_id} 的 device_serial，略過`);
      return;
    }
    const departText = speakText('accepted', {
      name: row.assignee_name,
      eta: row.eta_minutes,
      kind: row.kind,
    });
    downlink.enqueue(info.deviceSerial, { type: 'speak', text: departText, lang: info.lang });
    log(`[progress] → ${info.deviceSerial}（${info.lang}）出發：「${departText}」`);

    // ② 路上每 10 分鐘：定時重查最新 ETA 再報一次；狀態已非 accepted（到場/結案）就自動停。
    if (enroute.has(taskId)) return;
    const timer = setInterval(async () => {
      try {
        const { data } = await sb
          .from('dispatch_tasks')
          .select('status,eta_minutes,assignee_name,kind,elder_id')
          .eq('id', taskId)
          .single();
        if (!data || data.status !== 'accepted') {
          stopEnroute(taskId);
          return;
        }
        const el = await elderInfo(data.elder_id);
        if (!el) return;
        const text = speakText('enroute', {
          name: data.assignee_name,
          eta: data.eta_minutes,
          kind: data.kind,
        });
        downlink.enqueue(el.deviceSerial, { type: 'speak', text, lang: el.lang });
        log(`[progress] → ${el.deviceSerial}（${el.lang}）路上（每10分）：「${text}」`);
      } catch (e) {
        log(`[progress] 路上播報失敗：${e?.message || e}`);
      }
    }, ENROUTE_INTERVAL_MS);
    enroute.set(taskId, timer);
  }

  // 收到一列 volunteers 座標變化（志工 App 的真實 GPS，或 demo 的移動模擬）→
  // 對這位志工手上「前往中」的單，逐一算他離長輩家還有多遠，夠近就先預告一次。
  async function onVolunteerLocation(row) {
    const name = row?.name;
    const lat = Number(row?.lat) || 0;
    const lng = Number(row?.lng) || 0;
    if (!name || (!lat && !lng)) return;

    const { data: tasks } = await sb
      .from('dispatch_tasks')
      .select('id,elder_id,kind')
      .eq('assignee_name', name)
      .eq('status', 'accepted');

    for (const t of tasks || []) {
      // 已經播過「開門」就跳過（door 去重涵蓋 GPS 預告與 arrived 狀態，只會有一次）。
      if (announced.has(`${t.id}:door`)) continue;
      const info = await elderInfo(t.elder_id);
      if (!info || (!info.lat && !info.lng)) continue;
      const d = distanceMeters(lat, lng, info.lat, info.lng);
      if (d > APPROACH_METERS) continue;
      // ③ 到府通知：GPS 判定志工已到門口（≤250m）→ 播一次「到門口了，馬上進來看您」，並停掉路上定時。
      await speakDoor(t.id, t.elder_id, name, t.kind);
    }
  }

  return {
    /** 啟動 Realtime 訂閱。回傳 'live' | 'dryrun'。 */
    async start() {
      if (!PROGRESS_ENABLED) {
        log('[progress] PROGRESS_WORKER=off → 本機不參與進度播報（由另一端負責，避免重複）');
        return 'off';
      }
      if (!KEY) {
        log('[progress] 無 Supabase 憑證 → 進度播報停用（志工接單/抵達不會主動念）');
        return 'dryrun';
      }
      sb = await createDbClient();   // 依 DB_BACKEND 決定 Supabase 或 Aurora
      if (!sb) {
        log('[progress] 資料層不可用 → 進度播報停用');
        return 'dryrun';
      }
      sb.channel('progress:dispatch_tasks')
        .on(
          'postgres_changes',
          { event: 'UPDATE', schema: 'public', table: 'dispatch_tasks' },
          (payload) => {
            onTask(payload.new).catch((e) => log(`[progress] 處理失敗：${e?.message || e}`));
          },
        )
        // 志工 GPS 上報 → 接近長輩家就先預告「等一下會敲門」
        .on(
          'postgres_changes',
          { event: 'UPDATE', schema: 'public', table: 'volunteers' },
          (payload) => {
            onVolunteerLocation(payload.new).catch((e) =>
              log(`[progress] 接近判定失敗：${e?.message || e}`),
            );
          },
        )
        .subscribe((st) => log(`[progress] realtime 訂閱：${st}`));
      return 'live';
    },

    onTask, // 測試用
    onVolunteerLocation, // 測試用
  };
}
