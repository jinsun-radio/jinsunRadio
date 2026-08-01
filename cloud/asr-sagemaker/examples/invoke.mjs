// 從 Node（例如 cloud/prototype 的語音 Agent server）呼叫 ASR endpoint。
//
// SageMaker endpoint 不是公開 REST API：真正的 URL 是
//   https://runtime.sagemaker.<region>.amazonaws.com/endpoints/<name>/invocations
// 但每個請求都要 AWS SigV4 簽章，所以要用 SDK 打，不能直接 curl。
//
//   npm i @aws-sdk/client-sagemaker-runtime
//   node examples/invoke.mjs ../samples/sos.wav

import { readFileSync } from 'node:fs';
import {
  SageMakerRuntimeClient,
  InvokeEndpointCommand,
} from '@aws-sdk/client-sagemaker-runtime';

const REGION = process.env.AWS_REGION ?? 'ap-northeast-1';
const ENDPOINT = process.env.ASR_ENDPOINT_NAME ?? 'breeze-asr-26';

// 照護領域詞彙，用來壓同音字錯誤（實測「血壓要」→「血壓藥」）。
const INITIAL_PROMPT =
  '以下是長輩的居家照護語音：血壓藥、慢性病、回診、量血壓、送餐、跌倒、復健、輪椅。';

// client 重複使用才有連線池；每次 new 會多付一次 TLS 握手，實測那是延遲大頭。
const client = new SageMakerRuntimeClient({ region: REGION });

export async function transcribe(wavBuffer, { initialPrompt = INITIAL_PROMPT } = {}) {
  const res = await client.send(
    new InvokeEndpointCommand({
      EndpointName: ENDPOINT,
      ContentType: 'application/json',
      Body: JSON.stringify({
        audio_base64: wavBuffer.toString('base64'),
        initial_prompt: initialPrompt,
        beam_size: 5,
      }),
    }),
  );
  // → { text, segments, language, language_probability, duration, processing_ms }
  return JSON.parse(Buffer.from(res.Body).toString('utf-8'));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const path = process.argv[2];
  if (!path) {
    console.error('用法：node examples/invoke.mjs <檔案.wav>');
    process.exit(1);
  }
  const t0 = performance.now();
  const r = await transcribe(readFileSync(path));
  console.log(r.text);
  console.log(
    `wall ${((performance.now() - t0) / 1000).toFixed(2)}s | ` +
      `gpu ${(r.processing_ms / 1000).toFixed(2)}s | audio ${r.duration}s`,
  );
}
