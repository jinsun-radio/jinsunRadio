// jinsun-progress — 進度播報（cloud/prototype/src/progress.js 的 AWS 版）。
//
// 原版是常駐 worker：訂閱 Supabase Realtime + 用 setInterval 做「路上每 10 分鐘」。
// Lambda 沒有常駐能力，兩者分別換成：
//   Realtime 訂閱  → jinsun-data 寫入後直接 invoke 本 Lambda（event.__direct）
//   setInterval    → Step Functions JinsunEnrouteBroadcast（Wait → tick → Choice 迴圈）
//   announced Set  → DynamoDB（附 TTL，跨呼叫保存去重狀態）
//
// 播報措辭與距離計算直接 import 自 progress.js，維持單一來源。
//
// ⚠️ 資料存取一律走 src/db.js。本檔曾經直接 `import '@supabase/supabase-js'`，
//    在切到 Aurora 時 package.json 拿掉了該依賴、import 卻留著，結果是
//    **整支 Lambda 連載入都失敗**（ERR_MODULE_NOT_FOUND），每一次呼叫——包含
//    Step Functions 的 10 分鐘 tick——都靜默死在 init。db.js 依 DB_BACKEND
//    回傳 Aurora 或 Supabase 的相容薄殼，兩套環境共用同一段查詢。

import { IoTDataPlaneClient, PublishCommand } from '@aws-sdk/client-iot-data-plane';
import { SFNClient, StartExecutionCommand } from '@aws-sdk/client-sfn';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';

import { speakText, distanceMeters } from './src/progress.js';
import { createDbClient } from './src/db.js';
import { tee } from './shared/downlink.mjs';

const iot = new IoTDataPlaneClient({ endpoint: `https://${process.env.IOT_ENDPOINT}` });
const sfn = new SFNClient({});
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const ANNOUNCED = process.env.ANNOUNCED_TABLE;
const ENROUTE_ARN = process.env.ENROUTE_ARN;
const HOOK_SECRET = process.env.PROGRESS_WEBHOOK_SECRET || '';
const APPROACH_METERS = Number(process.env.APPROACH_METERS) || 250;

// 跨呼叫重用（Lambda 容器存活期間只建一次）。createDbClient 是 async，
// 所以不能在模組層 await——用 memoized getter。
let _db = null;
async function db() {
  if (!_db) {
    _db = await createDbClient();
    if (!_db) throw new Error('db.js 建不出 client：檢查 DB_BACKEND 與 AURORA_* 環境變數');
  }
  return _db;
}

/** 去重：同一 (taskId, milestone) 只播一次。回傳 true 表示「這次是第一次」。 */
async function claim(taskId, milestone) {
  const key = `${taskId}:${milestone}`;
  const got = await ddb.send(new GetCommand({ TableName: ANNOUNCED, Key: { key } }));
  if (got.Item) return false;
  await ddb.send(new PutCommand({
    TableName: ANNOUNCED,
    Item: { key, at: new Date().toISOString(), expiresAt: Math.floor(Date.now() / 1000) + 86400 },
  }));
  return true;
}

async function elderInfo(elderId) {
  if (!elderId) return null;
  // 每次即時查，家屬在 App 改語言後立刻生效（低頻）
  const { data, error } = await (await db()).from('elders').select('*').eq('id', elderId).single();
  if (error || !data?.device_serial) return null;
  return {
    deviceSerial: data.device_serial,
    lang: data.preferred_lang || 'mandarin',
    lat: data.lat || 0,
    lng: data.lng || 0,
  };
}

async function speak(deviceSerial, text, lang) {
  const cmd = { type: 'speak', text, lang };
  await iot.send(new PublishCommand({
    topic: `jinsun/${deviceSerial}/cmd`,
    qos: 1,
    payload: Buffer.from(JSON.stringify({ commands: [cmd] })),
  }));
  await tee(deviceSerial, cmd);   // 扇出給瀏覽器版模擬器
  console.log(`[progress] → ${deviceSerial}（${lang}）「${text}」`);
}

/** ③ 開門：approaching（GPS 預告）或 arrived（狀態）擇一，只播一次。 */
async function speakDoor(taskId, elderId, name, kind) {
  if (!(await claim(taskId, 'door'))) return;
  const info = await elderInfo(elderId);
  if (!info) return;
  await speak(info.deviceSerial, speakText('arrived', { name, kind }), info.lang);
}

/** dispatch_tasks 一列變化 → 三個時機：出發 / 路上每 10 分鐘 / 開門。 */
async function onTask(row) {
  const { id: taskId, status } = row || {};
  if (!taskId) return { handled: false };

  if (status === 'arrived') {
    await speakDoor(taskId, row.elder_id, row.assignee_name, row.kind);
    return { handled: true, milestone: 'door' };
  }
  // resolved / pending：不出聲。路上迴圈會自己在下一 tick 發現狀態變了而結束。
  if (status !== 'accepted') return { handled: false, status };

  // ① 出發：只在首次進入 accepted 播一次（後續 eta 更新的 UPDATE 被去重擋掉）
  if (!(await claim(taskId, 'depart'))) return { handled: false, reason: 'already_departed' };

  const info = await elderInfo(row.elder_id);
  if (!info) {
    console.log(`[progress] 找不到 elder=${row.elder_id} 的 device_serial，略過`);
    return { handled: false, reason: 'no_device' };
  }
  await speak(info.deviceSerial,
    speakText('accepted', { name: row.assignee_name, eta: row.eta_minutes, kind: row.kind }),
    info.lang);

  // ② 路上每 10 分鐘 → 交給 Step Functions（取代原本的 setInterval）
  if (ENROUTE_ARN) {
    await sfn.send(new StartExecutionCommand({
      stateMachineArn: ENROUTE_ARN,
      name: `enroute-${taskId}`.slice(0, 80),   // 同一張單重複啟動會被 ExecutionAlreadyExists 擋掉
      input: JSON.stringify({ taskId }),
    })).catch((e) => {
      if (e?.name !== 'ExecutionAlreadyExists') throw e;
    });
  }
  return { handled: true, milestone: 'depart' };
}

/** volunteers 座標變化 → 對他手上「前往中」的單算距離，≤250m 就先預告開門。 */
async function onVolunteerLocation(row) {
  const name = row?.name;
  const lat = Number(row?.lat) || 0;
  const lng = Number(row?.lng) || 0;
  if (!name || (!lat && !lng)) return { handled: false };

  const { data: tasks } = await (await db()).from('dispatch_tasks')
    .select('id,elder_id,kind').eq('assignee_name', name).eq('status', 'accepted');

  let hit = 0;
  for (const t of tasks || []) {
    const info = await elderInfo(t.elder_id);
    if (!info || (!info.lat && !info.lng)) continue;
    if (distanceMeters(lat, lng, info.lat, info.lng) > APPROACH_METERS) continue;
    await speakDoor(t.id, t.elder_id, name, t.kind);
    hit++;
  }
  return { handled: hit > 0, nearby: hit };
}

/** Step Functions 的路上迴圈：每 10 分鐘一 tick，狀態不再是 accepted 就回報 continue=false。 */
async function enrouteTick({ taskId }) {
  const { data } = await (await db()).from('dispatch_tasks')
    .select('status,eta_minutes,assignee_name,kind,elder_id').eq('id', taskId).single();
  if (!data || data.status !== 'accepted') return { continue: false, status: data?.status ?? 'gone' };
  // 已播過「開門」就不再報路上進度
  const done = await ddb.send(new GetCommand({ TableName: ANNOUNCED, Key: { key: `${taskId}:door` } }));
  if (done.Item) return { continue: false, status: 'arrived' };

  const info = await elderInfo(data.elder_id);
  if (!info) return { continue: true };
  await speak(info.deviceSerial,
    speakText('enroute', { name: data.assignee_name, eta: data.eta_minutes, kind: data.kind }),
    info.lang);
  return { continue: true };
}

const json = (code, obj) => ({
  statusCode: code,
  headers: { 'content-type': 'application/json; charset=utf-8' },
  body: JSON.stringify(obj),
});

export const handler = async (event) => {
  // Step Functions 直接呼叫
  if (event?.__sfn === 'enroute_tick') return enrouteTick(event);

  // jinsun-data 寫入 Aurora 後直接 invoke（InvocationType: Event，非同步）。
  // 這是「志工接單／抵達／上報座標 → 收音機播報」在純 AWS 環境的唯一觸發來源：
  // Aurora 沒有 Realtime，也不該為了播報而裝資料庫 trigger（那會多一層密鑰與失敗點，
  // 且 pg_net 那條路會把兩套環境耦合回去，見 aws-handoff.md §6.1）。
  if (event?.__direct === 'task') return onTask(event.record);
  if (event?.__direct === 'volunteer') return onVolunteerLocation(event.record);

  // 舊路徑：Supabase pg_net trigger（payload 對齊 Database Webhook 格式）。
  // 純 AWS 環境不會走到，保留是為了兩套環境共用同一支 handler。
  const secret = event.headers?.['x-webhook-secret'] || event.headers?.['X-Webhook-Secret'];
  if (HOOK_SECRET && secret !== HOOK_SECRET) return json(401, { error: 'bad secret' });

  let body = {};
  try { body = JSON.parse(event.body || '{}'); } catch { /* 空物件 */ }
  const { table, record, type } = body;
  if (type !== 'UPDATE' && type !== 'INSERT') return json(200, { skipped: type });

  try {
    if (table === 'dispatch_tasks') return json(200, await onTask(record));
    if (table === 'volunteers') return json(200, await onVolunteerLocation(record));
    return json(200, { skipped: table });
  } catch (e) {
    console.error(e);
    return json(500, { error: String(e?.message || e) });
  }
};
