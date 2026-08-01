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
items 用簡短名詞。speak 用溫暖、口語、短句。
speak **一律以「您」相稱，絕不使用任何長輩稱謂**（不要說「阿公」「阿嬤」「爺爺」「奶奶」「老人家」，
也不要用「阿公/阿嬤」這種並列寫法）——我們不知道對方的性別與輩分，叫錯會讓長輩不舒服。
speak **會直接送進 TTS 念出來**：不要表情符號、不要顏文字、不要 Markdown、不要括號註記，
只用一般標點（，。！？）。
只回 JSON。`;

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
      const out = await llm({
        system: SYSTEM,
        user: text,
        json: true,
        mock: () => {
          const bought = extractItems(text);
          if (bought.length) {
            return { category: 'supply', items: bought, speak: `好，我幫您買${bought.join('、')}，通知志工去採買。` };
          }
          const item = ruleItem(text) || '生活協助';
          return { category: 'care', items: [item], speak: `好，我幫您記下來「${item}」，並通知志工。` };
        },
      });

      const items = Array.isArray(out.items) && out.items.length ? out.items : [ruleItem(text) || '生活協助'];
      const speak = out.speak || `好的，我幫您記下來，並通知志工過來協助。`;

      await deps.createSupply({ elderKey, deviceSerial, elderId, items, transcript: text, category: out.category });
      return { reply: speak, action: { type: 'need_created', items } };
    },
  };
}
