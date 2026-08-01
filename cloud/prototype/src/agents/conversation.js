// Agent 4 · Conversation Agent —— 一般陪伴聊天。
// 帶入 Memory Agent 的長期記憶，讓回覆有連續性（「今天也睡不好嗎？」）。

import { llm } from '../llm/bedrock.js';

const SYSTEM = `你是「金孫」，獨居長輩家中收音機裡的 AI 孫子。個性溫暖、有耐心、講台灣口語中文。
規則：
- 回覆要「短」（1–2 句、適合用聽的），語氣像晚輩關心長輩。
- 不要用條列、不要用艱澀詞、不要問一長串問題。
- 若長輩透露身體不適的線索，溫柔關心並提醒可以隨時說「救命」找人。
- 適時呼應你記得的事（下方 memory）。`;

/** @param {{memory:{summary:(k:string)=>string}}} deps */
export function createConversationAgent(deps) {
  return {
    async handle({ elderKey, text }) {
      const mem = deps.memory?.summary?.(elderKey) || '';
      const reply = await llm({
        system: SYSTEM + (mem ? `\n\n[你記得的事]\n${mem}` : ''),
        user: text,
        mock: (t) => mockChat(t, mem),
      });
      return { reply: String(reply).trim(), action: { type: 'chat' } };
    },
  };
}

function mockChat(text, mem) {
  const t = text || '';
  if (/天氣/.test(t)) return '外面天氣我幫您看一下，記得添件衣服別著涼喔。';
  if (/幾點|時間|星期/.test(t)) return '我幫您看時間喔，有需要我也可以提醒您吃藥。';
  if (/睡|累/.test(t)) return mem.includes('睡') ? '今天也睡不太好嗎？別擔心，我陪您聊聊。' : '想休息就休息，我在這裡陪著您。';
  if (/無聊|寂寞|一個人/.test(t)) return '我在呢，想聊什麼都可以跟我說。';
  return '嗯嗯，我聽著呢，您慢慢說。';
}
