// AWS 版的下行扇出佇列 —— `cloud/prototype/src/downlink.js` 的等價物。
//
// 為什麼需要它：真韌體的下行走 IoT Core MQTT push，但**瀏覽器版硬體模擬器**
// （`admin/?sim=1`，`admin/lib/hardware_sim.dart`）連不了 raw MQTT，它靠
// `GET /commands?device_serial=X` 長輪詢。Render 那套用行程內 Map 就能做到
// （`createFanoutDownlink`：同一筆指令 MQTT 與佇列都投遞），Lambda 無狀態，
// 所以佇列改放 DynamoDB。
//
// 設計取捨：
//   * **tee 失敗絕不影響 publish**。模擬器是 demo 工具，它壞掉不能讓真裝置收不到話。
//     所以呼叫端是 publish 成功之後才 tee，且這裡自己吞掉錯誤只留 log。
//   * TTL 5 分鐘。模擬器沒開的時候指令會一直堆積，堆成幾天份的話一開頁面
//     會把幾百句話一次唸出來——那比沒有還糟。
//   * sort key 帶時間戳，讓 Query 自然照發生順序回來。急救階梯的三句話
//     （詢問 → 沒聽到 → 已幫您叫人）順序反了會變成另一個意思。

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient, PutCommand, QueryCommand, BatchWriteCommand,
} from '@aws-sdk/lib-dynamodb';

const TABLE = process.env.DOWNLINK_TABLE || '';
const TTL_SECONDS = Number(process.env.DOWNLINK_TTL_SECONDS) || 300;

let _ddb = null;
function ddb() {
  if (!_ddb) _ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
  return _ddb;
}

// 同一毫秒內連續 tee 兩筆時用來去重（急救階梯就會這樣）。
let _n = 0;

/**
 * 把一筆已經 publish 到 IoT 的指令複製一份進佇列，供模擬器輪詢。
 * 永不 throw —— 呼叫端不需要 try/catch。
 */
export async function tee(serial, cmd) {
  if (!TABLE || !serial || !cmd) return;
  try {
    const seq = `${String(Date.now()).padStart(14, '0')}-${String(_n++).padStart(4, '0')}`;
    await ddb().send(new PutCommand({
      TableName: TABLE,
      Item: {
        serial,
        seq,
        cmd,
        expiresAt: Math.floor(Date.now() / 1000) + TTL_SECONDS,
      },
    }));
  } catch (e) {
    // 只 log。模擬器收不到不是事故，真裝置那條已經送出去了。
    console.error('[downlink] tee 失敗（不影響 MQTT 投遞）：', e?.message || e);
  }
}

/**
 * 取出並清空某台裝置待送的指令。回傳 `[]` 表示目前沒有。
 * 與 `downlink.js` 的 `pull()` 語義一致：讀到就消耗掉，不重送。
 */
export async function drain(serial) {
  if (!TABLE || !serial) return [];
  const res = await ddb().send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: '#s = :s',
    ExpressionAttributeNames: { '#s': 'serial' },
    ExpressionAttributeValues: { ':s': serial },
    ScanIndexForward: true,   // 照 seq 由小到大＝發生順序
    Limit: 25,                // 與 BatchWrite 單次上限一致
  }));
  const items = res.Items || [];
  if (!items.length) return [];

  await ddb().send(new BatchWriteCommand({
    RequestItems: {
      [TABLE]: items.map((it) => ({
        DeleteRequest: { Key: { serial: it.serial, seq: it.seq } },
      })),
    },
  }));
  return items.map((it) => it.cmd).filter(Boolean);
}
