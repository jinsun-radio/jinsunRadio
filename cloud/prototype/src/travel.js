// 志工移動模擬（demo 用）—— 讓家屬 App 像 Uber 一樣看到志工「實際移動」。
//
// 為什麼需要：真實情境靠志工 App 的 GPS 上報位置（LocationPublisher → volunteers 表），
// 家屬地圖即時看到志工移動。但 demo 沒有人真的騎車，志工座標是靜止的。
// 這個 worker 訂閱 dispatch_tasks，當某單被「接單(accepted)」時，就把被派志工的座標
// 沿「起點→長輩家」逐步內插寫回 volunteers 表（每 2 秒一步），並同步倒數 eta_minutes，
// 走到終點就把單標成 arrived（觸發 progress.js 念「志工到囉」）。三端經 Realtime 即時反映。
//
// 以 DEMO_TRAVEL=0 關閉（正式版由真實 GPS 驅動，不需要模擬）。
// 正式對應：真裝置 GPS → IoT Core → 位置更新，無需本模組。
//
// 資料層走 db.js 轉接層（DB_BACKEND=supabase|aurora），兩套環境共用同一段查詢程式碼。
// 觸發來源依後端能力自動選擇：Supabase 有 Realtime 就訂閱；Aurora 沒有，改輪詢
// 「status=accepted 的單」。輪詢不是降級——simulate() 本來就自帶 active 去重與
// 每步狀態複查，重複觸發同一單會被擋掉。

import { createDbClient, dbConfigured, dbBackend } from './db.js';

const STEP_MS = Number(process.env.TRAVEL_STEP_MS) || 2000; // 每步間隔
const STEPS = Number(process.env.TRAVEL_STEPS) || 12; // 幾步走完全程（12×2s＝24s）
/** 無 Realtime 時的掃描間隔。志工接單到家屬看到車子開始動，最多差這麼久。 */
const POLL_MS = Number(process.env.TRAVEL_POLL_MS) || 3000;

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

export function createTravelSimulator({ log = console.log, client = null } = {}) {
  let sb = client;
  let poller = null;
  const active = new Set(); // 進行中的 taskId，避免同一單重複啟動

  async function one(table, id, cols) {
    const { data } = await sb.from(table).select(cols).eq('id', id).maybeSingle();
    return data;
  }

  async function simulate(row) {
    const taskId = row.id;
    if (!taskId || active.has(taskId)) return;
    if (row.status !== 'accepted' || !row.assignee_name) return;

    const { data: vol } = await sb
      .from('volunteers')
      .select('id,lat,lng')
      .eq('name', row.assignee_name)
      .maybeSingle();
    const el = await one('elders', row.elder_id, 'lat,lng');
    if (!vol || !el || (!el.lat && !el.lng)) return;

    active.add(taskId);
    const sLat = vol.lat || 0;
    const sLng = vol.lng || 0;
    const eLat = el.lat;
    const eLng = el.lng;
    const eta0 = row.eta_minutes || STEPS;
    log(`[travel] ${row.assignee_name} 出發前往 ${row.elder_id}（起點 ${sLat.toFixed(4)},${sLng.toFixed(4)}）`);

    for (let i = 1; i <= STEPS; i++) {
      await delay(STEP_MS);
      // 每步先確認單子還在 accepted 且仍是同一位志工（可能已結案/釋出/抵達）
      const cur = await one('dispatch_tasks', taskId, 'status,assignee_name');
      if (!cur || cur.status !== 'accepted' || cur.assignee_name !== row.assignee_name) {
        log(`[travel] ${taskId} 不再 accepted，停止移動模擬`);
        active.delete(taskId);
        return;
      }
      const t = i / STEPS;
      const lat = sLat + (eLat - sLat) * t;
      const lng = sLng + (eLng - sLng) * t;
      await sb.from('volunteers').update({ lat, lng }).eq('id', vol.id);
      if (i < STEPS) {
        const remain = Math.max(1, Math.round((1 - t) * eta0));
        await sb.from('dispatch_tasks').update({ eta_minutes: remain }).eq('id', taskId);
      }
    }
    // 抵達 → 標記 arrived（progress.js 會念「志工到囉」）。
    // arrived_at 一定要一起寫：志工端的任務時間軸（開單→出發→到場→回報）讀這個欄位，
    // 只翻 status 的話「到場」那格會顯示「—」，明明人已經到了。App 端的 markArrived
    // 也是同時寫這兩個，這裡要跟它一致。
    await sb
      .from('dispatch_tasks')
      .update({ status: 'arrived', arrived_at: new Date().toISOString() })
      .eq('id', taskId);
    log(`[travel] ${row.assignee_name} 已抵達 ${row.elder_id}`);
    active.delete(taskId);
  }

  /** 掃一輪「已接單但還沒開始跑」的單（無 Realtime 的後端用）。 */
  async function sweep() {
    const { data, error } = await sb
      .from('dispatch_tasks')
      .select('id,status,assignee_name,elder_id,eta_minutes')
      .eq('status', 'accepted');
    if (error) {
      log(`[travel] 掃描失敗：${error.message}`);
      return;
    }
    for (const row of data || []) {
      if (active.has(row.id)) continue;
      simulate(row).catch((e) => log(`[travel] 失敗：${e?.message || e}`));
    }
  }

  return {
    async start() {
      if ((process.env.DEMO_TRAVEL || '1') === '0') {
        log('[travel] DEMO_TRAVEL=0 → 志工移動模擬停用（由真實 GPS 驅動）');
        return 'off';
      }
      if (!dbConfigured()) {
        log(`[travel] 無 ${dbBackend} 憑證 → 移動模擬停用`);
        return 'dryrun';
      }
      sb = sb || (await createDbClient());
      if (!sb) {
        log('[travel] 資料層不可用 → 移動模擬停用');
        return 'dryrun';
      }
      // Supabase：訂閱 Realtime，接單當下就出發。
      if (typeof sb.channel === 'function') {
        sb.channel('travel:dispatch_tasks')
          .on(
            'postgres_changes',
            { event: 'UPDATE', schema: 'public', table: 'dispatch_tasks' },
            (p) => {
              if (p.new?.status === 'accepted') {
                simulate(p.new).catch((e) => log(`[travel] 失敗：${e?.message || e}`));
              }
            },
          )
          .subscribe((st) => log(`[travel] realtime 訂閱：${st}`));
        return 'live';
      }
      // Aurora（Data API）：沒有 Realtime，改輪詢已接單的派遣單。
      poller = setInterval(() => {
        sweep().catch((e) => log(`[travel] 掃描失敗：${e?.message || e}`));
      }, POLL_MS);
      if (typeof poller.unref === 'function') poller.unref(); // 不擋 process 結束
      log(`[travel] ${dbBackend} 無 Realtime → 每 ${POLL_MS}ms 輪詢已接單的派遣單`);
      return 'live';
    },
    stop() {
      if (poller) clearInterval(poller);
      poller = null;
    },
    simulate, // 測試用
    sweep, // 測試用
  };
}
