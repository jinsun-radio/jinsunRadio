// jinsun-speak — 把一句話下發給收音機（Step Functions 的「說話」步驟）
// 正式版 Escalate 會擴充成：寫 dispatch_tasks → 回傳 etaMinutes → 再由狀態機播報。
import { IoTDataPlaneClient, PublishCommand } from '@aws-sdk/client-iot-data-plane';

import { tee } from './shared/downlink.mjs';

const iot = new IoTDataPlaneClient({ endpoint: `https://${process.env.IOT_ENDPOINT}` });

export const handler = async (event) => {
  const { deviceSerial, text, lang = 'mandarin', command } = event;
  const commands = command
    ? [{ type: 'device', command }]
    : [{ type: 'speak', text, lang }];
  const topic = `jinsun/${deviceSerial}/cmd`;
  await iot.send(new PublishCommand({
    topic, qos: 1, payload: Buffer.from(JSON.stringify({ commands })),
  }));
  // 扇出給瀏覽器版模擬器（GET /commands 長輪詢）。publish 成功之後才做，
  // 且 tee 自己吞錯 —— 模擬器壞掉不能影響真裝置收話。
  for (const c of commands) await tee(deviceSerial, c);
  return { published: true, topic, at: new Date().toISOString() };
};
