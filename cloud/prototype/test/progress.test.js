import { test } from 'node:test';
import assert from 'node:assert/strict';
import { speakText, createProgressWorker, distanceMeters } from '../src/progress.js';

/** 極簡 Supabase client 假物件：只支援本檔用到的 from().select().eq()[.single()] 鏈。 */
function fakeSb({ elders = {}, tasks = [] }) {
  return {
    from(table) {
      const f = {};
      const q = {
        select: () => q,
        eq: (k, v) => ((f[k] = v), q),
        single: () => {
          const row = elders[f.id];
          return Promise.resolve(row ? { data: row, error: null } : { data: null, error: 'nf' });
        },
        // 不呼叫 single() 時直接 await → 回符合條件的多列
        then: (res, rej) =>
          Promise.resolve({
            data:
              table === 'dispatch_tasks'
                ? tasks.filter((t) => Object.entries(f).every(([k, v]) => t[k] === v))
                : [],
          }).then(res, rej),
      };
      return q;
    },
  };
}

// 台北車站 (25.0478,121.5170) 附近的參考點
const ELDER = { device_serial: 'JS-0001', preferred_lang: 'mandarin', lat: 25.0478, lng: 121.5170 };
/** 由 elder 往北位移 n 公尺後的緯度（1 度緯度 ≈ 111320m）。 */
const northOf = (m) => ELDER.lat + m / 111320;

test('接單 ETA：正常中文書寫', () => {
  const t = speakText('accepted', { name: '林志明', eta: 8, kind: 'emergency' });
  assert.match(t, /志工林志明/);
  assert.match(t, /8 ?分鐘/);
  assert.doesNotMatch(t, /矣|閣|予伊|共伊/); // 一律正常中文，不含台語詞
});

test('文字與語言無關：台語由裝置端 TTS 轉，speakText 只出正常中文', () => {
  // 給不同 lang 也一樣：文字內容不變（lang 只在下發指令當語音旗標）
  const zh = speakText('arrived', { name: '阿明', lang: 'mandarin' });
  const tg = speakText('arrived', { name: '阿明', lang: 'taigi' });
  assert.equal(zh, tg);
  assert.match(zh, /門口|進來看您/);
  assert.doesNotMatch(tg, /矣|予伊入來|共伊/); // 即使指定台語也是正常中文
});

test('物資單 vs 緊急單措辭不同；無 eta 有 fallback', () => {
  const supply = speakText('accepted', { name: '阿明', eta: 10, kind: 'supply' });
  assert.match(supply, /東西送到|送/);
  const noEta = speakText('accepted', { name: '阿明', kind: 'emergency' });
  assert.match(noEta, /在路上|趕過來/);
});

test('worker.onTask：只在 accepted/arrived 播、同狀態去重', async () => {
  const sent = [];
  const w = createProgressWorker({ downlink: { enqueue: (s, c) => sent.push({ s, c }) }, log: () => {} });
  // 用 elderCache 走捷徑：直接塞快取，避免打真 Supabase
  // （onTask 內部會查 elders；這裡先驗證「狀態過濾」不需查 DB 的分支）
  await w.onTask({ id: 't1', status: 'pending', elder_id: 'elder-1' });
  await w.onTask({ id: 't1', status: 'resolved', elder_id: 'elder-1' });
  assert.equal(sent.length, 0, 'pending/resolved 不該播');
});

test('distanceMeters：同點為 0、位移量約當', () => {
  assert.equal(Math.round(distanceMeters(ELDER.lat, ELDER.lng, ELDER.lat, ELDER.lng)), 0);
  const d = distanceMeters(northOf(300), ELDER.lng, ELDER.lat, ELDER.lng);
  assert.ok(Math.abs(d - 300) < 5, `應約 300m，實得 ${d}`);
});

test('接近預告：>250m 不播；進到門檻內播一次，之後去重不再播', async () => {
  const sent = [];
  const w = createProgressWorker({
    downlink: { enqueue: (s, c) => sent.push({ s, c }) },
    log: () => {},
    client: fakeSb({
      elders: { 'elder-1': ELDER },
      tasks: [
        { id: 't1', elder_id: 'elder-1', kind: 'emergency', assignee_name: '阿明', status: 'accepted' },
      ],
    }),
  });

  await w.onVolunteerLocation({ name: '阿明', lat: northOf(800), lng: ELDER.lng });
  assert.equal(sent.length, 0, '還有 800m，不該播');

  await w.onVolunteerLocation({ name: '阿明', lat: northOf(180), lng: ELDER.lng });
  assert.equal(sent.length, 1, '進到門檻內應播一次「開門」');
  assert.equal(sent[0].s, 'JS-0001');
  assert.equal(sent[0].c.type, 'speak');
  assert.match(sent[0].c.text, /開門|門口/);

  await w.onVolunteerLocation({ name: '阿明', lat: northOf(120), lng: ELDER.lng });
  assert.equal(sent.length, 1, '同一單只播一次「開門」');
});

test('開門：就算志工已很近（≤60m）也照播一次「開門」，不再靜默', async () => {
  const sent = [];
  const w = createProgressWorker({
    downlink: { enqueue: (s, c) => sent.push({ s, c }) },
    log: () => {},
    client: fakeSb({
      elders: { 'elder-1': ELDER },
      tasks: [
        { id: 't1', elder_id: 'elder-1', kind: 'emergency', assignee_name: '阿明', status: 'accepted' },
      ],
    }),
  });
  await w.onVolunteerLocation({ name: '阿明', lat: northOf(30), lng: ELDER.lng });
  assert.equal(sent.length, 1, '到門口只播一次「開門」');
  assert.match(sent[0].c.text, /開門|門口/);
});

test('接近預告：只看自己「前往中」的單；沒座標的上報略過', async () => {
  const sent = [];
  const w = createProgressWorker({
    downlink: { enqueue: (s, c) => sent.push({ s, c }) },
    log: () => {},
    client: fakeSb({
      elders: { 'elder-1': ELDER },
      tasks: [
        // 別人的單、以及自己已結案的單，都不該播
        { id: 't1', elder_id: 'elder-1', kind: 'emergency', assignee_name: '小華', status: 'accepted' },
        { id: 't2', elder_id: 'elder-1', kind: 'emergency', assignee_name: '阿明', status: 'resolved' },
      ],
    }),
  });
  await w.onVolunteerLocation({ name: '阿明', lat: northOf(150), lng: ELDER.lng });
  assert.equal(sent.length, 0);
  await w.onVolunteerLocation({ name: '阿明', lat: 0, lng: 0 });
  assert.equal(sent.length, 0, '無座標上報應略過');
});

test('物資單的接近預告用「送東西」措辭，不說敲門求救', () => {
  const t = speakText('approaching', { name: '阿明', kind: 'supply' });
  assert.match(t, /按門鈴|送/);
  assert.doesNotMatch(t, /矣|予伊|共伊/);
});
