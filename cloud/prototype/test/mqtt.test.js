// MQTT 下行測試：broker lifecycle 降級、publish 契約、presence 轉換、扇出雙通道。
// 全部用注入的假 aedes／假 TCP server 與 registry 直驅，不開真 socket。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import {
  createMqttDownlink,
  createPresenceRegistry,
  createFanoutDownlink,
  cmdTopic,
  statusTopic,
  cmdPayload,
} from '../src/mqtt.js';
import { createDownlink } from '../src/downlink.js';

const noop = () => {};

/** 假 aedes：記錄 publish 封包、可注入拋錯，事件照真 broker 介面 emit。 */
class FakeAedes extends EventEmitter {
  constructor() {
    super();
    this.published = [];
    this.handle = () => {};
  }
  publish(packet, cb) {
    this.published.push(packet);
    cb && cb();
  }
  close(cb) {
    cb && cb();
  }
}

/** 假 TCP server：listen 立刻成功（或依 failListen 立刻報錯）。 */
function fakeTcpFactory({ failListen = false } = {}) {
  return () => {
    const srv = new EventEmitter();
    srv.listen = (port, cb) => {
      if (failListen) queueMicrotask(() => srv.emit('error', new Error('EADDRINUSE')));
      else cb && cb();
    };
    srv.close = (cb) => cb && cb();
    return srv;
  };
}

/** 起一個 live mode 的下行（注入假件），回傳 { d, fake, logs, errors }。 */
async function liveDownlink() {
  const fake = new FakeAedes();
  const logs = [];
  const errors = [];
  const d = await createMqttDownlink({
    port: 1883,
    log: (m) => logs.push(m),
    logError: (m) => errors.push(m),
    loadAedes: async () => function FakeCtor() { return fake; },
    createTcpServer: fakeTcpFactory(),
  });
  return { d, fake, logs, errors };
}

// ---------- Embedded MQTT broker lifecycle ----------

test('MQTT_PORT=0 → mode off、API 全為 no-op、close 可重複呼叫', async () => {
  const logs = [];
  const d = await createMqttDownlink({ port: 0, log: (m) => logs.push(m) });
  assert.equal(d.mode, 'off');
  d.publish('JS-0001', { type: 'speak', text: 'hi' }); // 不拋錯
  assert.equal(d.presence('JS-0001'), 'unknown');
  await d.close();
  await d.close(); // 重複呼叫不拋錯
  assert.ok(logs.some((m) => m.includes('停用')));
});

test('aedes 未安裝 → mode off、警告含 npm i aedes', async () => {
  const logs = [];
  const d = await createMqttDownlink({
    port: 1883,
    log: (m) => logs.push(m),
    loadAedes: async () => { throw new Error('not found'); },
  });
  assert.equal(d.mode, 'off');
  assert.ok(logs.some((m) => m.includes('npm i aedes')));
});

test('listener 錯誤（埠被占用）→ 降級 off、不拋錯', async () => {
  const errors = [];
  const fake = new FakeAedes();
  const d = await createMqttDownlink({
    port: 1883,
    log: noop,
    logError: (m) => errors.push(m),
    loadAedes: async () => function () { return fake; },
    createTcpServer: fakeTcpFactory({ failListen: true }),
  });
  assert.equal(d.mode, 'off');
  assert.ok(errors.some((m) => m.includes('啟動失敗')));
});

test('live mode：mode/port 正確、close 可重複呼叫', async () => {
  const { d } = await liveDownlink();
  assert.equal(d.mode, 'live');
  assert.equal(d.port, 1883);
  await d.close();
  await d.close(); // idempotent
});

// ---------- Downlink command publish ----------

test('publish 契約：topic jinsun/{serial}/cmd、QoS 1、payload {"commands":[cmd]} 同形', async () => {
  const { d, fake } = await liveDownlink();
  const cmd = { type: 'speak', text: '志工大約 8 分鐘就到', lang: 'taigi' };
  d.publish('JS-0001', cmd);
  assert.equal(fake.published.length, 1);
  const p = fake.published[0];
  assert.equal(p.topic, cmdTopic('JS-0001'));
  assert.equal(p.topic, 'jinsun/JS-0001/cmd');
  assert.equal(p.qos, 1);
  assert.equal(p.retain, false);
  const parsed = JSON.parse(p.payload.toString());
  assert.deepEqual(parsed, { commands: [cmd] }); // 與 GET /commands 指令物件同形
  assert.equal(p.payload.toString(), cmdPayload(cmd));
});

test('broker publish 拋錯 → 呼叫端不拋錯、錯誤有 log', async () => {
  const { d, fake, errors } = await liveDownlink();
  fake.publish = () => { throw new Error('boom'); };
  d.publish('JS-0001', { type: 'speak', text: 'hi' }); // 不得外洩
  assert.ok(errors.some((m) => m.includes('publish 失敗')));
});

// ---------- Device presence tracking ----------

test('presence registry 直驅：online/offline 轉換與 unknown', () => {
  const logs = [];
  const reg = createPresenceRegistry({ log: (m) => logs.push(m) });
  assert.equal(reg.presence('JS-0001'), 'unknown');
  reg.online('JS-0001');
  assert.equal(reg.presence('JS-0001'), 'online');
  reg.offline('JS-0001');
  assert.equal(reg.presence('JS-0001'), 'offline');
  // 轉換各 log 一次（含 serial 與新狀態）
  assert.equal(logs.length, 2);
  assert.ok(logs[0].includes('JS-0001') && logs[0].includes('online'));
  assert.ok(logs[1].includes('JS-0001') && logs[1].includes('offline'));
  // 同狀態不重複 log
  reg.offline('JS-0001');
  assert.equal(logs.length, 2);
});

test('broker 事件驅動 presence：connect→online、disconnect→offline、LWT offline', async () => {
  const { d, fake } = await liveDownlink();
  assert.equal(d.presence('JS-0001'), 'unknown');
  fake.emit('client', { id: 'JS-0001' });
  assert.equal(d.presence('JS-0001'), 'online');
  fake.emit('clientDisconnect', { id: 'JS-0001' });
  assert.equal(d.presence('JS-0001'), 'offline');
  // LWT：status topic 收到 offline/online 也更新（雙保險）
  fake.emit('publish', { topic: statusTopic('JS-0002'), payload: Buffer.from('online') });
  assert.equal(d.presence('JS-0002'), 'online');
  fake.emit('publish', { topic: statusTopic('JS-0002'), payload: Buffer.from('offline') });
  assert.equal(d.presence('JS-0002'), 'offline');
  // 非 status topic 不影響
  fake.emit('publish', { topic: cmdTopic('JS-0003'), payload: Buffer.from('offline') });
  assert.equal(d.presence('JS-0003'), 'unknown');
});

// ---------- External-broker client mode (MQTT_URL) ----------

/** 假 mqtt 套件 client：記錄 publish/subscribe，事件照 mqtt.js 介面 emit。 */
class FakeMqttClient extends EventEmitter {
  constructor() {
    super();
    this.published = [];
    this.subscribed = [];
  }
  subscribe(topic, opts, cb) {
    this.subscribed.push({ topic, ...opts });
    cb && cb();
  }
  publish(topic, payload, opts, cb) {
    this.published.push({ topic, payload, ...opts });
    cb && cb();
  }
  end(force, opts, cb) {
    cb && cb();
  }
}

/** 起一個 client mode 的下行（注入假 mqtt 套件）。 */
async function clientDownlink() {
  const fake = new FakeMqttClient();
  const logs = [];
  const errors = [];
  const d = await createMqttDownlink({
    url: 'mqtt://broker.example.com:1883',
    log: (m) => logs.push(m),
    logError: (m) => errors.push(m),
    loadMqttClient: async () => ({ connect: () => fake }),
  });
  return { d, fake, logs, errors };
}

test('MQTT_URL 有值但未安裝 mqtt 套件 → mode off、警告含 npm i mqtt', async () => {
  const logs = [];
  const d = await createMqttDownlink({
    url: 'mqtt://broker.example.com:1883',
    log: (m) => logs.push(m),
    loadMqttClient: async () => { throw new Error('not found'); },
  });
  assert.equal(d.mode, 'off');
  assert.ok(logs.some((m) => m.includes('npm i mqtt')));
});

test('client mode：publish 契約與內嵌模式一致（topic/QoS 1/payload 同形）', async () => {
  const { d, fake } = await clientDownlink();
  assert.equal(d.mode, 'client');
  assert.equal(d.url, 'mqtt://broker.example.com:1883');
  const cmd = { type: 'speak', text: '志工大約 8 分鐘就到', lang: 'taigi' };
  d.publish('JS-0001', cmd);
  assert.equal(fake.published.length, 1);
  const p = fake.published[0];
  assert.equal(p.topic, cmdTopic('JS-0001'));
  assert.equal(p.qos, 1);
  assert.equal(p.payload, cmdPayload(cmd));
  await d.close();
  await d.close(); // idempotent
});

test('client mode：連上 broker 即訂閱 jinsun/+/status，status 訊息驅動 presence', async () => {
  const { d, fake } = await clientDownlink();
  fake.emit('connect');
  assert.ok(fake.subscribed.some((s) => s.topic === 'jinsun/+/status' && s.qos === 1));
  assert.equal(d.presence('JS-0001'), 'unknown');
  fake.emit('message', statusTopic('JS-0001'), Buffer.from('online'));
  assert.equal(d.presence('JS-0001'), 'online');
  fake.emit('message', statusTopic('JS-0001'), Buffer.from('offline')); // LWT
  assert.equal(d.presence('JS-0001'), 'offline');
  // 非 status topic 不影響
  fake.emit('message', cmdTopic('JS-0002'), Buffer.from('online'));
  assert.equal(d.presence('JS-0002'), 'unknown');
});

test('client mode：publish 拋錯 → 呼叫端不拋錯、錯誤有 log', async () => {
  const { d, fake, errors } = await clientDownlink();
  fake.publish = () => { throw new Error('boom'); };
  d.publish('JS-0001', { type: 'speak', text: 'hi' });
  assert.ok(errors.some((m) => m.includes('publish 失敗')));
});

// ---------- Fan-out to the long-poll simulator channel ----------

test('扇出：enqueue 一筆 → MQTT publish 收到且長輪詢 pull 拿到同一指令物件', async () => {
  const { d, fake } = await liveDownlink();
  const fanout = createFanoutDownlink(d, createDownlink());
  const cmd = { type: 'speak', text: '已經幫你叫人', lang: 'mandarin' };
  fanout.enqueue('JS-0001', cmd);
  // MQTT 端
  assert.equal(fake.published.length, 1);
  assert.deepEqual(JSON.parse(fake.published[0].payload.toString()).commands[0], cmd);
  // 長輪詢端（同一指令物件）
  const got = await fanout.pull('JS-0001');
  assert.equal(got.length, 1);
  assert.deepEqual(got[0], cmd);
  assert.equal(fanout.pending('JS-0001'), 0);
});

test('mode off 時扇出：長輪詢行為與現行完全一致', async () => {
  const off = await createMqttDownlink({ port: 0, log: noop });
  const fanout = createFanoutDownlink(off, createDownlink());
  const cmd = { type: 'device', command: 'volume_up' };
  fanout.enqueue('JS-0001', cmd);
  const got = await fanout.pull('JS-0001');
  assert.deepEqual(got, [cmd]);
});
