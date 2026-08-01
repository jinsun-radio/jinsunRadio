// jinsun-tts — 國語 TTS（Amazon Polly）
//
// 為什麼需要這支：裝置端原本只接 ATEN TTS（kws.oaselab.org），而**那是台語模型**，
// 且端點不吃 voice/lang 參數 —— 也就是說 `lang=mandarin` 一直被念成台語。
// 這支補上國語那半邊，讓下行 speak 的 `lang` 旗標第一次真的有路由意義：
//   lang=taigi    → ATEN（裝置直接打，不經過這裡）
//   lang=mandarin → 這支 Lambda（Polly Zhiyu）
//
// 回應直接是 WAV bytes，不是 JSON URL。理由：韌體的 amp.playWavStream(client) 是
// 邊收邊播，POST 完直接串流少一次 TLS 握手（板子上一次握手就要幾百毫秒），
// 也省掉 S3 bucket 與它的生命週期管理。
//
// ⚠️ Polly 的 OutputFormat=pcm 是**沒有檔頭的 raw 16-bit LE**，
//    playWavStream 需要 RIFF 檔頭 → 下面 wavHeader() 自己補那 44 bytes。
// 兩種呼叫者、兩種回應形式（同一條 POST /tts，靠 Accept 分辨）：
//   Accept: audio/wav（韌體）→ WAV bytes，邊收邊播
//   其他（elder_app 網頁版）  → JSON {status,url}，url 是 data:audio/mpeg;base64,…
// 網頁版那條沿用它本來打 Render /tts 的介面（apps/elder_app/lib/main.dart 的
// _cloudTtsUrl 只看 j['url']），所以前端一行都不用改。給瀏覽器的是 **mp3** 不是 wav：
// 同一句話 mp3 大約只有 wav 的 1/10，塞進 data: URL 才不會太肥。
import { PollyClient, SynthesizeSpeechCommand } from '@aws-sdk/client-polly';

const polly = new PollyClient({});

const VOICE = process.env.POLLY_VOICE || 'Zhiyu';   // Polly 目前唯一的華語音色
const SAMPLE_RATE = 16000;                           // pcm 只支援 8000/16000；板子提示音也是 16k
const MAX_CHARS = 800;                               // 超過就截斷，見下方 Lambda 回應上限

// 峰值正規化目標。Polly 出來的音量偏保守（實測 23 字那句峰值只到 −10.0 dBFS、
// RMS −22.7），上板實聽就是「有點小聲」；而韌體那邊 ampVolume 預設 0.8、上限 1.0，
// 只剩 1.9 dB 可調，補不了這個缺口——而且調大會連 ATEN（台語）一起變大聲。
// 所以在這裡把國語這條路拉到接近滿刻度，台語完全不受影響。
const PEAK_DBFS = Number(process.env.TTS_PEAK_DBFS ?? -1);
const MAX_GAIN_DB = Number(process.env.TTS_MAX_GAIN_DB ?? 12);   // 近乎無聲的短句不要把底噪也放大

// 容器級快取。播報文案高度重複（「志工林志明大約 8 分鐘就到」這類），
// 熱容器內同一句就不用再打 Polly —— 省的是延遲，不是錢（Polly 本來就很便宜）。
const cache = new Map();
const CACHE_MAX = 32;

function wavHeader(dataLen, rate = SAMPLE_RATE) {
  const b = Buffer.alloc(44);
  b.write('RIFF', 0);
  b.writeUInt32LE(36 + dataLen, 4);
  b.write('WAVE', 8);
  b.write('fmt ', 12);
  b.writeUInt32LE(16, 16);          // fmt chunk 長度
  b.writeUInt16LE(1, 20);           // PCM
  b.writeUInt16LE(1, 22);           // mono
  b.writeUInt32LE(rate, 24);        // sample rate
  b.writeUInt32LE(rate * 2, 28);    // byte rate = rate * channels * bytesPerSample
  b.writeUInt16LE(2, 32);           // block align
  b.writeUInt16LE(16, 34);          // bits per sample
  b.write('data', 36);
  b.writeUInt32LE(dataLen, 40);
  return b;
}

// 把 raw 16-bit LE PCM 的峰值拉到 PEAK_DBFS。就地改寫 buffer，回傳實際套用的增益（dB）。
//
// 為什麼是峰值正規化而不是壓縮／限幅：語音的波峰因數本來就大（實測這句 12.7 dB），
// 單純拉高峰值不會改變語氣起伏，長輩聽到的還是同一種說話方式，只是整體變大聲。
// 要再更響就得動態壓縮，那會讓播報聽起來像廣告，不適合陪伴情境。
function normalizePcm(pcm) {
  let peak = 0;
  for (let i = 0; i + 1 < pcm.length; i += 2) {
    const a = Math.abs(pcm.readInt16LE(i));
    if (a > peak) peak = a;
  }
  if (peak === 0) return 0;   // 全靜音，不用管

  const target = 32767 * Math.pow(10, PEAK_DBFS / 20);
  const maxGain = Math.pow(10, MAX_GAIN_DB / 20);
  const gain = Math.min(target / peak, maxGain);
  if (gain <= 1) return 0;    // 已經夠大聲就不動它

  for (let i = 0; i + 1 < pcm.length; i += 2) {
    // 有 MAX_GAIN_DB 擋著仍然要夾一次：gain 是照峰值算的，浮點誤差可能讓
    // 最大的那幾個取樣點剛好超過 32767 而繞回負值（爆音）。
    const v = Math.round(pcm.readInt16LE(i) * gain);
    pcm.writeInt16LE(v > 32767 ? 32767 : v < -32768 ? -32768 : v, i);
  }
  return 20 * Math.log10(gain);
}

async function synth(text, engine, format) {
  const r = await polly.send(new SynthesizeSpeechCommand({
    Text: text,
    VoiceId: VOICE,
    Engine: engine,
    OutputFormat: format,
    SampleRate: format === 'pcm' ? String(SAMPLE_RATE) : '24000',
    // 刻意不帶 LanguageCode：它只有雙語音色（如 Aditi）才需要，
    // 而 Zhiyu 的語言碼在不同文件寫成 cmn-CN 或 zh-CN，填錯會直接被 Polly 打回。
    // 不填 → 用音色自己的預設語言，沒有猜錯的餘地。
  }));
  return Buffer.from(await r.AudioStream.transformToByteArray());
}

// neural 在部分 region／音色不可用時，standard 仍念得出來。
// 長輩一定要聽到聲音，音質是其次。
async function synthWithFallback(text, format) {
  try {
    return await synth(text, 'neural', format);
  } catch (e) {
    console.warn(`[tts] neural 失敗（${e.name}: ${e.message}）→ 退回 standard`);
    return await synth(text, 'standard', format);
  }
}

export const handler = async (event) => {
  // HTTP API 的 $default 路由會吃掉 OPTIONS（見 deploy-data.sh 的註解），
  // 但 /tts 是自己的路由，preflight 要自己回。長輩端網頁版也會打這支。
  const method = event?.requestContext?.http?.method || 'POST';
  if (method === 'OPTIONS') {
    return { statusCode: 204, headers: cors() };
  }

  let body = {};
  try {
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body || '', 'base64').toString('utf8')
      : (event.body || '{}');
    body = JSON.parse(raw);
  } catch {
    return json(400, { status: 'Error', error: 'bad JSON body' });
  }

  let text = String(body.text ?? '').trim();
  const lang = String(body.lang ?? 'mandarin');
  if (!text) return json(400, { status: 'Error', error: 'text is required' });

  const accept = String(
    event.headers?.accept ?? event.headers?.Accept ?? '',
  ).toLowerCase();
  const wantsWav = accept.includes('audio/wav');   // 韌體會帶；瀏覽器不會

  // 台語不走這裡 —— Polly 沒有閩南語音色。
  //
  // 韌體不會踩到（speak() 的 taigi 直接打 ATEN），真正的呼叫者是 elder_app 網頁版。
  // 回 **404** 而不是 400，是為了對上它既有的處理：main.dart 的 _cloudTtsUrl 只在
  // 404 時把 _cloudTtsAvailable 關掉，之後整個 session 直接走瀏覽器語音；
  // 回 400 的話它每念一句都要先白等一趟往返。
  // （AWS 這側沒有台語 TTS 是已知缺口——Render 那台的 /tts 有代打 ATEN，這裡沒有。）
  if (lang === 'taigi') {
    return json(404, { status: 'Error', error: 'taigi TTS is not available on this environment (Polly has no Hokkien voice)' });
  }

  if (text.length > MAX_CHARS) {
    console.warn(`[tts] text ${text.length} chars → 截斷到 ${MAX_CHARS}`);
    text = text.slice(0, MAX_CHARS);
  }

  const key = `${VOICE}:${wantsWav ? 'wav' : 'mp3'}:${text}`;
  const hit = cache.get(key);
  if (hit) {
    console.log(`[tts] cache hit (${hit.length} bytes)`);
    return wantsWav ? wav(hit) : dataUrl(hit);
  }

  let out;
  try {
    if (wantsWav) {
      // pcm 是沒有檔頭的 raw 16-bit LE → 先拉音量，再補 RIFF（playWavStream 才認得）。
      const pcm = await synthWithFallback(text, 'pcm');
      const applied = normalizePcm(pcm);
      if (applied > 0) console.log(`[tts] 音量 +${applied.toFixed(1)} dB → 峰值 ${PEAK_DBFS} dBFS`);
      out = Buffer.concat([wavHeader(pcm.length), pcm]);
    } else {
      // mp3 這條不正規化：拿回來已經是編碼後的資料，要調音量得解碼再重編。
      // 而且呼叫端是瀏覽器，本來就有系統音量可調——只有收音機沒有。
      out = await synthWithFallback(text, 'mp3');
    }
  } catch (e) {
    console.error(`[tts] Polly 失敗：${e.name}: ${e.message}`);
    return json(502, { status: 'Error', error: `polly: ${e.message}` });
  }

  // Lambda proxy 回應上限 6 MB；wav 是 16k/16-bit/mono ≈ 32 KB/秒 → 約 190 秒語音。
  // MAX_CHARS 早就擋在前面了，這裡只是最後一道保險（data: URL 那條還要再乘 4/3）。
  if (out.length > 4 * 1024 * 1024) {
    return json(413, { status: 'Error', error: 'audio too large' });
  }

  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value);
  cache.set(key, out);

  console.log(`[tts] ${text.length} 字 → ${wantsWav ? 'wav' : 'mp3'} ${out.length} bytes`);
  return wantsWav ? wav(out) : dataUrl(out);
};

const cors = () => ({
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type',
  'access-control-allow-methods': 'POST,OPTIONS',
});

// isBase64Encoded=true → HTTP API（payload format 2.0）會自己還原成二進位，
// 不需要 REST API 那套 binaryMediaTypes 設定。
const wav = (buf) => ({
  statusCode: 200,
  isBase64Encoded: true,
  headers: { 'content-type': 'audio/wav', 'content-length': String(buf.length), ...cors() },
  body: buf.toString('base64'),
});

// 給瀏覽器的形式：沿用 Render /tts 的 {status,url} 介面，但 url 是 data: URI ——
// 音檔留在回應本身，不必開 S3、也沒有跨源與過期問題（<audio src> 吃得下 data:）。
const dataUrl = (mp3) => json(200, {
  status: 'Success',
  url: `data:audio/mpeg;base64,${mp3.toString('base64')}`,
});

const json = (statusCode, obj) => ({
  statusCode,
  headers: { 'content-type': 'application/json', ...cors() },
  body: JSON.stringify(obj),
});
