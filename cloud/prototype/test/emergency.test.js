// 黃金時間鏈路合約測試：不呼叫真 LLM / Supabase，用注入的假計時器同步推進階梯。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createOrchestrator } from '../src/orchestrator.js';
import { createDispatch } from '../src/dispatch.js';

// 假計時器：立即記錄 callback，由 flush() 手動、依序觸發，測試不需真的等秒數。
function fakeTimers() {
  const queue = [];
  const setTimer = (fn, ms) => {
    const t = { ms, fn, cancelled: false };
    queue.push(t);
    return t;
  };
  const clearTimer = (t) => t && (t.cancelled = true);
  async function flushNext() {
    const t = queue.find((x) => !x.cancelled && !x.done);
    if (!t) return false;
    t.done = true;
    await t.fn();
    return true;
  }
  async function flushAll() {
    let n = 0;
    while (await flushNext()) if (++n > 20) break;
  }
  return { setTimer, clearTimer, flushNext, flushAll, queue };
}

// 攔截派遣層：不寫 Supabase，只記錄有沒有被叫到。
function spyDispatch() {
  const calls = [];
  return {
    mode: 'test',
    escalateEmergency: async (ctx) => {
      calls.push(['escalate', ctx]);
      return { eventId: 'e1', taskId: 't1', etaMinutes: 6 };
    },
    createSupply: async (ctx) => {
      calls.push(['supply', ctx]);
      return { eventId: 'e2', taskId: 't2' };
    },
    openAsking: async (ctx) => {
      calls.push(['asking', ctx]);
      return 'asking-1';
    },
    _calls: calls,
  };
}

function build() {
  const timers = fakeTimers();
  const dispatch = spyDispatch();
  const spoken = [];
  const orch = createOrchestrator({
    dispatch,
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
    speak: async (k, t) => spoken.push(t),
  });
  return { orch, dispatch, timers, spoken };
}

test('「我跌倒了」立即進急救對話，並先安撫', async () => {
  const { orch } = build();
  const out = await orch.handle({ deviceSerial: 'JS-0001', text: '我跌倒了' });
  assert.equal(out.intent, 'emergency');
  assert.match(out.reply, /還好嗎|我在這裡/);
});

test('無回應跑完逾時階梯 → 必定升級派遣（黃金時間合約）', async () => {
  const { orch, dispatch, timers } = build();
  await orch.handle({ deviceSerial: 'JS-0001', text: '救命' });
  await timers.flushAll(); // 推進整個階梯到最後一階
  const escalated = dispatch._calls.filter((c) => c[0] === 'escalate');
  assert.equal(escalated.length, 1, '階梯跑完必須升級一次');
});

test('偵測到就先寫「AI 詢問中」→ 家屬不必等 20 秒才看到有事發生', async () => {
  const { orch, dispatch, timers } = build();
  await orch.handle({ deviceSerial: 'JS-0001', text: '我跌倒了' });
  // 還沒推進任何計時器（＝還在黃金 20 秒內）就該已經寫入 attention 事件
  const asking = dispatch._calls.filter((c) => c[0] === 'asking');
  assert.equal(asking.length, 1, '詢問階段就要寫一筆，不能等到升級才寫');
  assert.equal(
    dispatch._calls.filter((c) => c[0] === 'escalate').length,
    0,
    '這個時間點還不該升級',
  );
  await timers.flushAll();
  const escalated = dispatch._calls.filter((c) => c[0] === 'escalate');
  assert.equal(escalated.length, 1);
  assert.equal(
    escalated[0][1].eventId,
    'asking-1',
    '升級必須帶著詢問階段的 eventId（更新同一列，不另外插一筆）',
  );
});

test('openAsking 寫入失敗不得中斷升級鏈路（黃金時間優先）', async () => {
  const timers = fakeTimers();
  const dispatch = spyDispatch();
  dispatch.openAsking = async () => {
    throw new Error('supabase down');
  };
  const orch = createOrchestrator({
    dispatch,
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
    speak: async () => {},
  });
  await orch.handle({ deviceSerial: 'JS-0001', text: '我跌倒了' });
  await timers.flushAll();
  const escalated = dispatch._calls.filter((c) => c[0] === 'escalate');
  assert.equal(escalated.length, 1, 'attention 寫不進去，仍然必須照常升級');
  assert.equal(escalated[0][1].eventId, undefined, '沒有 eventId 就走插入新列的路徑');
});

test('實體 SOS 鍵 immediate → 同步立刻升級，不需等逾時階梯', async () => {
  const { orch, dispatch, timers } = build();
  const out = await orch.handle({ deviceSerial: 'JS-0001', text: '救命', immediate: true });
  assert.equal(out.action.type, 'emergency_escalated');
  assert.equal(dispatch._calls.filter((c) => c[0] === 'escalate').length, 1, '按下即升級一次');
  // immediate 不排逾時階梯；僅保留一個「session 過期兜底清除」計時器（15 分鐘）。
  const pending = timers.queue.filter((t) => !t.cancelled);
  assert.equal(pending.length, 1, '不留逾時階梯，只留 session 過期清除計時器');
  assert.ok(pending[0].ms >= 60000, '留下的是過期清除（長時距），非逾時階梯');
});

test('長輩中途說「我沒事」→ 解除，不升級', async () => {
  const { orch, dispatch, timers } = build();
  await orch.handle({ deviceSerial: 'JS-0001', text: '救命' });
  const out = await orch.handle({ deviceSerial: 'JS-0001', text: '我沒事啦' });
  assert.equal(out.action.type, 'emergency_standdown');
  await timers.flushAll();
  assert.equal(dispatch._calls.filter((c) => c[0] === 'escalate').length, 0, '已解除就不該升級');
});

test('「我想買牛奶跟雞蛋」→ 建立物資派遣單', async () => {
  const { orch, dispatch } = build();
  const out = await orch.handle({ deviceSerial: 'JS-0001', text: '我想買牛奶跟雞蛋' });
  assert.equal(out.intent, 'need');
  assert.equal(dispatch._calls.filter((c) => c[0] === 'supply').length, 1);
});

test('「音量大一點」→ 裝置指令 volume_up，不派遣', async () => {
  const { orch, dispatch } = build();
  const out = await orch.handle({ deviceSerial: 'JS-0001', text: '音量大一點' });
  assert.equal(out.intent, 'device');
  assert.equal(out.action.command, 'volume_up');
  assert.equal(dispatch._calls.length, 0);
});

test('「今天星期幾」→ 一般聊天，不派遣', async () => {
  const { orch, dispatch } = build();
  const out = await orch.handle({ deviceSerial: 'JS-0001', text: '今天星期幾' });
  assert.equal(out.intent, 'general');
  assert.equal(dispatch._calls.length, 0);
});

test('dispatch dry-run 模式不需憑證即可回應', async () => {
  const d = createDispatch();
  const r = await d.escalateEmergency({ deviceSerial: 'JS-0001', keyword: '救命', transcript: '救命' });
  assert.ok(r.eventId);
});
