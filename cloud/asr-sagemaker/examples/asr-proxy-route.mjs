// 給語音 Agent server（cloud/prototype）加的 OpenAI 相容 ASR 路由。
//
// 為什麼需要這一層：SageMaker endpoint 的傳輸層強制 AWS SigV4 簽章，HUB8735 做不到
// （HMAC-SHA256 簽章鏈太重，而且不該把 IAM 憑證燒進韌體）。Render server 已經在 443、
// 已被韌體信任、也已能持有雲端金鑰，由它轉一手最省事。
//
// 因為 endpoint 本身已經吃 OpenAI 形狀的 multipart（見 src/inference.py），
// 這裡只做兩件事：驗裝置金鑰、原封轉發 body。不解析、不改寫。
//
//   npm i @aws-sdk/client-sagemaker-runtime

import {
  SageMakerRuntimeClient,
  InvokeEndpointCommand,
} from '@aws-sdk/client-sagemaker-runtime';

// client 重複使用才有連線池；每次 new 會多付一次 TLS 握手，實測那是延遲大頭。
const client = new SageMakerRuntimeClient({
  region: process.env.AWS_REGION ?? 'ap-northeast-1',
});
const ENDPOINT = process.env.ASR_ENDPOINT_NAME ?? 'breeze-asr-26';
const DEVICE_KEY = process.env.ASR_DEVICE_KEY; // 裝置端共用金鑰，必設

const MAX_BYTES = 5 << 20; // SageMaker 即時 endpoint 上限 6MB，留點餘裕

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (c) => {
      total += c.length;
      if (total > MAX_BYTES) {
        reject(new Error('payload too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/**
 * 掛在 server.js 的路由分派裡：
 *   if (req.method === 'POST' && req.url === '/v1/audio/transcriptions')
 *     return handleTranscription(req, res);
 */
export async function handleTranscription(req, res) {
  const json = (code, body) => {
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(body));
  };

  // 沿用韌體既有的 x-bf-vk 標頭，也接 OpenAI 慣用的 Authorization: Bearer。
  const bearer = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
  const presented = req.headers['x-bf-vk'] ?? bearer;
  if (!DEVICE_KEY || presented !== DEVICE_KEY) {
    return json(401, { error: { message: 'unauthorized', type: 'invalid_request_error' } });
  }

  let body;
  try {
    body = await readBody(req);
  } catch (err) {
    return json(413, { error: { message: err.message, type: 'invalid_request_error' } });
  }

  try {
    const out = await client.send(
      new InvokeEndpointCommand({
        EndpointName: ENDPOINT,
        // ⚠️ 這裡刻意「不」把原本的 multipart/form-data 標頭帶過去。
        //    SageMaker 容器裡的 MMS 看到 multipart/form-data 會自己先把 parts 拆掉，
        //    HF toolkit 接著只取名為 body 的那一份 → handler 收到 null 而炸掉。
        //    標成 octet-stream，body 原封不動送過去，由 inference.py 從第一行
        //    嗅出 boundary 自行解析。改這行之前先看 src/inference.py 的 _sniff_boundary。
        ContentType: 'application/octet-stream',
        Body: body,
      }),
    );
    const text = Buffer.from(out.Body).toString('utf-8');
    res.writeHead(200, { 'Content-Type': out.ContentType ?? 'application/json; charset=utf-8' });
    res.end(text);
  } catch (err) {
    console.error('[asr] invoke failed:', err);
    // 韌體等 20 秒後就放棄；明確回錯比讓它空等好。
    return json(502, { error: { message: 'asr_upstream_failed', type: 'api_error' } });
  }
}
