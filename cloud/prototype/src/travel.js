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

const URL = process.env.SUPABASE_URL || 'https://ykfxmoubynnbhnburawl.supabase.co';
const KEY =
  process.env.SUPABASE_SERVICE_KEY ||
  process.env.SUPABASE_SECRET_KEY ||
  process.env.SUPABASE_ANON_KEY ||
  '';

const STEP_MS = Number(process.env.TRAVEL_STEP_MS) || 2000; // 每步間隔
const STEPS = Number(process.env.TRAVEL_STEPS) || 12; // 幾步走完全程（12×2s＝24s）

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

export function createTravelSimulator({ log = console.log } = {}) {
  let sb = null;
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

  return {
    async start() {
      if ((process.env.DEMO_TRAVEL || '1') === '0') {
        log('[travel] DEMO_TRAVEL=0 → 志工移動模擬停用（由真實 GPS 驅動）');
        return 'off';
      }
      if (!KEY) {
        log('[travel] 無 Supabase 憑證 → 移動模擬停用');
        return 'dryrun';
      }
      let createClient;
      try {
        ({ createClient } = await import('@supabase/supabase-js'));
      } catch {
        log('[travel] 未安裝 @supabase/supabase-js → 移動模擬停用');
        return 'dryrun';
      }
      sb = createClient(URL, KEY, { auth: { persistSession: false } });
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
    },
    simulate, // 測試用
  };
}
