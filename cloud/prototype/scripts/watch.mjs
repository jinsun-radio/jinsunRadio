// 端到端驗證小工具：每 2 秒讀 Supabase 最新事件與派遣單，確認 server 真的寫進去了。
// 零依賴（用內建 fetch + Supabase REST）。讀取是公開的（demo_read policy），用 anon key 即可。
//
//   node scripts/watch.mjs
//
// 看到新的 radio_events / dispatch_tasks 冒出來 = server → Supabase 這段通了；
// 三個前台（家屬/志工/社工）訂閱同一份資料，會同時亮。

const URL = process.env.SUPABASE_URL || 'https://ykfxmoubynnbhnburawl.supabase.co';
const KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_1252UHs0uFhEvQ_LSjXQdg_w-EIyPIG';

async function get(path) {
  const res = await fetch(`${URL}/rest/v1/${path}`, {
    headers: { apikey: KEY, authorization: `Bearer ${KEY}` },
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json();
}

const S = { normal: '🟢', attention: '🟡', emergency: '🔴' };

async function tick() {
  const [elders, events, tasks] = await Promise.all([
    get('elders?select=id,name,severity&order=id'),
    get('radio_events?select=type,status,severity,transcript,occurred_at&order=occurred_at.desc&limit=5'),
    get('dispatch_tasks?select=kind,status,assignee_name,worker_name,items,created_at&order=created_at.desc&limit=5'),
  ]);

  console.clear();
  console.log('=== 長輩狀態（社工後台 dashboard）===');
  for (const e of elders) console.log(`  ${S[e.severity] || '⚪'} ${e.name}  (${e.severity})`);

  console.log('\n=== 最新事件 radio_events（硬體上報）===');
  for (const e of events) {
    console.log(`  ${S[e.severity] || '⚪'} ${e.type}/${e.status}  ${e.transcript || ''}  @${e.occurred_at?.slice(11, 19)}`);
  }

  console.log('\n=== 最新派遣單 dispatch_tasks（志工接單／家屬進度）===');
  for (const t of tasks) {
    const who = t.assignee_name ? `接單:${t.assignee_name}` : '待接單';
    const items = t.items?.length ? ` [${t.items.join('、')}]` : '';
    console.log(`  • ${t.kind}/${t.status}  ${who}  督導:${t.worker_name || '-'}${items}  @${t.created_at?.slice(11, 19)}`);
  }
  console.log('\n(每 2 秒更新，Ctrl+C 結束)');
}

console.log('連線中…', URL);
setInterval(() => tick().catch((e) => console.error('讀取失敗：', e.message)), 2000);
tick().catch((e) => console.error('讀取失敗：', e.message));
