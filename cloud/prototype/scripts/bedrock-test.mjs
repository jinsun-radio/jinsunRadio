// Bedrock 連線自我診斷：用 server 同一個 Mantle client 打一次真的 Bedrock，
// 明確回報是「憑證問題」還是「模型未開通」。不需要 aws CLI。
//
//   node --env-file=.env scripts/bedrock-test.mjs
//
// 需先：① 在 Bedrock 主控台開通模型存取  ② .env 有 AWS 憑證與 region

const REGION = process.env.AWS_REGION || 'us-west-2';
const GATEWAY = process.env.BEDROCK_GATEWAY || 'standard';
const MODELS = [
  ['快模型（意圖分類）', process.env.BEDROCK_FAST_MODEL_ID || 'us.anthropic.claude-haiku-4-5-20251001-v1:0'],
  ['強模型（聊天/需求）', process.env.BEDROCK_MODEL_ID || 'us.anthropic.claude-sonnet-4-5-20250929-v1:0'],
];

const hasKeyEnv = !!(process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY);
console.log(`region = ${REGION}｜gateway = ${GATEWAY}${process.env.AWS_SESSION_TOKEN ? '｜有 session token（一時憑證）' : ''}`);
console.log(`憑證來源 = ${hasKeyEnv ? '環境變數(.env)' : '~/.aws/credentials 或 IAM 角色（若都沒有會失敗）'}`);
console.log('');

const sdk = await import('@anthropic-ai/bedrock-sdk');
const Client = GATEWAY === 'mantle' ? sdk.AnthropicBedrockMantle : sdk.AnthropicBedrock;
const client = new Client({ awsRegion: REGION });

let allOk = true;
for (const [label, model] of MODELS) {
  process.stdout.write(`測試 ${label}  ${model} … `);
  try {
    const res = await client.messages.create({
      model,
      max_tokens: 16,
      messages: [{ role: 'user', content: '只回兩個字：你好' }],
    });
    const text = res?.content?.find((b) => b.type === 'text')?.text ?? '(空)';
    console.log(`✅ 通　回覆：「${text.trim()}」`);
  } catch (e) {
    allOk = false;
    console.log('❌ 失敗');
    diagnose(e, model);
  }
}

console.log('');
console.log(allOk ? '🎉 兩個模型都通，server 設 LLM_PROVIDER=bedrock 即可上線。' : '⚠️  有模型未通，依上面提示處理後再跑一次。');

function diagnose(e, model) {
  const name = e?.name || '';
  const msg = String(e?.message || e);
  const s = (name + ' ' + msg).toLowerCase();
  const hint = (t) => console.log(`   → ${t}`);
  console.log(`   ${name}: ${msg.split('\n')[0]}`);
  if (s.includes('accessdenied') || s.includes("don't have access") || s.includes('not authorized') || s.includes('access to the model')) {
    hint(`此模型還沒開通。到 Bedrock 主控台 → Model access 勾選並儲存：${model}`);
    hint('頁面：https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/modelaccess');
  } else if (s.includes('inference profile') || s.includes('on-demand throughput') || s.includes('invocation with the on-demand')) {
    hint(`此模型需用跨區 inference profile。把 .env 的 ID 改成 us. 前綴：us.${model}`);
  } else if (s.includes('unrecognizedclient') || s.includes('invalid') && s.includes('token') || s.includes('signature') || s.includes('credential') || s.includes('security token')) {
    hint('憑證無效或未設。確認 .env 的 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY 正確。');
  } else if (s.includes('could not load credentials') || s.includes('unable to locate credentials')) {
    hint('找不到憑證。在 .env 填 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY，並用 node --env-file=.env 執行。');
  } else if (s.includes('region')) {
    hint('region 問題。確認 AWS_REGION=us-east-1（或該模型有開通的區）。');
  } else {
    hint('其他錯誤，把上面整行貼給我看。');
  }
}
