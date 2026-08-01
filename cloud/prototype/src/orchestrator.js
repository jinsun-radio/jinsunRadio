// Conversation Orchestrator —— 語音 Agent server 的大腦。
//
// 每一句進來的文字：
//   1) 若該長輩正在急救對話中 → 先交給 Emergency Agent（吃掉解除詞／後續回應）
//   2) rule 快路徑 + Intent Agent 分類 → emergency / need / device / general
//   3) 交給對應 Agent → 產生「要回給長輩的文字」＋可能的 side effect（派遣單／裝置指令）
//   4) Response Generator：把文字＋TTS/裝置指令回給硬體
//
// 對長輩的所有輸出都是「一段要用聽的短文字」＋可選 device command。

import { classifyIntent } from './agents/intent.js';
import { createEmergencyAgent } from './agents/emergency.js';
import { createNeedsAgent } from './agents/needs.js';
import { createConversationAgent } from './agents/conversation.js';
import { createDeviceAgent } from './agents/device.js';
import { createMemoryAgent } from './agents/memory.js';
import { createDispatch } from './dispatch.js';
import { firstHit, EMERGENCY_WORDS } from './config/triggers.js';

export function createOrchestrator(opts = {}) {
  const dispatch = opts.dispatch || createDispatch();
  const memory = opts.memory || createMemoryAgent();

  // speak：把文字下發給裝置做 TTS。原型交給 opts.speak（server 端可串 MQTT/WS）。
  const speak = opts.speak || (async (elderKey, text) => ({ elderKey, text }));

  const emergency = createEmergencyAgent({
    speak,
    // 偵測到就先寫 attention（家屬端「AI 確認中」卡），20 秒後 escalate 更新同一列
    openAsking: (ctx) => dispatch.openAsking(ctx),
    escalate: (ctx) => dispatch.escalateEmergency(ctx),
    setTimer: opts.setTimer,
    clearTimer: opts.clearTimer,
  });
  const needs = createNeedsAgent({ createSupply: (o) => dispatch.createSupply(o) });
  const conversation = createConversationAgent({ memory });
  const device = createDeviceAgent();

  /**
   * 處理一句話。
   * @param {object} msg
   * @param {string} msg.deviceSerial 硬體序號（JS-0001）
   * @param {string} [msg.elderId]    已知的 elder id（可省，靠 device_serial 反查）
   * @param {string} msg.text         ASR 後的文字
   * @returns {Promise<{reply:string, intent:string, action:object}>}
   */
  async function handle({ deviceSerial, elderId, text, immediate = false, passive = false }) {
    const elderKey = elderId || deviceSerial || 'unknown';
    memory.remember(elderKey, deriveMemoryNote(text));

    // 1) 急救對話進行中：後續語句先給 Emergency Agent
    if (emergency.isActive(elderKey)) {
      const r = await emergency.onReply({ elderKey, text });
      if (r.handled) {
        if (r.resolved) emergency.resolve(elderKey);
        return { reply: r.reply, intent: 'emergency', action: r.action };
      }
    }

    // 2) 分類
    const { intent, via } = await classifyIntent(text);

    // 3) 分派
    if (intent === 'emergency') {
      const kw = firstHit(text, EMERGENCY_WORDS) || '救命';
      const r = await emergency.start({ elderKey, deviceSerial, elderId, text, keyword: kw, immediate, passive });
      return { reply: r.reply, intent, action: { ...r.action, via } };
    }
    if (intent === 'need') {
      const r = await needs.handle({ elderKey, deviceSerial, elderId, text });
      return { reply: r.reply, intent, action: { ...r.action, via } };
    }
    if (intent === 'device') {
      const r = await device.handle({ text });
      return { reply: r.reply, intent, action: { ...r.action, via } };
    }
    const r = await conversation.handle({ elderKey, text });
    return { reply: r.reply, intent: 'general', action: { ...r.action, via } };
  }

  return { handle, emergency, memory, dispatch };
}

// 極輕量：從語句抽出值得長期記住的線索（正式版可用 Memory Agent LLM）。
function deriveMemoryNote(text) {
  const t = text || '';
  if (/睡不著|失眠/.test(t)) return '晚上常說睡不著';
  if (/膝蓋|腰|關節/.test(t)) return '提過關節/腰不舒服';
  if (/孫子|兒子|女兒|想念/.test(t)) return '會想念家人';
  return '';
}
