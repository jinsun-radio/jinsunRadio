// jinsun-data —— 三端 App 的資料 API（取代 Supabase PostgREST + Realtime）。
//
// 三個端點：
//   GET  /data/version   極輕量的變更指紋（每張表一個 md5）。App 每 3 秒打一次，
//                        指紋沒變就不抓快照——這是「即時同步」的成本控制點。
//   GET  /data/snapshot  一次回全部集合（依角色過濾），**單次 Data API 往返**：
//                        用 json_agg 把六張表包成同一列的六個欄位。
//   POST /data/mutate    具名寫入操作，{ op, args }。可寫欄位寫死在 ops.mjs。
//
// 為什麼是輪詢而不是 AppSync 訂閱：跌倒升級開單是後端 Lambda 直接寫 Aurora 的，
// 不經過 AppSync mutation，所以 GraphQL subscription 對「最重要的那條鏈路」不會響——
// 要響就得讓每支後端 Lambda 反手再呼叫一次 AppSync。多一層耦合、多一個失敗點，
// 換來的是 3 秒 → 次秒級。這個系統的黃金窗是 20 秒，3 秒綽綽有餘。
// （設計取捨完整說明見 docs/requirements/aws-architecture.md）
//
// 身分由 API Gateway 的 Cognito JWT authorizer 驗好，claims 直接讀；
// 角色（Cognito group）→ 可見範圍的規則全在 authz.mjs，那是唯一的授權真相。

import { createAuroraSql } from './src/db.js';
import { principalFrom, readScope, checkRole, checkOwnership } from './authz.mjs';
import { createOps } from './ops.mjs';

const PROOFS_BUCKET = process.env.PROOFS_BUCKET || '';
const PROOFS_PUBLIC_BASE = process.env.PROOFS_PUBLIC_BASE || '';

let _db = null;
async function db() {
  if (_db) return _db;
  _db = await createAuroraSql();
  if (!_db) throw new Error('Aurora 未設定（AURORA_CLUSTER_ARN / AURORA_SECRET_ARN）');
  return _db;
}

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization,content-type',
  'access-control-allow-methods': 'GET,POST,OPTIONS',
};
const json = (code, obj) => ({
  statusCode: code,
  headers: { 'content-type': 'application/json; charset=utf-8', ...CORS },
  body: JSON.stringify(obj),
});

/**
 * 只送出 SQL 真的用到的參數。
 * Data API 對「宣告了卻沒用到的參數」會報錯，而述詞是依角色動態組出來的
 * （社工的 SQL 完全不含 :uid），所以這裡按實際出現的名字過濾。
 * 負向後查是為了跳過 `::uuid` 這種轉型——那不是參數。
 */
function usedParams(sql, all) {
  const names = new Set([...sql.matchAll(/(?<!:):([a-zA-Z_]\w*)/g)].map((m) => m[1]));
  return Object.fromEntries(Object.entries(all).filter(([k]) => names.has(k)));
}

// ──────────────────────────── 讀 ────────────────────────────

/**
 * 六張表的變更指紋。刻意不是 count(*)＋max(時間)——
 * 事件從 open 翻成 escalated、長輩燈號從 normal 翻成 emergency，
 * 這兩件事都不會新增列也不會動時間欄位，但它們正是最需要立刻反映到三端的變化。
 * 所以指紋要涵蓋「會影響畫面的欄位」本身。表都是幾百到幾千列，md5 掃一遍成本可忽略。
 */
function versionSql(scope) {
  return `select
    md5(coalesce((select string_agg(e.id || e.severity::text || e.preferred_lang::text
                                    || coalesce(e.note, '') || coalesce(e.supervisor_volunteer_name, ''),
                                    ',' order by e.id)
                    from elders e where ${scope.elders}), '')) as elders,
    md5(coalesce((select string_agg(ev.id::text || ev.status::text || ev.severity::text,
                                    ',' order by ev.id)
                    from radio_events ev where ${scope.events}), '')) as events,
    md5(coalesce((select string_agg(t.id::text || t.status::text || coalesce(t.assignee_name, '')
                                    || coalesce(t.eta_minutes::text, '') || coalesce(t.offered_until::text, ''),
                                    ',' order by t.id)
                    from dispatch_tasks t where ${scope.tasks}), '')) as tasks,
    md5(coalesce((select string_agg(v.id || v.lat::text || v.lng::text || v.online::text
                                    || coalesce(v.location_updated_at::text, ''),
                                    ',' order by v.id)
                    from volunteers v where ${scope.volunteers}), '')) as volunteers,
    md5(coalesce((select string_agg(m.id::text, ',' order by m.id)
                    from task_messages m where ${scope.messages}), '')) as messages,
    md5(coalesce((select string_agg(c.id::text || c.status, ',' order by c.id)
                    from call_signals c where ${scope.calls}), '')) as calls,
    md5(coalesce((select string_agg(fb.elder_id, ',' order by fb.elder_id)
                    from family_bindings fb where fb.family_id = :uid::uuid), '')) as bindings,
    md5(coalesce((select string_agg(key || '=' || coalesce(value, ''), ',' order by key)
                    from app_settings), '')) as settings`;
}

/**
 * 一次往返把六張表撈回來。json_agg 出來的 json 欄位由 db.js 的 decode 自動 parse。
 * 排序寫在 json_agg 上而不是只寫在子查詢裡：子查詢的 order by 只保證「哪些列被 limit 選中」，
 * 不保證聚合輸出的順序。三端有幾處吃順序（事件由新到舊、confirmElderOk 取最近一筆）。
 */
function snapshotSql(scope) {
  return `select
    (select coalesce(json_agg(x order by x.id), '[]'::json) from
      (select e.* from elders e where ${scope.elders}) x) as elders,
    (select coalesce(json_agg(x order by x.occurred_at desc), '[]'::json) from
      (select ev.* from radio_events ev where ${scope.events}
        order by ev.occurred_at desc limit 2000) x) as events,
    (select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from
      (select t.* from dispatch_tasks t where ${scope.tasks}
        order by t.created_at desc limit 2000) x) as tasks,
    (select coalesce(json_agg(x order by x.id), '[]'::json) from
      (select v.*,
              coalesce((select json_agg(vc) from volunteer_certificates vc
                         where vc.volunteer_id = v.id), '[]'::json) as certificates
         from volunteers v where ${scope.volunteers}) x) as volunteers,
    (select coalesce(json_agg(x order by x.id), '[]'::json) from
      (select w.* from social_workers w where ${scope.workers}) x) as workers,
    (select coalesce(json_agg(x order by x.created_at), '[]'::json) from
      (select m.* from task_messages m where ${scope.messages}
        order by m.created_at desc limit 500) x) as messages,
    (select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from
      (select c.* from call_signals c where ${scope.calls}
        order by c.created_at desc limit 200) x) as calls,
    (select coalesce(json_agg(fb.elder_id), '[]'::json) from family_bindings fb
       where fb.family_id = :uid::uuid) as bindings,
    (select coalesce(json_object_agg(key, value), '{}'::json) from app_settings) as settings`;
}

// ──────────────────────────── 入口 ────────────────────────────

export const handler = async (event) => {
  const method = event?.requestContext?.http?.method || 'GET';
  const path = event?.rawPath || '';

  if (method === 'OPTIONS') return { statusCode: 204, headers: CORS, body: '' };

  const principal = principalFrom(event);
  if (!principal.sub) return json(401, { error: '未登入' });
  if (!principal.role) {
    // 帳號建立後還沒被加進任何 Cognito group → 預設拒絕，不是預設全開。
    return json(403, { error: '帳號尚未指派角色（family / volunteer / worker）' });
  }

  const scope = readScope(principal);
  const baseParams = { uid: principal.sub, vname: principal.name || '' };

  try {
    const d = await db();

    if (method === 'GET' && path.endsWith('/version')) {
      const sql = versionSql(scope);
      const row = await d.queryOne(sql, usedParams(sql, baseParams));
      return json(200, { v: row });
    }

    if (method === 'GET' && path.endsWith('/snapshot')) {
      const sql = snapshotSql(scope);
      const row = await d.queryOne(sql, usedParams(sql, baseParams));
      return json(200, {
        role: principal.role,
        name: principal.name,
        ...row,
      });
    }

    if (method === 'POST' && path.endsWith('/mutate')) {
      let body = {};
      try { body = JSON.parse(event.body || '{}'); } catch { /* 空物件 */ }
      const { op, args = {} } = body;

      const roleErr = checkRole(op, principal);
      if (roleErr) return json(403, { error: roleErr });

      const ownErr = await checkOwnership(op, principal, args, {
        getTask: (id) =>
          id ? d.queryOne('select * from dispatch_tasks where id = :id::uuid', { id }) : null,
        taskVisible: async (id) => {
          const sql = `select 1 as ok from dispatch_tasks t where t.id = :id::uuid and ${scope.tasks}`;
          return Boolean(await d.queryOne(sql, usedParams(sql, { ...baseParams, id })));
        },
        elderVisible: async (id) => {
          const sql = `select 1 as ok from elders e where e.id = :id and ${scope.elders}`;
          return Boolean(await d.queryOne(sql, usedParams(sql, { ...baseParams, id })));
        },
      });
      if (ownErr) return json(403, { error: ownErr });

      const ops = createOps(d, principal);
      if (op === 'proofUploadUrl') return json(200, await proofUploadUrl(args));
      if (typeof ops[op] !== 'function') return json(400, { error: `未實作的操作：${op}` });
      return json(200, await ops[op](args));
    }

    if (method === 'GET' && path.endsWith('/timebank')) {
      const name = event?.queryStringParameters?.name || '';
      const row = await d.queryOne(
        'select coalesce(sum(points), 0)::int as total from time_bank_ledger where volunteer_name = :name',
        { name },
      );
      return json(200, { minutes: row?.total ?? 0 });
    }

    return json(404, { error: 'not found' });
  } catch (e) {
    const code = e?.statusCode || 500;
    if (code >= 500) console.error(e);
    return json(code, { error: String(e?.message || e) });
  }
};

/**
 * 結案證明照片：回一組 S3 presigned PUT URL，讓 App 直接把位元組傳進 S3，
 * 不經過 Lambda（照片走 API Gateway 會撞 6MB payload 上限，也白白付兩份流量）。
 * 路徑用 taskId，同一單重拍就覆蓋，不累積垃圾檔——與 Supabase Storage 版一致。
 */
async function proofUploadUrl({ taskId, contentType = 'image/jpeg' }) {
  if (!PROOFS_BUCKET) {
    const err = new Error('PROOFS_BUCKET 未設定');
    err.statusCode = 501;
    throw err;
  }
  const { S3Client, PutObjectCommand } = await import('@aws-sdk/client-s3');
  const { getSignedUrl } = await import('@aws-sdk/s3-request-presigner');
  const ext = contentType.includes('png') ? 'png' : 'jpg';
  const key = `${taskId}.${ext}`;
  const s3 = new S3Client({});
  const uploadUrl = await getSignedUrl(
    s3,
    new PutObjectCommand({ Bucket: PROOFS_BUCKET, Key: key, ContentType: contentType }),
    { expiresIn: 300 },
  );
  const base = PROOFS_PUBLIC_BASE || `https://${PROOFS_BUCKET}.s3.amazonaws.com`;
  return { uploadUrl, publicUrl: `${base.replace(/\/$/, '')}/${key}`, contentType };
}
