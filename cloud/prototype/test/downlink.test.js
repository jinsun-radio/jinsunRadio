// 下行通道測試：有貨立刻回、無貨長輪詢等到 enqueue 才回、逾時回空。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createDownlink } from '../src/downlink.js';

function fakeTimers() {
  const q = [];
  return {
    setTimer: (fn, ms) => {
      const t = { fn, ms, cancelled: false };
      q.push(t);
      return t;
    },
    clearTimer: (t) => t && (t.cancelled = true),
    fire: async () => {
      for (const t of q) if (!t.cancelled && !t.done) { t.done = true; await t.fn(); }
    },
  };
}

test('已有指令 → pull 立刻回並清空', async () => {
  const d = createDownlink();
  d.enqueue('JS-0001', { type: 'speak', text: 'hi' });
  const cmds = await d.pull('JS-0001');
  assert.equal(cmds.length, 1);
  assert.equal(cmds[0].text, 'hi');
  assert.equal(d.pending('JS-0001'), 0);
});

test('無指令 → 長輪詢 hold，enqueue 後才回', async () => {
  const d = createDownlink();
  const p = d.pull('JS-0001'); // 尚未有貨，掛著
  d.enqueue('JS-0001', { type: 'device', command: 'volume_up' });
  const cmds = await p;
  assert.equal(cmds[0].command, 'volume_up');
});

test('逾時 → 回空陣列', async () => {
  const ft = fakeTimers();
  const d = createDownlink({ setTimer: ft.setTimer, clearTimer: ft.clearTimer });
  const p = d.pull('JS-0001');
  await ft.fire(); // 觸發逾時
  assert.deepEqual(await p, []);
});

test('裝置不同序號互不干擾', async () => {
  const d = createDownlink();
  d.enqueue('JS-0001', { type: 'speak', text: 'a' });
  assert.equal((await d.pull('JS-0002', { timeoutMs: 1 })).length, 0);
  assert.equal((await d.pull('JS-0001')).length, 1);
});
