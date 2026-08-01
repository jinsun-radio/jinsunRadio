// 長輪詢下行佇列 —— 模擬器／對測通道（sim.html 與 curl 用），真韌體走 MQTT push（見 mqtt.js）。
//
// 為什麼保留：急救逾時階梯的第 2、3 句（「我沒有聽到您…」「已經幫您叫人…」）是在
// HTTP 回應「之後」才產生的，單靠 POST /voice 的同步回應送不出去；瀏覽器版模擬控制台
// 連不了 raw MQTT，所以留這條 GET /commands 長輪詢。server 端 enqueue 是扇出
// （mqtt.js 的 createFanoutDownlink）：同一筆指令 MQTT 與這裡都會投遞。

export function createDownlink({
  timeoutMs = 25000,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
} = {}) {
  /** @type {Map<string, object[]>} serial -> 待送指令 */
  const queues = new Map();
  /** @type {Map<string, Array<{resolve:Function, timer:any}>>} serial -> 等待中的長輪詢 */
  const waiters = new Map();

  const q = (s) => {
    if (!queues.has(s)) queues.set(s, []);
    return queues.get(s);
  };

  /** server 端把一個指令推給某台裝置（有人在等就直接喚醒，否則入列）。 */
  function enqueue(serial, cmd) {
    const arr = waiters.get(serial);
    if (arr && arr.length) {
      const { resolve, timer } = arr.shift();
      clearTimer(timer);
      resolve([cmd]);
      return;
    }
    q(serial).push(cmd);
  }

  /** 裝置長輪詢：有貨立刻回；沒有就 hold 到逾時回 []。 */
  function pull(serial, { timeoutMs: t = timeoutMs } = {}) {
    const pending = q(serial);
    if (pending.length) return Promise.resolve(pending.splice(0));
    return new Promise((resolve) => {
      const entry = { resolve: null, timer: null };
      entry.timer = setTimer(() => {
        const arr = waiters.get(serial) || [];
        const i = arr.indexOf(entry);
        if (i >= 0) arr.splice(i, 1);
        resolve([]);
      }, t);
      entry.resolve = resolve;
      if (!waiters.has(serial)) waiters.set(serial, []);
      waiters.get(serial).push(entry);
    });
  }

  /** 目前等列長度（測試/監控用）。 */
  const pending = (serial) => q(serial).length;

  return { enqueue, pull, pending, _queues: queues, _waiters: waiters };
}
