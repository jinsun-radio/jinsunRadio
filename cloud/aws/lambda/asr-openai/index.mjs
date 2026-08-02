// jinsun-asr-openai — 把 SageMaker 的 breeze-asr-26 endpoint 開成可以 curl 的
// OpenAI `/v1/audio/transcriptions`。
//
// 為什麼需要這一層：SageMaker 的傳輸層強制 AWS SigV4 簽章，所以 endpoint 本身
// **不能直接 curl**，也不能讓 HUB8735 直連（簽章鏈太重，而且不該把 IAM 憑證燒進韌體）。
// 這支 Lambda 就是那顆「重新簽章、原封轉發」的門面。
//
// endpoint 內部的 handler（cloud/asr-sagemaker/src/inference.py）本來就吃 OpenAI 形狀的
// multipart、回 OpenAI 形狀的 {"text": …}，所以這裡**不解析也不改寫 body**，只做三件事：
//   ① 驗金鑰  ② 把 API Gateway 的 base64 body 還原成 bytes  ③ 換上 octet-stream 轉發
//
// ⚠️ ③ 的 ContentType 是刻意「不」帶原本的 multipart/form-data：
//    SageMaker 容器裡的 MMS 看到 multipart/form-data 會自己先把 parts 拆掉，
//    HF toolkit 接著只取名為 body 的那一份 → handler 收到 None 而炸掉。
//    標成 octet-stream 讓 body 原封送達，由 inference.py 的 _sniff_boundary 自行還原。
//    改這行之前先讀 cloud/asr-sagemaker/src/inference.py。
import {
  SageMakerRuntimeClient,
  InvokeEndpointCommand,
} from '@aws-sdk/client-sagemaker-runtime';

// client 放在 handler 外重複使用才有連線池；每次 new 會多付一次 TLS 握手，
// 在冷啟動之外那是延遲大頭。
const client = new SageMakerRuntimeClient({});

const ENDPOINT = process.env.ASR_ENDPOINT_NAME || 'breeze-asr-26';
const API_KEY = process.env.ASR_API_KEY || '';        // 空字串 = 不驗（見 deploy 腳本的警告）
const MODEL_ID = process.env.ASR_MODEL_ID || 'breeze-asr-26';

// 上限取三個限制裡最緊的那個，再往下留餘裕：
//   API Gateway HTTP API 請求 10MB / Lambda 同步呼叫 payload 6MB / SageMaker 即時 endpoint 6MB
// binary body 會被 API Gateway 做 base64（膨脹 4/3），所以 4.5MB 的原始音訊 → 6MB base64，
// 正好頂到 Lambda 上限。約等於 2.3 分鐘的 16kHz mono WAV；韌體最長錄 30 秒，綽綽有餘。
const MAX_BYTES = 4.5 * 1024 * 1024;

const json = (statusCode, obj, extra = {}) => ({
  statusCode,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'access-control-allow-origin': '*',
    ...extra,
  },
  body: JSON.stringify(obj),
});

// OpenAI 的錯誤形狀。照著回，client SDK 才能正確解讀而不是丟 parse error。
const fail = (statusCode, message, type = 'invalid_request_error', code = null) =>
  json(statusCode, { error: { message, type, param: null, code } });

export const handler = async (event) => {
  const method = event?.requestContext?.http?.method || 'POST';
  const path = event?.rawPath || '/';

  // CORS preflight：瀏覽器直接打這支時需要（例如拿 elder_app 的網頁版試錄音）。
  if (method === 'OPTIONS') {
    return {
      statusCode: 204,
      headers: {
        'access-control-allow-origin': '*',
        'access-control-allow-methods': 'POST, GET, OPTIONS',
        'access-control-allow-headers': 'authorization, content-type, x-bf-vk',
        'access-control-max-age': '86400',
      },
      body: '',
    };
  }

  const headers = event?.headers || {};
  // 標頭名在 API Gateway v2 已經小寫化，但本地測試可能不是，保險起見兩邊都找。
  const pick = (name) => headers[name] ?? headers[name.toLowerCase()] ?? '';
  const bearer = String(pick('authorization')).replace(/^Bearer\s+/i, '');
  // 沿用韌體既有的 x-bf-vk 標頭，也接 OpenAI 慣用的 Authorization: Bearer。
  const presented = String(pick('x-bf-vk') || bearer);

  if (API_KEY && presented !== API_KEY) {
    return fail(401, 'Incorrect API key provided.', 'invalid_request_error', 'invalid_api_key');
  }

  // OpenAI 相容工具（SDK、Open WebUI 之類）啟動時常會先打這支列模型。
  if (method === 'GET' && path.endsWith('/models')) {
    return json(200, {
      object: 'list',
      data: [{ id: MODEL_ID, object: 'model', created: 0, owned_by: 'jinsun' }],
    });
  }

  if (method !== 'POST') {
    return fail(405, `Unsupported method: ${method}`);
  }

  if (!event.body) {
    return fail(400, "Missing required parameter: 'file'.");
  }

  // API Gateway 對 binary body 會做 base64（multipart 一律算 binary）。
  const body = event.isBase64Encoded
    ? Buffer.from(event.body, 'base64')
    : Buffer.from(event.body, 'utf8');

  if (body.length > MAX_BYTES) {
    return fail(
      413,
      `Audio is too large (${body.length} bytes). Maximum is ${MAX_BYTES} bytes ` +
        '(about 2 minutes of 16kHz mono WAV).',
    );
  }

  try {
    const out = await client.send(
      new InvokeEndpointCommand({
        EndpointName: ENDPOINT,
        ContentType: 'application/octet-stream',   // ⚠️ 見檔頭 ③ 的說明，不要改成 multipart
        Body: body,
      }),
    );

    const text = Buffer.from(out.Body).toString('utf-8');
    return {
      statusCode: 200,
      headers: {
        'content-type': out.ContentType || 'application/json; charset=utf-8',
        'access-control-allow-origin': '*',
      },
      body: text,
    };
  } catch (err) {
    console.error('[asr-openai] invoke failed:', err);

    // endpoint 被 teardown.sh 收掉是最常見的狀況（GPU 機型持續計費，用完就關）。
    // 明確講是哪一種失敗，比一律 502 讓人猜要好——韌體等 20 秒就放棄了。
    const name = err?.name || '';
    if (name === 'ValidationError' || /could not be found/i.test(err?.message || '')) {
      return fail(
        503,
        `SageMaker endpoint '${ENDPOINT}' not found or not InService. ` +
          'It may have been torn down (GPU instances bill continuously).',
        'api_error',
        'endpoint_unavailable',
      );
    }
    if (name === 'ModelError') {
      return fail(422, `Model returned an error: ${err.message}`, 'api_error', 'model_error');
    }
    return fail(502, 'Upstream ASR request failed.', 'api_error');
  }
};
