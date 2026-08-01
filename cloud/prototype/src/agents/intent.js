// Agent 1 · Intent Agent —— 只做分類，不回答。
// 先走 rule 快路徑（觸發表命中即定案，省一次 LLM）；沒命中才問 LLM。
// 輸出：'emergency' | 'need' | 'device' | 'general'

import { llm } from '../llm/bedrock.js';
import {
  EMERGENCY_WORDS,
  NEED_WORDS,
  DEVICE_WORDS,
  firstHit,
  normalize,
} from '../config/triggers.js';

const SYSTEM = `你是長輩陪伴系統的意圖分類器。只輸出一個 JSON：{"intent":"emergency|need|device|general"}。
規則：
- emergency：跌倒、受傷、劇痛、呼吸困難、胸痛、流血、昏倒、明確求救。
- need：口渴、肚子餓、吃藥、如廁、想找家人／看護、想買東西等生活需求。
- device：調整音量、關掉、再說一次等對機器本身的操作。
- general：一般聊天、問時間天氣、閒聊。
只回 JSON，不要多餘文字。`;

function ruleIntent(text) {
  if (firstHit(text, EMERGENCY_WORDS)) return 'emergency';
  const n = normalize(text);
  for (const g of DEVICE_WORDS) if (g.match.some((m) => n.includes(normalize(m)))) return 'device';
  for (const g of NEED_WORDS) if (g.match.some((m) => n.includes(normalize(m)))) return 'need';
  return null;
}

export async function classifyIntent(text) {
  const fast = ruleIntent(text);
  if (fast) return { intent: fast, via: 'rule' };

  const out = await llm({
    system: SYSTEM,
    user: text,
    json: true,
    fast: true, // 意圖分類走快模型（Haiku）：高頻、低延遲、低成本
    mock: () => ({ intent: 'general' }), // 離線時：非觸發詞一律當閒聊
  });
  const intent = ['emergency', 'need', 'device', 'general'].includes(out.intent)
    ? out.intent
    : 'general';
  return { intent, via: 'llm' };
}
