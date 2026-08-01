// 把 cloud/prototype/.env 裡指定的幾個 key 併進 jinsun-voice Lambda 的環境變數。
// 用 JSON 傳遞（不是 Variables={k=v,...} 的簡寫），才不會被含 = 或 , 的值弄壞。
//
// 用法：LAMBDA_FN=<函式名> node --env-file=<repo>/cloud/prototype/.env set-lambda-env.mjs KEY1 [KEY2...]
// 　　（LAMBDA_FN 省略時預設 jinsun-voice）
// 金鑰只在本機記憶體與 AWS API 之間流動，不會印出來。

import { execFileSync } from 'node:child_process';
import { writeFileSync, unlinkSync } from 'node:fs';

const FN = process.env.LAMBDA_FN || 'jinsun-voice';
const wanted = process.argv.slice(2);
if (!wanted.length) {
  console.error('用法：node --env-file=.env set-lambda-env.mjs KEY1 [KEY2...]');
  process.exit(1);
}

const aws = (args) => execFileSync('aws', args, { encoding: 'utf8' });

const current = JSON.parse(
  aws(['lambda', 'get-function-configuration', '--function-name', FN,
       '--query', 'Environment.Variables', '--output', 'json']),
);

const added = [];
for (const k of wanted) {
  const v = process.env[k];
  if (!v) { console.error(`  ⚠️ .env 裡找不到 ${k}，略過`); continue; }
  current[k] = v;
  added.push(`${k}（${v.length} 字元）`);
}
if (!added.length) { console.error('  沒有任何 key 可套用'); process.exit(1); }

const tmp = `/tmp/jinsun-lambda-env-${process.pid}.json`;
writeFileSync(tmp, JSON.stringify({ Variables: current }), { mode: 0o600 });
try {
  const status = aws(['lambda', 'update-function-configuration', '--function-name', FN,
                      '--environment', `file://${tmp}`,
                      '--query', 'LastUpdateStatus', '--output', 'text']).trim();
  console.log(`  ✅ 已套用：${added.join('、')}`);
  console.log(`  目前變數：${Object.keys(current).sort().join(', ')}`);
  console.log(`  更新狀態：${status}`);
} finally {
  unlinkSync(tmp);   // 立刻刪掉含 secret 的暫存檔
}
