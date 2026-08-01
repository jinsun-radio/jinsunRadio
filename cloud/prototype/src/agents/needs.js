// Agent 3 · Needs Agent —— 把「我口渴／我想買牛奶跟雞蛋」解析成物資／代辦，
// 建立 supply 派遣單（寫 Supabase，觸發志工端接單）。

import { llm } from '../llm/bedrock.js';
import { NEED_WORDS, normalize } from '../config/triggers.js';

const SYSTEM = `你幫獨居長輩把口語需求整理成待辦。輸出 JSON：
{"category":"supply|reminder|contact|care","items":["品項1","品項2"],"speak":"要回長輩的一句安撫話"}
- supply：要採買的東西（牛奶、雞蛋、衛生紙…）。
- reminder：吃藥、喝水等提醒。
- contact：想聯絡家人。
- care：如廁、起身等生活協助。
items 用簡短名詞。speak 用溫暖、口語、短句。只回 JSON。`;

// mock 模式的簡易品項抽取：「我想買牛奶跟雞蛋」→ ['牛奶','雞蛋']（正式版由 Bedrock 做）
function extractItems(text) {
  const m = String(text || '').match(/(?:想買|要買|幫我買|買|想要|需要)(.+)/);
  if (!m) return [];
  return m[1]
    .replace(/[。！？!?.、]*$/g, '')
    .split(/[跟和與、,，]|以及| and /)
    .map((s) => s.trim())
    .filter(Boolean)
    .slice(0, 5);
}

function ruleItem(text) {
  const n = normalize(text);
  for (const g of NEED_WORDS) {
    if (g.item && g.match.some((m) => n.includes(normalize(m)))) return g.item;
  }
  return null;
}

/** @param {{createSupply:(o:object)=>Promise<object>}} deps */
export function createNeedsAgent(deps) {
  return {
    async handle({ elderKey, deviceSerial, elderId, text }) {
      // 先用規則／樣式快速抽品項，**立刻建單＋廣播**（志工端 2 秒內亮單）——不把上單卡在 LLM 後面。
      // 之前是先 await LLM 再 createSupply，正式站接 Bedrock 時整條上單延遲＝LLM 往返，達不到 2 秒。
      const bought = extractItems(text);
      const isSupply = bought.length > 0;
      const items = isSupply ? bought : [ruleItem(text) || '生活協助'];
      const category = isSupply ? 'supply' : 'care';
      const fallbackSpeak = isSupply
        ? `好，我幫您買${items.join('、')}，通知志工去採買。`
        : `好，我幫您記下來「${items[0]}」，並通知志工。`;

      await deps.createSupply({ elderKey, deviceSerial, elderId, items, transcript: text, category });

      // 回長輩的安撫話可再交 LLM 潤飾——此時派遣單已建好、廣播已發，這段延遲只影響「裝置播的話」，
      // 不影響網頁上單時效。沒有 LLM（mock／離線）就用模板，一樣不卡。
      let speak = fallbackSpeak;
      try {
        const out = await llm({
          system: SYSTEM,
          user: text,
          json: true,
          mock: () => ({ speak: fallbackSpeak }),
        });
        if (out && out.speak) speak = out.speak;
      } catch (_) {
        // LLM 失敗照用模板，長輩仍聽得到回覆
      }
      return { reply: speak, action: { type: 'need_created', items } };
    },
  };
}
