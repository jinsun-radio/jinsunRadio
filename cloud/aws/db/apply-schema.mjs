// 把 cloud/aws/db/schema.sql 套用到 Aurora（走 Data API，不需進 VPC、不碰密碼）。
//
// 為什麼要自己切語句：Data API 的 ExecuteStatement 一次只吃一句，而 schema 裡有
// plpgsql 函式（$$ ... $$ 內含分號），單純用 ; 切會把函式切壞。
//
// 用法：
//   CLUSTER_ARN=... SECRET_ARN=... node cloud/aws/db/apply-schema.mjs [--dry-run]
// 依賴：aws CLI（不需 npm 套件，方便任何人直接跑）

import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const CLUSTER = process.env.CLUSTER_ARN;
const SECRET = process.env.SECRET_ARN;
const DB = process.env.DB_NAME || 'jinsun';
const DRY = process.argv.includes('--dry-run');

if (!CLUSTER || !SECRET) {
  console.error('需要環境變數 CLUSTER_ARN 與 SECRET_ARN');
  process.exit(1);
}

const here = dirname(fileURLToPath(import.meta.url));
const sql = readFileSync(join(here, 'schema.sql'), 'utf8');

/**
 * 依分號切語句。必須同時處理三種「分號不算數」的情境，少一種就會切出無效 SQL：
 *   1. $$ … $$ / $tag$ … $tag$  plpgsql 函式體內的分號
 *   2. '…'                      字串常值內的分號（種子資料的地址等）
 *   3. -- …                     行註解內的分號 —— schema.sql 第 18 行就有一個，
 *                               早期版本沒處理，切出了 `（勿改動這裡） do $$…$$` 這種壞語句
 * 註解一律丟棄（Data API 不需要，也避免再被當成語句起頭）。
 */
function split(text) {
  const out = [];
  let buf = '';
  let dollarTag = null;   // 目前所在的 $tag$（null = 不在函式體內）
  let inString = false;   // 是否在 '…' 內
  let inComment = false;  // 是否在 -- 行註解內

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    const rest = text.slice(i);

    if (inComment) {                       // 行註解：吃到換行為止，內容不保留
      if (ch === '\n') { inComment = false; buf += '\n'; }
      continue;
    }
    if (dollarTag) {                       // 函式體：原樣保留到結束標記
      if (rest.startsWith(dollarTag)) { buf += dollarTag; i += dollarTag.length - 1; dollarTag = null; }
      else buf += ch;
      continue;
    }
    if (inString) {                        // 字串常值：'' 為跳脫，單一 ' 結束
      buf += ch;
      if (ch === "'") { if (text[i + 1] === "'") { buf += "'"; i++; } else inString = false; }
      continue;
    }

    if (rest.startsWith('--')) { inComment = true; continue; }
    const dq = rest.match(/^\$([A-Za-z_]*)\$/);
    if (dq) { dollarTag = dq[0]; buf += dq[0]; i += dq[0].length - 1; continue; }
    if (ch === "'") { inString = true; buf += ch; continue; }

    if (ch === ';') {
      const stmt = buf.trim();
      if (stmt) out.push(stmt);
      buf = '';
    } else {
      buf += ch;
    }
  }
  const tail = buf.trim();
  if (tail) out.push(tail);
  return out;
}

const statements = split(sql);
console.log(`  共 ${statements.length} 句${DRY ? '（dry-run，不執行）' : ''}\n`);

let ok = 0;
const failures = [];
for (const [i, stmt] of statements.entries()) {
  const label = stmt.replace(/\s+/g, ' ').slice(0, 72);
  if (DRY) { console.log(`  [${i + 1}] ${label}`); continue; }
  try {
    execFileSync('aws', ['rds-data', 'execute-statement',
      '--resource-arn', CLUSTER, '--secret-arn', SECRET, '--database', DB,
      '--sql', stmt], { stdio: 'pipe' });
    ok++;
  } catch (e) {
    const msg = String(e.stderr || e.message).split('\n').find((l) => l.includes('ERROR')) || String(e.message);
    failures.push({ i: i + 1, label, msg: msg.slice(0, 200) });
  }
}

if (!DRY) {
  console.log(`  ✅ 成功 ${ok} 句`);
  if (failures.length) {
    console.log(`  ❌ 失敗 ${failures.length} 句：`);
    failures.forEach((f) => console.log(`     [${f.i}] ${f.label}\n         ${f.msg}`));
    process.exit(1);
  }
}
