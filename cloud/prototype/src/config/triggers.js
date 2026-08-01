// 金孫收音機 · 語音 Agent server 觸發表（Rule-based，寫死在 server 端）
//
// 這一層不進 LLM：速度快、行為穩定、可審計。硬體只做「喚醒 + 錄音 + ASR → 文字」，
// 文字進到 server 後先過這張表，命中才有可能省下一次 LLM 呼叫並直接進對應 Agent。
//
// 分三類：
//   1) WAKE_WORDS      喚醒詞（喚醒後才開始把後續語音轉文字送上來）
//   2) EMERGENCY_WORDS 高優先急救詞（命中即進 Emergency Agent，不等 LLM）
//   3) NEED_WORDS      日常需求詞（命中即進 Needs Agent）
//   4) DEVICE_WORDS    裝置控制詞（命中即進 Device Agent）
//   5) STANDDOWN_WORDS 「我沒事」類解除詞（急救對話中用來解除）
//
// 比對一律做正規化（去標點、全形轉半形、去空白），用「包含」判斷。

/** 品牌／喚醒詞。可依產品命名調整（預設「小金孫」）。 */
export const WAKE_WORDS = [
  '小金孫', '金孫', '嘿金孫', '金孫你好', '阿金',
  '救命', 'help', 'sos', '有人嗎', '有人在嗎',
];

/** 高優先急救詞 → Emergency Agent（不經 LLM）。 */
export const EMERGENCY_WORDS = [
  '救命', '救我', '快來救我', '快來人',
  '我跌倒', '跌倒了', '摔倒', '我起不來', '爬不起來', '站不起來',
  '好痛', '很痛', '好難過', '不舒服',
  '喘不過氣', '不能呼吸', '快不能呼吸', '呼吸困難',
  '胸口痛', '胸口好痛', '心臟',
  '流血', '我流血了',
  '昏倒', '頭暈', '暈倒', '天旋地轉',
  'sos',
];

/** 日常需求詞 → Needs Agent。value 為要建立的物資／代辦標的。 */
export const NEED_WORDS = [
  { match: ['想喝水', '口渴', '要喝水'], item: '喝水' },
  { match: ['餓了', '肚子餓', '想吃東西', '想吃飯'], item: '吃飯' },
  { match: ['要吃藥', '該吃藥', '忘記吃藥', '藥'], item: '吃藥提醒' },
  { match: ['上廁所', '要尿尿', '想大號'], item: '如廁協助' },
  { match: ['想睡覺', '睡不著', '失眠'], item: '休息' },
  { match: ['叫家人', '找我兒子', '找我女兒', '聯絡家人'], item: '聯絡家人' },
  { match: ['叫看護', '找看護', '找志工', '需要幫忙'], item: '生活協助' },
  { match: ['買', '需要', '幫我準備'], item: null }, // 泛用採買，交給 Needs Agent 抽取品項
];

/** 裝置控制詞 → Device Agent。 */
export const DEVICE_WORDS = [
  { match: ['大聲', '音量大', '聽不清楚', '太小聲'], command: 'volume_up' },
  { match: ['小聲', '音量小', '太吵', '太大聲'], command: 'volume_down' },
  { match: ['關掉', '安靜', '停止', '別說了'], command: 'stop_speak' },
  { match: ['再說一次', '你說什麼', '沒聽到'], command: 'repeat' },
];

/** 急救對話中，長輩用來主動解除的詞（含國語其他說法與台語，避免台語長輩無法取消）。 */
export const STANDDOWN_WORDS = [
  // 國語
  '我沒事', '沒事', '沒關係', '不用', '好了', '不痛了', '我很好', '不用麻煩',
  '不要緊', '沒怎樣', '我還好', '好多了', '沒問題',
  // 台語（免啦／毋免／袂要緊／無要緊／無代誌／我好好／好好啦）
  '免啦', '毋免', '袂要緊', '無要緊', '無代誌', '我好好', '好好啦',
];

/**
 * 急救對話腳本與逾時階梯（server 端狀態機）。
 *
 * 設計原則：長輩「主動」喊救命／說跌倒 = 已在求救，確認窗口要短，
 * 才守得住黃金時間（架構約束：疑似跌倒 20 秒內要升級）。
 * ladder 兩階 waitMs 相加 = 20000ms（8s + 12s），升級剛好落在 20 秒，不超窗。
 * 秒數可用環境變數調短方便測試（EMERGENCY_WAIT1_MS / EMERGENCY_WAIT2_MS）。
 */
export const EMERGENCY_SCRIPT = {
  // 第一句：立即回應，讓長輩知道「有人在」，降低恐慌。
  // passive=true（相機／被動聲學偵測，長輩沒開口）→ 不可謊稱「我聽到您說…」，
  // 否則長輩會困惑或反駁；active（長輩主動喊）才複述他說的話。
  onStart: (kw, { passive = false } = {}) =>
    passive
      ? '我這邊注意到您那邊好像有狀況，可能跌倒了，我有點擔心您。您現在還好嗎？可以回我一聲嗎？'
      : `我聽到您說「${kw}」了，我在這裡。請問您現在還好嗎？可以回我一聲嗎？`,

  // 逾時階梯：每一階等待 waitMs 內若無回應，就播下一句；最後一階 escalate。
  ladder: [
    {
      waitMs: Number(process.env.EMERGENCY_WAIT1_MS) || 8000,
      say: '我沒有聽到您的聲音。如果您沒事，請跟我說「我沒事」；如果需要幫忙，說一聲就好。',
    },
    {
      waitMs: Number(process.env.EMERGENCY_WAIT2_MS) || 12000,
      say: '我還是聯絡不到您。我現在就幫您通知家人和附近的志工過來，請您撐著，馬上有人到。',
      escalate: true, // 這一階結束 = 升級派遣（8s + 12s = 20s，守住黃金窗）
    },
  ],

  // 升級後對長輩的安撫（拿到志工 ETA 後可再覆蓋）
  onEscalated: '別擔心，我已經幫您叫人了，很快就會有人到，我會一直陪著您。',

  // 長輩主動說「我沒事」時的解除語
  onStanddown: '好，聽到您沒事我就放心了。有需要隨時叫我「金孫」就好。',
};

const FULLWIDTH_OFFSET = 0xfee0;

/** 正規化：全形轉半形、轉小寫、去標點與空白。 */
export function normalize(text) {
  if (!text) return '';
  let s = String(text).replace(/[！-～]/g, (c) =>
    String.fromCharCode(c.charCodeAt(0) - FULLWIDTH_OFFSET),
  );
  return s.toLowerCase().replace(/[\s，。！？、,.!?~～]/g, '');
}

/** 命中任一關鍵詞就回傳該詞（原字串），否則 null。 */
export function firstHit(text, words) {
  const n = normalize(text);
  for (const w of words) {
    if (n.includes(normalize(w))) return w;
  }
  return null;
}
