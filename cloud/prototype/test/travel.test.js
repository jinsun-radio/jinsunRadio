import { test } from 'node:test';
import assert from 'node:assert/strict';

// 移動步數／間隔在 module 載入時就讀進去 → 必須先設環境變數再動態 import。
process.env.TRAVEL_STEP_MS = '1';
process.env.TRAVEL_STEPS = '2';
const { createTravelSimulator } = await import('../src/travel.js');

/**
 * 極簡資料層假物件：只涵蓋 db.js（Aurora 薄殼）實際提供的鏈——
 * from().select().eq()[.maybeSingle()] 與 from().update().eq()。
 * 刻意不提供 `channel`，剛好模擬「Aurora 沒有 Realtime」的情況。
 */
function fakeDb({ tasks = [], volunteers = [], elders = [] } = {}) {
  const writes = [];
  const selects = [];
  const tableOf = (t) => ({ dispatch_tasks: tasks, volunteers, elders })[t] || [];

  function from(table) {
    const rows = tableOf(table);
    const f = {};
    let payload = null;
    const match = (r) => Object.entries(f).every(([k, v]) => r[k] === v);
    const q = {
      select: () => q,
      eq: (k, v) => ((f[k] = v), q),
      update: (obj) => ((payload = obj), q),
      maybeSingle: () => {
        selects.push({ table, filters: { ...f } });
        return Promise.resolve({ data: rows.find(match) ?? null, error: null });
      },
      then: (res, rej) => {
        if (payload) {
          const hit = rows.filter(match);
          for (const r of hit) Object.assign(r, payload);
          writes.push({ table, filters: { ...f }, payload, n: hit.length });
          return Promise.resolve({ data: hit, error: null }).then(res, rej);
        }
        selects.push({ table, filters: { ...f } });
        return Promise.resolve({ data: rows.filter(match), error: null }).then(res, rej);
      },
    };
    return q;
  }
  return { from, writes, selects, __backend: 'aurora' };
}

const ELDER = { id: 'elder-1', lat: 25.0478, lng: 121.517 };
const accepted = () => ({
  id: 't-1',
  status: 'accepted',
  assignee_name: '阿明',
  elder_id: 'elder-1',
  eta_minutes: 8,
});

function scene(taskOverrides = []) {
  return fakeDb({
    tasks: [accepted(), ...taskOverrides],
    volunteers: [{ id: 'v-1', name: '阿明', lat: 25.04, lng: 121.51 }],
    elders: [ELDER],
  });
}

test('sweep：只撈 status=accepted 的單，pending／resolved 不會被啟動', async () => {
  const db = scene([
    { id: 't-2', status: 'pending', assignee_name: null, elder_id: 'elder-1' },
    { id: 't-3', status: 'resolved', assignee_name: '阿華', elder_id: 'elder-1' },
  ]);
  const sim = createTravelSimulator({ client: db, log: () => {} });
  await sim.sweep();
  // 掃描本身用的條件
  const scan = db.selects.find((s) => s.table === 'dispatch_tasks');
  assert.deepEqual(scan.filters, { status: 'accepted' });
  // 讓被啟動的 simulate 跑完（2 步 × 1ms）
  await new Promise((r) => setTimeout(r, 60));
  const moved = db.writes.filter((w) => w.table === 'volunteers');
  assert.ok(moved.length > 0, 'accepted 的單應該有志工座標更新');
  // 只有 t-1 被推進；阿華（resolved 的單）沒有被找出來過
  assert.equal(
    db.selects.some((s) => s.table === 'volunteers' && s.filters.name === '阿華'),
    false,
  );
  sim.stop();
});

test('sweep：同一張單重複掃到不會重複啟動', async () => {
  const db = scene();
  const sim = createTravelSimulator({ client: db, log: () => {} });
  await sim.sweep();
  await sim.sweep(); // 第二次掃描時 t-1 仍在移動中
  await new Promise((r) => setTimeout(r, 60));
  // 兩步 × 一輪 = 2 次座標更新；若重複啟動會變 4 次
  assert.equal(db.writes.filter((w) => w.table === 'volunteers').length, 2);
  sim.stop();
});

test('simulate：走完全程後把單標成 arrived 並同時寫 arrived_at', async () => {
  const db = scene();
  const sim = createTravelSimulator({ client: db, log: () => {} });
  await sim.simulate(accepted());
  const arrived = db.writes.find(
    (w) => w.table === 'dispatch_tasks' && w.payload.status === 'arrived',
  );
  assert.ok(arrived, '應把單標成 arrived');
  assert.ok(
    arrived.payload.arrived_at,
    'arrived_at 要一起寫，否則志工端時間軸「到場」那格會顯示 —',
  );
  const lastMove = [...db.writes].reverse().find((w) => w.table === 'volunteers');
  assert.ok(Math.abs(lastMove.payload.lat - ELDER.lat) < 1e-9, '最後一步應落在長輩家');
  assert.ok(Math.abs(lastMove.payload.lng - ELDER.lng) < 1e-9);
});

test('simulate：單子已不是 accepted 就停止移動，不會硬標 arrived', async () => {
  const db = scene();
  // 模擬「已被改派／已結案」：資料庫裡那一列變了，但傳進 simulate 的還是舊的 accepted 快照。
  const { data } = await db.from('dispatch_tasks').select('*').eq('id', 't-1');
  data[0].status = 'resolved';
  await createTravelSimulator({ client: db, log: () => {} }).simulate(accepted());
  const arrived = db.writes.find(
    (w) => w.table === 'dispatch_tasks' && w.payload.status === 'arrived',
  );
  assert.equal(arrived, undefined, '單已不是 accepted，不該標成 arrived');
});
