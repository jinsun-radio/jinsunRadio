// escalateEmergency / openAsking 寫進 Supabase 的 payload 形狀合約。
//
// 為什麼需要這支：這個函式的 payload 兩次寫錯，兩次都是部署到正式站才發現——
//   ① 寫了 radio_events 根本沒有的 note 欄位 → PostgREST 42703，insert 整筆失敗
//   ② 升級走 UPDATE 時誤帶 elder_id（server 手上只有 device_serial → 值是 null），
//      把 fn_on_radio_event trigger 在 INSERT 時補好的 elder_id 蓋回 null，
//      連鎖導致沒人被派單、志工 App 顯示「長輩（0 歲）」與假的 1.0 km。
// 兩者都是「欄位寫錯」而不是邏輯錯，用假 client 攔下 payload 斷言就能擋住。

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createDispatch, setSupabaseClientForTest } from '../src/dispatch.js';

// radio_events 的真實欄位（cloud/supabase/schema.sql:128）。多寫一個就會被 PostgREST 打回。
const RADIO_EVENT_COLUMNS = new Set([
  'id',
  'elder_id',
  'device_serial',
  'type',
  'status',
  'severity',
  'transcript',
  'occurred_at',
]);

/** 只記錄 payload 的假 Supabase client；查詢一律回空，讓流程往下走到底。 */
function fakeSupabase() {
  const writes = [];
  const api = (table) => ({
    insert(payload) {
      writes.push({ table, op: 'insert', payload });
      return chain({ id: 'evt-new', elder_id: payload.elder_id ?? null });
    },
    update(payload) {
      writes.push({ table, op: 'update', payload });
      return { eq: () => chain({ id: 'evt-asking', elder_id: 'elder-1' }) };
    },
    select() {
      return {
        eq: () => ({
          eq: () => ({ neq: () => ({ data: [], error: null }) }),
          neq: () => ({ data: [], error: null }),
          maybeSingle: async () => ({ data: null, error: null }),
          single: async () => ({ data: null, error: null }),
          order: () => ({ limit: () => ({ data: [], error: null }) }),
          data: [],
          error: null,
        }),
        order: () => ({ limit: () => ({ data: [], error: null }) }),
        data: [],
        error: null,
      };
    },
  });
  const chain = (data) => ({
    select: () => ({ single: async () => ({ data, error: null }) }),
  });
  return { from: api, _writes: writes };
}

function setup() {
  const fake = fakeSupabase();
  setSupabaseClientForTest(fake);
  return { fake, dispatch: createDispatch() };
}

test('openAsking 只寫 radio_events 真的有的欄位（note 不存在）', async () => {
  const { fake, dispatch } = setup();
  await dispatch.openAsking({ deviceSerial: 'JS-0001', keyword: '我跌倒了' });
  setSupabaseClientForTest(null);

  const ins = fake._writes.find((w) => w.table === 'radio_events' && w.op === 'insert');
  assert.ok(ins, 'openAsking 應該 insert 一筆 radio_events');
  const unknown = Object.keys(ins.payload).filter((k) => !RADIO_EVENT_COLUMNS.has(k));
  assert.deepEqual(unknown, [], `寫了 radio_events 沒有的欄位：${unknown.join(', ')}`);
  assert.equal(ins.payload.status, 'open');
  assert.equal(ins.payload.severity, 'attention');
});

test('升級走 UPDATE 時不得帶 elder_id／device_serial（會蓋掉 trigger 補好的值）', async () => {
  const { fake, dispatch } = setup();
  // server 手上只有 device_serial、沒有 elderId —— 正是會踩到的那條路徑
  await dispatch.escalateEmergency({
    deviceSerial: 'JS-0001',
    keyword: '我跌倒了',
    eventId: 'evt-asking',
  });
  setSupabaseClientForTest(null);

  const upd = fake._writes.find((w) => w.table === 'radio_events' && w.op === 'update');
  assert.ok(upd, '帶 eventId 時應該走 update 而不是 insert');
  assert.equal('elder_id' in upd.payload, false, 'UPDATE 不能帶 elder_id');
  assert.equal('device_serial' in upd.payload, false, 'UPDATE 不能帶 device_serial');
  assert.deepEqual(
    Object.keys(upd.payload).sort(),
    ['severity', 'status'],
    '升級＝狀態轉換，只該翻 status 與 severity',
  );
  assert.equal(
    fake._writes.some((w) => w.table === 'radio_events' && w.op === 'insert'),
    false,
    '帶 eventId 時不該另外插一筆事件',
  );
});

test('沒有 eventId（SOS 立即升級）時走 insert，且欄位齊全合法', async () => {
  const { fake, dispatch } = setup();
  await dispatch.escalateEmergency({ deviceSerial: 'JS-0001', keyword: 'sos' });
  setSupabaseClientForTest(null);

  const ins = fake._writes.find((w) => w.table === 'radio_events' && w.op === 'insert');
  assert.ok(ins, '沒有 eventId 就該 insert 一筆');
  const unknown = Object.keys(ins.payload).filter((k) => !RADIO_EVENT_COLUMNS.has(k));
  assert.deepEqual(unknown, [], `寫了 radio_events 沒有的欄位：${unknown.join(', ')}`);
  assert.equal(ins.payload.status, 'escalated');
  assert.equal(ins.payload.severity, 'emergency');
  assert.equal(ins.payload.type, 'sos', '關鍵字 sos 要對應 type=sos');
});
