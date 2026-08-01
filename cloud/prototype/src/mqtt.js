// MQTT 下行（server → 硬體）—— 指令 publish 給訂閱中的真裝置。兩種模式：
//
//   內嵌 broker（預設）：server 自己跑 aedes，裝置直連 server 的 1883。本機開發用。
//   外部 broker client（MQTT_URL 有值）：Render 這類 PaaS 只對外開 HTTPS，內嵌
//     broker 的 1883 從公網進不來 → server 改當 MQTT client 連到外部 broker
//     （公共 EMQX／自架 mosquitto），裝置連同一顆會合。topic 與 payload 契約不變；
//     presence 改靠裝置的 status topic（online＋LWT offline），沒有 broker 連線事件。
//
// 契約（docs/requirements/hardware-integration.md §3②）：
//   topic   jinsun/{device_serial}/cmd        QoS 1
//   payload {"commands":[{type:"speak",...}]}  與 GET /commands 回的指令物件同形
//   上下線  裝置連線即 online；斷線或 LWT jinsun/{serial}/status = "offline" 即 offline
//
// aedes／mqtt 都走 optionalDependencies（比照 bedrock/supabase）：未安裝、MQTT_PORT=0
// 或埠被占用時降級為 mode:'off'（publish 變 no-op），server 照常服務長輪詢。
// 正式版對應 AWS IoT Core：換 endpoint＋憑證，topic 與 payload 不變。

// ---- 契約常數：topic 樣式與 payload 組裝集中在這裡，測試與 server 共用 ----
export const cmdTopic = (serial) => `jinsun/${serial}/cmd`;
export const statusTopic = (serial) => `jinsun/${serial}/status`;
export const cmdPayload = (cmd) => JSON.stringify({ commands: [cmd] });

const STATUS_RE = /^jinsun\/([^/]+)\/status$/;

/**
 * enqueue 扇出：同一筆指令同時走 MQTT publish（真裝置）與長輪詢佇列
 * （sim.html／curl 對測），兩通道獨立投遞、互不影響。介面與 createDownlink 相容。
 */
export function createFanoutDownlink(mqtt, downlink) {
  return {
    enqueue: (serial, cmd) => {
      mqtt.publish(serial, cmd);
      downlink.enqueue(serial, cmd);
    },
    pull: (...args) => downlink.pull(...args),
    pending: (...args) => downlink.pending(...args),
  };
}

/**
 * 裝置上下線 registry（純資料結構，測試可直接驅動，不需真 socket）。
 * 狀態轉換時 log 出 serial 與新狀態。
 */
export function createPresenceRegistry({ log = console.log } = {}) {
  /** @type {Map<string,'online'|'offline'>} */
  const state = new Map();
  const set = (serial, next) => {
    if (!serial || state.get(serial) === next) return;
    state.set(serial, next);
    log(`[mqtt] 裝置 ${serial} ${next}`);
  };
  return {
    online: (serial) => set(serial, 'online'),
    offline: (serial) => set(serial, 'offline'),
    presence: (serial) => state.get(serial) || 'unknown',
  };
}

/**
 * 外部 broker client 模式（MQTT_URL 有值時走這裡）。
 * mqtt.js 套件自帶自動重連與離線佇列，publish 失敗只 log 不外洩。
 */
async function createClientDownlink({ url, registry, log, logError, loadMqttClient, off }) {
  let mqttLib;
  try {
    mqttLib = loadMqttClient ? await loadMqttClient() : (await import('mqtt')).default;
  } catch {
    log('[mqtt] ⚠️  設了 MQTT_URL 但未安裝 mqtt 套件，下行 MQTT 停用（僅剩長輪詢）。要啟用：npm i mqtt');
    return off();
  }

  const client = mqttLib.connect(url, {
    clientId: `jinsun-server-${Math.random().toString(16).slice(2, 8)}`,
    keepalive: 30,
  });
  client.on('connect', () => {
    log(`[mqtt] 已連上外部 broker ${url}`);
    // presence 靠裝置的 status topic（連上發 online、LWT 斷線發 offline）
    client.subscribe('jinsun/+/status', { qos: 1 }, (err) => {
      if (err) logError(`[mqtt] subscribe 失敗：${err?.message || err}`);
    });
  });
  client.on('error', (e) => logError(`[mqtt] client 錯誤：${e?.message || e}`)); // 套件會自動重連
  client.on('message', (topic, payload) => {
    const m = STATUS_RE.exec(topic || '');
    if (!m) return;
    const text = payload?.toString?.() ?? String(payload);
    if (text === 'offline') registry.offline(m[1]);
    else if (text === 'online') registry.online(m[1]);
  });

  let closed = false;
  return {
    mode: 'client',
    url,
    publish(serial, cmd) {
      try {
        client.publish(cmdTopic(serial), cmdPayload(cmd), { qos: 1 }, (err) => {
          if (err) logError(`[mqtt] publish 失敗（${serial}）：${err?.message || err}`);
        });
      } catch (e) {
        logError(`[mqtt] publish 失敗（${serial}）：${e?.message || e}`);
      }
    },
    presence: registry.presence,
    async close() {
      if (closed) return;
      closed = true;
      await new Promise((resolve) => client.end(false, {}, resolve));
    },
  };
}

/**
 * 建立 MQTT 下行。回傳 { mode, port|url, publish, presence, close }。
 * mode:'off' 時 publish 為 no-op、presence 一律 'unknown'、close 可安全呼叫。
 *
 * deps 供測試注入：loadAedes（回傳 Aedes 建構子）、createTcpServer（回傳 net server）、
 * loadMqttClient（回傳 mqtt 套件，client 模式用）。
 */
export async function createMqttDownlink({
  url = process.env.MQTT_URL || '',
  port = Number(process.env.MQTT_PORT ?? 1883),
  log = console.log,
  logError = console.error,
  loadAedes,
  createTcpServer,
  loadMqttClient,
} = {}) {
  const registry = createPresenceRegistry({ log });
  const off = () => ({
    mode: 'off',
    port,
    publish: () => {},
    presence: () => 'unknown',
    close: async () => {},
  });

  // MQTT_URL 有值 → 外部 broker client 模式（PaaS 部署用，見檔頭說明）
  if (url) {
    return createClientDownlink({ url, registry, log, logError, loadMqttClient, off });
  }

  // MQTT_PORT=0（或非數字）＝明確停用
  if (!port || Number.isNaN(port)) {
    log('[mqtt] MQTT_PORT=0，下行 MQTT 停用（僅剩長輪詢模擬器通道）。');
    return off();
  }

  // aedes 未安裝 → 降級，不擋 server 啟動
  let Aedes;
  try {
    Aedes = loadAedes ? await loadAedes() : (await import('aedes')).default;
  } catch {
    log('[mqtt] ⚠️  未安裝 aedes，下行 MQTT 停用（僅剩長輪詢）。要啟用：npm i aedes');
    return off();
  }

  const aedes = new Aedes();

  // 上下線：連線事件＋LWT（jinsun/{serial}/status）雙保險。
  // client id 即 device_serial（hardware-integration.md 契約）。
  aedes.on('client', (client) => registry.online(client?.id));
  aedes.on('clientDisconnect', (client) => registry.offline(client?.id));
  aedes.on('publish', (packet) => {
    const m = STATUS_RE.exec(packet?.topic || '');
    if (!m) return;
    const text = packet.payload?.toString?.() ?? String(packet.payload);
    if (text === 'offline') registry.offline(m[1]);
    else if (text === 'online') registry.online(m[1]);
  });

  // TCP listener：埠被占用等錯誤 → 降級為 off，不讓 process 掛掉
  let server;
  try {
    const net = createTcpServer ? { createServer: createTcpServer } : await import('node:net');
    server = net.createServer(aedes.handle);
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, resolve);
    });
    server.on('error', (e) => logError(`[mqtt] listener 錯誤：${e?.message || e}`));
  } catch (e) {
    logError(`[mqtt] broker 啟動失敗（port ${port}）：${e?.message || e}，下行 MQTT 停用。可用 MQTT_PORT 改埠。`);
    try { aedes.close(() => {}); } catch { /* 降級路徑，忽略 */ }
    return off();
  }

  let closed = false;
  return {
    mode: 'live',
    port,
    /** publish 失敗只 log、不外洩——下行斷線不能拖垮急救鏈路的呼叫端 */
    publish(serial, cmd) {
      try {
        aedes.publish(
          { topic: cmdTopic(serial), payload: Buffer.from(cmdPayload(cmd)), qos: 1, retain: false },
          (err) => err && logError(`[mqtt] publish 失敗（${serial}）：${err?.message || err}`),
        );
      } catch (e) {
        logError(`[mqtt] publish 失敗（${serial}）：${e?.message || e}`);
      }
    },
    presence: registry.presence,
    async close() {
      if (closed) return;
      closed = true;
      await new Promise((resolve) => aedes.close(resolve));
      await new Promise((resolve) => server.close(resolve));
    },
  };
}
