// 由 cloud/supabase/schema.sql 產生 Aurora 版本 schema。
//
// 兩套環境共用同一份 schema 定義（單一來源），差異只在 Supabase 專屬的四塊：
//   1. auth.users 外鍵      → Aurora 沒有 auth schema，改成純 uuid 欄位（身分由 Cognito 管）
//   2. fn_handle_new_user   → 掛在 auth.users 上的觸發器，Aurora 無此表；改由 Cognito
//                             Post-Confirmation Lambda 寫 profiles
//   3. supabase_realtime    → publication / replica identity，AppSync 不需要
//   4. RLS policies         → 全部用 auth.uid()，Aurora 無此函式；授權改在 AppSync
//                             resolver / Lambda 層做（見 aws-architecture.md §6）
//
// 用法：node cloud/aws/db/transform-schema.mjs > cloud/aws/db/schema.sql

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '../../supabase/schema.sql'), 'utf8');

const lines = src.split('\n');
const out = [];
let skipping = null;

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];

  // ── 區塊層級的切除 ──
  if (line.includes('========== 即時推播 ==========')) { skipping = 'realtime'; continue; }
  if (line.includes('========== RLS ==========')) { skipping = 'rls'; continue; }
  if (line.includes('========== 種子資料')) { skipping = null; }   // 種子資料要留
  if (skipping) continue;

  // ── auth.users 外鍵 → 純 uuid ──
  if (/references auth\.users/.test(line)) {
    out.push(line.replace(/\s*references auth\.users(\(id\))?( on delete cascade)?/, '')
                 .replace(/,\s*$/, ',')
                 + '   -- 身分改由 Cognito 管理（原為 Supabase auth.users 外鍵）');
    continue;
  }

  // ── fn_handle_new_user 及其掛在 auth.users 的觸發器 ──
  // 這一整塊（函式定義 → drop trigger → create trigger → for each row …）都要移除。
  // 用「吃到觸發器最後一行為止」來界定，比逐段猜結尾可靠——早期版本用後者，
  // 留下了孤兒片段 `for each row execute function fn_handle_new_user();`。
  if (/create or replace function fn_handle_new_user/.test(line)) {
    while (i < lines.length && !/execute function fn_handle_new_user\(\)/.test(lines[i])) i++;
    out.push('-- fn_handle_new_user / trg_new_user 已移除：Aurora 無 auth.users。');
    out.push('-- 使用者建立時寫入 profiles 改由 Cognito Post-Confirmation Lambda 負責。');
    continue;
  }

  out.push(line);
}

const header = `-- ⚠️ 自動產生，請勿直接編輯。
-- 來源：cloud/supabase/schema.sql
-- 產生：node cloud/aws/db/transform-schema.mjs > cloud/aws/db/schema.sql
--
-- 與來源的差異（見 transform-schema.mjs 檔頭說明）：
--   移除 auth.users 外鍵、fn_handle_new_user 觸發器、supabase_realtime publication、RLS policies。
--   資料表、型別、業務觸發器（fn_on_radio_event / fn_after_radio_event）與種子資料完全保留。
`;

process.stdout.write(header + out.join('\n'));
