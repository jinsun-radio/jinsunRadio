// 派遣整合層 —— Emergency/Needs Agent 的決策在這裡「落地」成既有系統的資料，
// 從而觸發家屬 App／志工 App／社工後台的即時推播（三端已訂閱 Supabase Realtime）。
//
// 寫入既有兩張表（見 cloud/supabase/schema.sql）：
//   radio_events   （type=sos/fall_suspected/supply_request；trigger 會補 elder_id、更新長輩 severity）
//   dispatch_tasks （kind=emergency/supply；三端即時收到）
//
// 沒有 @supabase/supabase-js 或缺憑證時 → dry-run（印 log），讓狀態機/測試仍可跑。
// 正式對應：Step Functions + DynamoDB + AppSync。

const URL = process.env.SUPABASE_URL || 'https://ykfxmoubynnbhnburawl.supabase.co';
// 接受多種命名：SERVICE_KEY（舊）／SECRET_KEY（新 sb_secret_）；最後才退到 anon（寫不了派遣單）。
const KEY =
  process.env.SUPABASE_SERVICE_KEY ||
  process.env.SUPABASE_SECRET_KEY ||
  process.env.SUPABASE_ANON_KEY ||
  '';

let _sb = null;
let _mode = 'dryrun';

// 「即時亮單」廣播：Postgres Changes（WAL 回放）到三端要 1~3 秒、行動網路更久，達不到
// 「收音機一觸發、網頁 2 秒內出現任務單」。所以每次寫完事件／派遣單，另外用 Realtime
// Broadcast（次秒級）打一則到 App 也在聽的 'jinsun-signal' 頻道，App 收到就立刻重抓對應表，
// 不必等 WAL。走 REST broadcast 端點（無狀態、server 端最省），fire-and-forget、失敗不影響 DB。
async function broadcastFast(event, payload) {
  if (!KEY) return;
  try {
    await fetch(`${URL}/realtime/v1/api/broadcast`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: KEY,
        Authorization: `Bearer ${KEY}`,
      },
      body: JSON.stringify({
        messages: [{ topic: 'jinsun-signal', event, payload: payload || {} }],
      }),
    });
  } catch {
    // 廣播失敗就退回 App 的 Postgres Changes／輪詢，不致命
  }
}

// 測試注入點：setSupabaseClientForTest(fake) 之後 client() 直接回傳假 client，
// 不去 import @supabase/supabase-js、不連真庫。傳 null 還原。
// 之所以需要這個：escalateEmergency 的 payload 曾兩次寫錯欄位（note 不存在、
// UPDATE 誤帶 elder_id 把 trigger 補好的值蓋成 null），兩次都是上線後才發現。
export function setSupabaseClientForTest(fake) {
  _sb = fake === null ? null : fake;
  _mode = fake ? 'live' : 'dryrun';
}

async function client() {
  if (_sb !== null) return _sb;
  if (!KEY) {
    _sb = false;
    return false;
  }
  try {
    const { createClient } = await import('@supabase/supabase-js');
    _sb = createClient(URL, KEY, { auth: { persistSession: false } });
    _mode = 'live';
    return _sb;
  } catch {
    _sb = false;
    return false;
  }
}

/** 同一長輩若已有未結案的同類派遣單，回傳其 id，否則 null（避免重複開單）。 */
async function existingOpenTaskId(sb, elderId, kind) {
  if (!elderId) return null;
  try {
    const { data } = await sb
      .from('dispatch_tasks')
      .select('id')
      .eq('elder_id', elderId)
      .eq('kind', kind)
      .neq('status', 'resolved')
      .limit(1)
      .maybeSingle();
    return data?.id || null;
  } catch {
    return null;
  }
}

// ---- 就近派單（鏡射 Dart models.dart 的 estimateEtaMinutes / pickVolunteer）----
function _haversineKm(lat1, lng1, lat2, lng2) {
  const r = 6371;
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(lat2 - lat1);
  const dLng = rad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) ** 2;
  return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** 抵達分鐘（機車市區均速 18km/h、道路係數 1.3；座標未知回 5）。 */
function _estimateEta(fromLat, fromLng, toLat, toLng) {
  if ((!fromLat && !fromLng) || (!toLat && !toLng)) return 5;
  const roadKm = _haversineKm(fromLat, fromLng, toLat, toLng) * 1.3;
  return Math.min(120, Math.max(1, Math.ceil((roadKm / 18) * 60)));
}

/** 志工目前是否在可服務時段內（service_hours jsonb；weekday 1=一…7=日）。 */
function _availableNow(serviceHours) {
  const now = new Date();
  const wd = now.getDay() === 0 ? 7 : now.getDay();
  const h = now.getHours();
  return (serviceHours || []).some(
    (s) =>
      (s.weekdays || []).includes(wd) &&
      (s.start <= s.end ? h >= s.start && h < s.end : h >= s.start || h < s.end),
  );
}

/**
 * 緊急單就近派單：依距離＋志工在辦任務量挑最適合者（鏡射 Dart pickVolunteer）。
 * 篩上線且有座標→優先可服務時段內→dispatchScore(eta + load*8) 最低者。查無回 null。
 */
async function pickVolunteerName(sb, elderId) {
  try {
    if (!elderId) return null;
    const el = await sb
      .from('elders')
      .select('lat,lng')
      .eq('id', elderId)
      .maybeSingle();
    const elat = el.data?.lat || 0;
    const elng = el.data?.lng || 0;
    if (!elat && !elng) return null;
    const vs = await sb
      .from('volunteers')
      .select('name,lat,lng,online,service_hours');
    let cands = (vs.data || []).filter(
      (v) => v.online && !(!v.lat && !v.lng),
    );
    if (!cands.length) return null;
    const avail = cands.filter((v) => _availableNow(v.service_hours));
    const pool = avail.length ? avail : cands;
    const tasks = await sb
      .from('dispatch_tasks')
      .select('assignee_name,status')
      .neq('status', 'resolved');
    const loadOf = (name) =>
      (tasks.data || []).filter((t) => t.assignee_name === name).length;
    const score = (v) =>
      _estimateEta(v.lat, v.lng, elat, elng) + loadOf(v.name) * 8;
    pool.sort((a, b) => score(a) - score(b));
    return pool[0]?.name || null;
  } catch {
    return null;
  }
}

/** 值班中、單量最少的社工（鏡射 Dart 端 pickWorker）；dry-run 時回 null。 */
async function pickWorkerName(sb) {
  try {
    const { data } = await sb.from('social_workers').select('*');
    if (!data?.length) return null;
    const h = new Date().getHours();
    const onDuty = data.filter((w) =>
      w.shift_start_hour <= w.shift_end_hour
        ? h >= w.shift_start_hour && h < w.shift_end_hour
        : h >= w.shift_start_hour || h < w.shift_end_hour,
    );
    return (onDuty[0] || data[0]).name;
  } catch {
    return null;
  }
}

export function createDispatch() {
  return {
    get mode() {
      return _mode;
    },

    /** 啟動時先探測一次連線，讓 /health 與啟動日誌回報真實模式（live / dryrun）。 */
    async ready() {
      await client();
      return _mode;
    },

    /**
     * 疑似事件「AI 詢問中」——偵測到就先寫一列 open/attention，**不開派遣單**。
     *
     * 為什麼要有這一步：升級是 20 秒後才發生的，如果那 20 秒完全不寫 Supabase，
     * 家屬在長輩倒在地上的黃金時間看到的是「今天一切安好」。先寫 attention，
     * 家屬端就會出現「AI 確認中」卡（見 family_app home_page 的 RadioEventStatus.open 判斷），
     * 社工後台也會轉成「注意」。20 秒後 escalateEmergency 會**更新同一列**而不是插新的。
     *
     * 回傳 eventId（dryrun 或寫入失敗回 null，呼叫端照舊往下走，不因此中斷黃金鏈路）。
     */
    async openAsking({ deviceSerial, elderId, keyword, transcript }) {
      const sb = await client();
      const type = keyword === '救命' || keyword === 'sos' ? 'sos' : 'fall_suspected';
      if (!sb) {
        console.log('[dispatch:dryrun] AI 詢問中 →', { deviceSerial, elderId, type });
        return null;
      }
      const evt = await sb
        .from('radio_events')
        .insert({
          elder_id: elderId || null,
          device_serial: deviceSerial || null,
          type,
          status: 'open',
          severity: 'attention',
          transcript: transcript || keyword,
          // ⚠️ radio_events 沒有 note 欄位（schema.sql:128）。Dart 端 _insertEvent 收了
          // note: 參數卻沒寫進 row，看起來像有這欄位——照抄會被 PostgREST 打回 42703。
        })
        .select()
        .single();
      if (evt.error) {
        console.error('[dispatch] 寫「AI 詢問中」事件失敗：', evt.error.message);
        return null;
      }
      console.log(`[dispatch] ⏳ AI 詢問中已寫入：event=${evt.data?.id}（家屬端出現確認卡）`);
      broadcastFast('sync', { tables: ['radio_events', 'elders'] });
      return evt.data?.id;
    },

    /**
     * 升級成緊急派遣單。回傳 { eventId, taskId, etaMinutes? }。
     * 帶 [eventId]（openAsking 拿到的那筆）時**更新**該列而非插新的，避免同一次跌倒留下兩筆事件。
     */
    async escalateEmergency({ deviceSerial, elderId, keyword, transcript, eventId: askingId }) {
      const sb = await client();
      const type = keyword === '救命' || keyword === 'sos' ? 'sos' : 'fall_suspected';
      if (!sb) {
        console.log('[dispatch:dryrun] 緊急升級 →', { deviceSerial, elderId, type, transcript });
        return { eventId: 'dry-event', taskId: 'dry-task' };
      }
      // 升級＝狀態轉換，只翻這兩個欄位。
      // ⚠️ 千萬不要在 UPDATE 裡帶 elder_id／device_serial：openAsking 是用 device_serial
      // 插入的（elder_id 為 null），由 fn_on_radio_event trigger 在 INSERT 時補上 elder_id。
      // UPDATE 時若再送一次 elder_id（server 手上通常只有 deviceSerial → 值是 null），
      // 就會把 trigger 補好的 elder_id 蓋回 null，接著 pickVolunteerName 找不到長輩座標
      // → 沒人被派、dispatch_tasks.elder_id 也是 null → 志工 App 顯示「長輩（0 歲）」。
      const escalatedFields = { status: 'escalated', severity: 'emergency' };
      // 有 askingId → 把「AI 詢問中」那列升級掉；沒有（SOS 立即升級路徑）→ 直接插一列。
      const evt = askingId
        ? await sb
            .from('radio_events')
            .update(escalatedFields)
            .eq('id', askingId)
            .select()
            .single()
        : await sb
            .from('radio_events')
            .insert({
              elder_id: elderId || null,
              device_serial: deviceSerial || null,
              type,
              transcript: transcript || keyword,
              ...escalatedFields,
            })
            .select()
            .single();
      if (evt.error) console.error('[dispatch] 寫 radio_events 失敗：', evt.error.message);
      const eventId = evt.data?.id || askingId;
      const elderIdResolved = evt.data?.elder_id || elderId;
      // ⚠️ 升級走 radio_events UPDATE，而 severity 同步到 elders 的 trigger 只在 INSERT 時跑，
      // 所以這裡必須手動把長輩本人轉緊急（否則家屬首頁/後台 dashboard 吃 elder.severity 排序上色
      // 的長輩會停在「注意」🟡，永遠不轉🔴——黃金鏈路最關鍵的可見結果會在正式站失效）。
      if (elderIdResolved) {
        const upE = await sb
          .from('elders')
          .update({ severity: 'emergency' })
          .eq('id', elderIdResolved);
        if (upE.error) console.error('[dispatch] 更新長輩 severity=emergency 失敗：', upE.error.message);
      }
      // 同長輩已有進行中的緊急單 → 不重複開（事件仍記錄，只是不再多開一張派遣單）
      const dupE = await existingOpenTaskId(sb, elderIdResolved, 'emergency');
      if (dupE) {
        console.log(`[dispatch] 同長輩已有進行中緊急單，不重複開：task=${dupE}`);
        broadcastFast('sync', { tables: ['radio_events', 'elders'] });
        return { eventId, taskId: dupE };
      }
      const workerName = await pickWorkerName(sb);
      // 就近派單：依距離＋在辦任務量指派最適合志工，60 秒未接再退回全體廣播（offered_until）。
      const assignee = await pickVolunteerName(sb, elderIdResolved);
      const offeredUntil = assignee
        ? new Date(Date.now() + 60 * 1000).toISOString()
        : null;
      const task = await sb
        .from('dispatch_tasks')
        .insert({
          elder_id: elderIdResolved,
          event_id: eventId,
          kind: 'emergency',
          status: 'pending',
          worker_name: workerName,
          assignee_name: assignee,
          offered_until: offeredUntil,
        })
        .select()
        .single();
      if (task.error) console.error('[dispatch] 寫 dispatch_tasks 失敗：', task.error.message);
      else console.log(`[dispatch] ✅ 緊急派遣單已開：event=${eventId} task=${task.data?.id} 就近派給=${assignee || '（全體廣播）'}`);
      // 次秒級廣播：三端不必等 1~3 秒的 Postgres Changes，收到就立刻抓到這張新緊急單。
      broadcastFast('sync', { tables: ['radio_events', 'dispatch_tasks', 'elders'] });
      return { eventId, taskId: task.data?.id };
    },

    /** 建立物資／代辦派遣單。 */
    async createSupply({ deviceSerial, elderId, items, transcript }) {
      const sb = await client();
      if (!sb) {
        console.log('[dispatch:dryrun] 物資需求 →', { deviceSerial, elderId, items });
        return { eventId: 'dry-event', taskId: 'dry-task' };
      }
      const evt = await sb
        .from('radio_events')
        .insert({
          elder_id: elderId || null,
          device_serial: deviceSerial || null,
          type: 'supply_request',
          status: 'open',
          severity: 'normal',
          transcript: transcript || `我想要${(items || []).join('、')}`,
        })
        .select()
        .single();
      if (evt.error) console.error('[dispatch] 寫 radio_events 失敗：', evt.error.message);
      const eventId = evt.data?.id;
      const elderIdResolved = evt.data?.elder_id || elderId;
      const dupS = await existingOpenTaskId(sb, elderIdResolved, 'supply');
      if (dupS) {
        console.log(`[dispatch] 同長輩已有進行中物資單，不重複開：task=${dupS}`);
        broadcastFast('sync', { tables: ['radio_events'] });
        return { eventId, taskId: dupS };
      }
      // 物資單 3 分鐘寬限：先 offer 給督導志工＋通知家屬，不廣播全體；
      // 到期或家屬/社工按「請求支援」才開放全體接單（見前端 offered_until 邏輯）。
      let supervisor = null;
      if (elderIdResolved) {
        const el = await sb
          .from('elders')
          .select('supervisor_volunteer_name')
          .eq('id', elderIdResolved)
          .maybeSingle();
        supervisor = el.data?.supervisor_volunteer_name || null;
      }
      const offeredUntil = new Date(Date.now() + 3 * 60 * 1000).toISOString();
      const task = await sb
        .from('dispatch_tasks')
        .insert({
          elder_id: elderIdResolved,
          event_id: eventId,
          kind: 'supply',
          status: 'pending',
          items: items || [],
          offered_until: offeredUntil,
          assignee_name: supervisor,
        })
        .select()
        .single();
      if (task.error) console.error('[dispatch] 寫 dispatch_tasks 失敗：', task.error.message);
      else console.log(`[dispatch] ✅ 物資派遣單已開：event=${eventId} task=${task.data?.id} items=${(items||[]).join('、')}`);
      broadcastFast('sync', { tables: ['radio_events', 'dispatch_tasks'] });
      return { eventId, taskId: task.data?.id };
    },

    /**
     * 被動感知回報（非長輩主動求助，不進 orchestrator）：
     *   - activity_report：每日人形活動彙整 → 只更新 elders.last_activity_at
     *     （家屬端「最後偵測到活動」據此），不寫事件、不派工、無 reply。
     *   - inactivity_suspected：日間連續 6 小時未偵測到人形 → 把長輩升成「注意」，
     *     家屬 App／社工後台立即亮「注意」（不派志工）。**只在目前是 normal 時升**，
     *     絕不覆蓋既有 emergency（避免把真跌倒降級）。
     * 這兩個事件 event_type_t enum 沒有對應值，硬塞 fall_suspected 會謊報成跌倒，
     * 因此走 elders 欄位而非 radio_events；回傳是否有實際寫入（dryrun/失敗回 false）。
     */
    async recordPresence({ deviceSerial, elderId, event }) {
      const sb = await client();
      if (!sb) {
        console.log('[dispatch:dryrun] presence →', { deviceSerial, elderId, event });
        return false;
      }
      // 用 device_serial 或 elder_id 定位那一列（兩者擇一即可）
      const match = (q) =>
        elderId ? q.eq('id', elderId) : q.eq('device_serial', deviceSerial);
      try {
        if (event === 'activity_report') {
          const r = await match(
            sb.from('elders').update({ last_activity_at: new Date().toISOString() }),
          );
          if (r.error) throw r.error;
          return true;
        }
        if (event === 'inactivity_suspected') {
          // 只升 normal → attention；emergency/attention 維持不動
          const r = await match(
            sb.from('elders').update({ severity: 'attention' }).eq('severity', 'normal'),
          );
          if (r.error) throw r.error;
          console.log(`[dispatch] ⚠️ 久未偵測到活動 → 長輩升「注意」（device=${deviceSerial || elderId}）`);
          broadcastFast('sync', { tables: ['elders'] });
          return true;
        }
      } catch (e) {
        console.error('[dispatch] recordPresence 失敗：', e.message || e);
      }
      return false;
    },
  };
}
