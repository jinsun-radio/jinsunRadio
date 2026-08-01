// 資料層轉接：讓同一份業務程式（dispatch / elders / progress / llm）能跑在兩套環境上。
//
//   DB_BACKEND=supabase（預設）→ 直接回傳真正的 Supabase client，行為與過去完全相同
//   DB_BACKEND=aurora           → 回傳一個「介面相容」的薄殼，底層走 Aurora Data API
//
// 為什麼做成介面相容而不是另開一套 API：`dispatch.js` 裡的查詢是這個系統最容易寫錯的地方
// （註解裡記著兩次上線後才發現的欄位錯誤）。讓兩套環境跑「同一段查詢程式碼」，
// 才不會修好一邊、另一邊悄悄壞掉。
//
// 只實作實際用到的 8 個方法；沒實作的一律 throw，讓遺漏當場炸開而不是回錯資料。

const BACKEND = (process.env.DB_BACKEND || 'supabase').toLowerCase();

// ---- Supabase（原環境）----
const SB_URL = process.env.SUPABASE_URL || 'https://ykfxmoubynnbhnburawl.supabase.co';
const SB_KEY =
  process.env.SUPABASE_SERVICE_KEY ||
  process.env.SUPABASE_SECRET_KEY ||
  process.env.SUPABASE_ANON_KEY ||
  '';

// ---- Aurora（AWS 環境）----
const AURORA_CLUSTER = process.env.AURORA_CLUSTER_ARN || '';
const AURORA_SECRET = process.env.AURORA_SECRET_ARN || '';
const AURORA_DB = process.env.AURORA_DB_NAME || 'jinsun';

/** 目前生效的後端名稱（給 /health 顯示用）。 */
export const dbBackend = BACKEND;

/** 有沒有足夠的憑證可以連線（沒有就讓呼叫端走 dryrun）。 */
export function dbConfigured() {
  return BACKEND === 'aurora' ? Boolean(AURORA_CLUSTER && AURORA_SECRET) : Boolean(SB_KEY);
}

/**
 * 建立資料庫 client。回傳物件的 `.from(table)` 介面與 Supabase 相容。
 * 失敗（缺套件／缺憑證）回傳 false，與既有 dispatch.js 的判斷方式一致。
 */
export async function createDbClient() {
  if (!dbConfigured()) return false;
  if (BACKEND === 'aurora') {
    try {
      const { RDSDataClient, ExecuteStatementCommand } = await import('@aws-sdk/client-rds-data');
      return auroraClient(new RDSDataClient({}), ExecuteStatementCommand);
    } catch {
      return false;
    }
  }
  try {
    const { createClient } = await import('@supabase/supabase-js');
    return createClient(SB_URL, SB_KEY, { auth: { persistSession: false } });
  } catch {
    return false;
  }
}

/**
 * 直接下 SQL 的 Aurora client（給 jinsun-data 用）。
 *
 * 為什麼另開一個入口而不是沿用上面的 `.from()` 薄殼：那個薄殼刻意只實作 dispatch.js
 * 用得到的 8 個方法，order／join／聚合一律 throw。三端資料 API 需要排序、跨表授權
 * 過濾與 sum()，用 SQL 表達才誠實；但 **encode/decode 兩個踩雷點（enum 要顯式轉型、
 * text[] 是 `{"a","b"}` 不是 JSON）在這裡共用同一份實作**，不重寫第二遍。
 *
 * 參數以物件傳入，SQL 端自己寫轉型：`where status = :status::dispatch_status_t`。
 * 回傳 false 代表缺憑證或缺套件，呼叫端據此走 dryrun。
 */
export async function createAuroraSql() {
  if (!AURORA_CLUSTER || !AURORA_SECRET) return false;
  let RDSDataClient, ExecuteStatementCommand;
  try {
    ({ RDSDataClient, ExecuteStatementCommand } = await import('@aws-sdk/client-rds-data'));
  } catch {
    return false;
  }
  const client = new RDSDataClient({});

  async function query(sql, params = {}) {
    const parameters = Object.entries(params).map(([name, value]) =>
      // 陣列一律當 Postgres 陣列字面值送；SQL 端配 `:p::text[]`。
      encode(name, value, Array.isArray(value) ? 'text[]' : undefined),
    );
    const res = await client.send(new ExecuteStatementCommand({
      resourceArn: AURORA_CLUSTER,
      secretArn: AURORA_SECRET,
      database: AURORA_DB,
      sql,
      parameters,
      includeResultMetadata: true,
    }));
    const meta = res.columnMetadata || [];
    return (res.records || []).map((row) => {
      const obj = {};
      row.forEach((f, i) => { obj[meta[i]?.name ?? i] = decode(f, meta[i]); });
      return obj;
    });
  }

  /** 取第一列，沒有就 null。 */
  const queryOne = async (sql, params) => (await query(sql, params))[0] ?? null;

  return { query, queryOne };
}

// ──────────────────────────── Aurora Data API ────────────────────────────

/** Data API 的欄位值 → JS 值。需要 columnMetadata 才能還原 jsonb 與陣列。 */
function decode(field, meta) {
  if (field.isNull) return null;
  const type = meta?.typeName || '';
  if (field.arrayValue) {
    const a = field.arrayValue;
    return a.stringValues ?? a.longValues ?? a.doubleValues ?? a.booleanValues ?? [];
  }
  if (field.stringValue !== undefined) {
    // jsonb/json 在 Data API 是字串，Supabase client 會回已解析物件——這裡對齊後者
    if (type === 'jsonb' || type === 'json') {
      try { return JSON.parse(field.stringValue); } catch { return field.stringValue; }
    }
    return field.stringValue;
  }
  if (field.longValue !== undefined) return field.longValue;
  if (field.doubleValue !== undefined) return field.doubleValue;
  if (field.booleanValue !== undefined) return field.booleanValue;
  return null;
}

/** JS 陣列 → Postgres 陣列字面值 `{"a","b"}`（不是 JSON！`["a","b"]` 轉 text[] 會失敗）。 */
function toPgArray(arr) {
  const esc = (v) => `"${String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  return `{${arr.map((v) => (v === null ? 'NULL' : esc(v))).join(',')}}`;
}

/** JS 值 → Data API 參數。null 要明確標記，否則 Data API 會當成缺參數。 */
function encode(name, value, pgType) {
  if (value === null || value === undefined) return { name, value: { isNull: true } };
  if (typeof value === 'number') {
    return Number.isInteger(value)
      ? { name, value: { longValue: value } }
      : { name, value: { doubleValue: value } };
  }
  if (typeof value === 'boolean') return { name, value: { booleanValue: value } };
  if (Array.isArray(value)) {
    return { name, value: { stringValue: pgType?.endsWith('[]') ? toPgArray(value) : JSON.stringify(value) } };
  }
  if (typeof value === 'object') return { name, value: { stringValue: JSON.stringify(value) } };
  return { name, value: { stringValue: String(value) } };
}

function auroraClient(client, ExecuteStatementCommand) {
  async function run(sql, parameters) {
    const res = await client.send(new ExecuteStatementCommand({
      resourceArn: AURORA_CLUSTER,
      secretArn: AURORA_SECRET,
      database: AURORA_DB,
      sql,
      parameters,
      includeResultMetadata: true,
    }));
    const meta = res.columnMetadata || [];
    return (res.records || []).map((row) => {
      const obj = {};
      row.forEach((f, i) => { obj[meta[i]?.name ?? i] = decode(f, meta[i]); });
      return obj;
    });
  }

  // 欄位型別快取。Data API 的參數一律是 text，Postgres 不會隱式轉成 enum／uuid／
  // timestamptz／jsonb／text[]，所以每個參數都要顯式 ::轉型。型別從 information_schema
  // 查一次就快取（PostgREST 幫我們做掉的事，這裡要自己做）。
  const typeCache = new Map();
  async function columnTypes(table) {
    if (typeCache.has(table)) return typeCache.get(table);
    const rows = await run(
      `select column_name, udt_name from information_schema.columns
       where table_schema = 'public' and table_name = :t`,
      [{ name: 't', value: { stringValue: table } }],
    );
    const map = {};
    for (const r of rows) {
      // udt_name 對陣列是 `_text` 這種形式 → 還原成 `text[]`
      map[r.column_name] = r.udt_name.startsWith('_') ? `${r.udt_name.slice(1)}[]` : r.udt_name;
    }
    typeCache.set(table, map);
    return map;
  }

  class Query {
    constructor(table) {
      this.table = table;
      this.op = null;          // select | insert | update
      this.cols = '*';
      this.payload = null;
      this.filters = [];       // { col, cmp, value }
      this._limit = null;
      this._mode = null;       // single | maybeSingle
      this._params = [];
      this._n = 0;
      this._types = {};
    }

    _param(value, col) {
      const name = `p${this._n++}`;
      const pgType = col ? this._types[col] : undefined;
      this._params.push(encode(name, value, pgType));
      return pgType ? `:${name}::${pgType}` : `:${name}`;
    }

    select(cols = '*') { this.op = this.op ?? 'select'; if (this.op === 'select') this.cols = cols; return this; }
    insert(obj) { this.op = 'insert'; this.payload = obj; return this; }
    update(obj) { this.op = 'update'; this.payload = obj; return this; }
    eq(col, v) { this.filters.push({ col, cmp: '=', v }); return this; }
    neq(col, v) { this.filters.push({ col, cmp: '<>', v }); return this; }
    limit(n) { this._limit = n; return this; }
    single() { this._mode = 'single'; return this; }
    maybeSingle() { this._mode = 'maybeSingle'; return this; }

    // 沒實作的方法一律當場炸開，避免悄悄回錯資料
    order() { throw new Error('db.js(aurora): order() 尚未實作'); }
    gte() { throw new Error('db.js(aurora): gte() 尚未實作'); }
    lte() { throw new Error('db.js(aurora): lte() 尚未實作'); }
    in() { throw new Error('db.js(aurora): in() 尚未實作'); }
    ilike() { throw new Error('db.js(aurora): ilike() 尚未實作'); }
    delete() { throw new Error('db.js(aurora): delete() 尚未實作'); }
    upsert() { throw new Error('db.js(aurora): upsert() 尚未實作'); }

    _where() {
      if (!this.filters.length) return '';
      return ' where ' + this.filters
        .map((f) => `${f.col} ${f.cmp} ${this._param(f.v, f.col)}`).join(' and ');
    }

    _sql() {
      const t = this.table;
      if (this.op === 'insert') {
        const keys = Object.keys(this.payload);
        const vals = keys.map((k) => this._param(this.payload[k], k));
        return `insert into ${t} (${keys.join(',')}) values (${vals.join(',')}) returning *`;
      }
      if (this.op === 'update') {
        // set 子句要先產生（參數順序＝出現順序），再接 where
        const sets = Object.keys(this.payload)
          .map((k) => `${k} = ${this._param(this.payload[k], k)}`).join(', ');
        return `update ${t} set ${sets}${this._where()} returning *`;
      }
      const cols = this.cols === '*' ? '*' : this.cols.split(',').map((c) => c.trim()).join(', ');
      return `select ${cols} from ${t}${this._where()}` + (this._limit ? ` limit ${Number(this._limit)}` : '');
    }

    /** 讓 builder 可以直接 await，回傳 { data, error }——與 Supabase client 一致。 */
    then(resolve, reject) {
      (async () => {
        try {
          this._types = await columnTypes(this.table);
          const rows = await run(this._sql(), this._params);
          if (this._mode === 'single') {
            if (rows.length !== 1) {
              return { data: null, error: { message: `期望 1 列，實際 ${rows.length} 列` } };
            }
            return { data: rows[0], error: null };
          }
          if (this._mode === 'maybeSingle') {
            if (rows.length > 1) return { data: null, error: { message: `期望 0-1 列，實際 ${rows.length} 列` } };
            return { data: rows[0] ?? null, error: null };
          }
          return { data: rows, error: null };
        } catch (e) {
          return { data: null, error: { message: String(e?.message || e) } };
        }
      })().then(resolve, reject);
    }
  }

  return { from: (table) => new Query(table), __backend: 'aurora' };
}
