// Agent 2 · Emergency Agent —— 急救對話狀態機（server 端持有）。
//
// 這是黃金時間鏈路的核心：長輩喊「救命／我跌倒了」→ 立即安撫 →
// 逾時階梯詢問 → 最後一階仍無回應 → 升級派遣（寫進 Supabase，觸發三端推播）。
//
// 為什麼放 server 而不是硬體：計時器一旦跑在 App／裝置上，關機或斷線就失效；
// 放雲端狀態機才守得住「20 秒無回應必升級」的合約。
//
// 一位長輩同時只維持一個 session（Map key = elderKey）。

import { EMERGENCY_SCRIPT, STANDDOWN_WORDS, firstHit } from '../config/triggers.js';

/**
 * @param {object} deps
 * @param {(elderKey:string, text:string)=>Promise<void>} deps.speak  下發 TTS 給裝置
 * @param {(ctx:object)=>Promise<object>} deps.escalate  升級派遣（寫 Supabase）
 * @param {(ms:number, fn:Function)=>any} [deps.setTimer] 可注入（測試用）
 * @param {(t:any)=>void} [deps.clearTimer]
 */
export function createEmergencyAgent(deps) {
  const setTimer = deps.setTimer || setTimeout;
  const clearTimer = deps.clearTimer || clearTimeout;
  // 升級後兜底清 session 的時限：志工多半用 App 到場結案（非長輩口說「我沒事」），
  // 沒有解除詞就永遠不會 resolve，久了長輩任何一句話都被當急救。過期即自動清。
  const EXPIRE_MS =
    Number(process.env.EMERGENCY_SESSION_EXPIRE_MS) || 15 * 60 * 1000;

  /** @type {Map<string, object>} elderKey -> session（每個 agent 實例獨立） */
  const sessions = new Map();

  function clear(session) {
    if (session?.timer) clearTimer(session.timer);
    if (session?.expireTimer) clearTimer(session.expireTimer);
  }

  /** 進入下一階逾時；跑完最後一階就升級。 */
  function armLadder(elderKey, session) {
    const step = EMERGENCY_SCRIPT.ladder[session.stage];
    if (!step) return;
    session.timer = setTimer(async () => {
      await deps.speak(elderKey, step.say);
      if (step.escalate) {
        await doEscalate(elderKey, session);
      } else {
        session.stage += 1;
        armLadder(elderKey, session);
      }
    }, step.waitMs);
  }

  // 升級派遣。speak=true 時透過下行通道播安撫語（計時器路徑用）；
  // speak=false 時只回傳安撫語文字，由同步呼叫端放進 HTTP 回應（避免重複播）。
  async function doEscalate(elderKey, session, { speak = true } = {}) {
    session.status = 'escalated';
    clear(session);
    const result = await deps.escalate({
      elderKey,
      deviceSerial: session.deviceSerial,
      elderId: session.elderId,
      keyword: session.keyword,
      transcript: session.transcript,
      // 有值＝升級 start() already 寫好的那列 attention 事件，而不是插一筆新的
      eventId: session.eventId,
    });
    const eta = result?.etaMinutes;
    const text = eta
      ? `別擔心，志工已經在路上，大約 ${eta} 分鐘到，我會一直陪著您。`
      : EMERGENCY_SCRIPT.onEscalated;
    if (speak) await deps.speak(elderKey, text);
    // 升級後保留 session 供後續到場安撫；但掛一個過期計時器兜底清除，
    // 避免志工用 App 到場結案（沒有解除詞）時 session 永遠殘留、污染後續對話。
    if (session.expireTimer) clearTimer(session.expireTimer);
    session.expireTimer = setTimer(() => {
      if (sessions.get(elderKey) === session) sessions.delete(elderKey);
    }, EXPIRE_MS);
    return text;
  }

  return {
    /**
     * 起始一次急救對話。text 為觸發語句，keyword 為命中的急救詞。
     * immediate=true（實體 SOS 鍵）→ 不問診、立刻升級派遣。
     */
    async start({ elderKey, deviceSerial, elderId, text, keyword, immediate = false, passive = false }) {
      const prev = sessions.get(elderKey);
      if (prev && prev.status !== 'resolved') clear(prev); // 重觸發：重置

      const session = {
        elderKey,
        deviceSerial,
        elderId,
        keyword: keyword || '救命',
        transcript: text,
        stage: 0,
        status: 'asking',
        timer: null,
      };
      sessions.set(elderKey, session);

      if (immediate) {
        const escalatedText = await doEscalate(elderKey, session, { speak: false });
        return { reply: escalatedText, action: { type: 'emergency_escalated' } };
      }

      // 先讓三端知道「正在確認」——不等 20 秒。這 20 秒家屬最焦慮，不能讓 App 還寫著「一切安好」。
      // 寫失敗只記 log 不 throw：黃金 20 秒的升級鏈路不能因為這一筆寫不進去就中斷。
      if (deps.openAsking) {
        try {
          session.eventId = await deps.openAsking({
            elderKey,
            deviceSerial: session.deviceSerial,
            elderId: session.elderId,
            keyword: session.keyword,
            transcript: session.transcript,
          });
        } catch (e) {
          console.error('[emergency] 寫「AI 詢問中」失敗，繼續走升級鏈路：', e?.message || e);
        }
      }

      const reply = EMERGENCY_SCRIPT.onStart(session.keyword, { passive });
      armLadder(elderKey, session);
      return { reply, action: { type: 'emergency_asking' } };
    },

    /**
     * 對話中收到長輩後續語句。
     * 回傳 handled=true 表示這句被急救對話吃掉了（外層不再另行處理）。
     */
    async onReply({ elderKey, text }) {
      const session = sessions.get(elderKey);
      if (!session || session.status === 'resolved') return { handled: false };

      // 主動解除
      if (firstHit(text, STANDDOWN_WORDS)) {
        session.status = 'resolved';
        clear(session);
        sessions.delete(elderKey);
        return {
          handled: true,
          resolved: true,
          reply: EMERGENCY_SCRIPT.onStanddown,
          action: { type: 'emergency_standdown' },
        };
      }

      // 已升級（志工已在路上）→ 後續非解除詞不再重新升級，只安撫。
      // 否則長輩升級後說「我口渴／閒聊」都會被 doEscalate 再升級一次、後續事件也被吃掉。
      if (session.status === 'escalated') {
        return {
          handled: true,
          reply: EMERGENCY_SCRIPT.onEscalated,
          action: { type: 'emergency_reassured' },
        };
      }

      // 詢問階段（尚未升級）有回應但非解除 → 長輩明確在求救情境且有話說 → 升級，交給人到場判斷。
      const escalatedText = await doEscalate(elderKey, session, { speak: false });
      return {
        handled: true,
        reply: escalatedText,
        action: { type: 'emergency_escalated' },
      };
    },

    /** 是否有進行中的急救對話。 */
    isActive(elderKey) {
      const s = sessions.get(elderKey);
      return !!s && s.status !== 'resolved';
    },

    /** 志工到場／結案後清除 session。 */
    resolve(elderKey) {
      const s = sessions.get(elderKey);
      if (s) clear(s);
      sessions.delete(elderKey);
    },

    _sessions: sessions, // 測試用
  };
}
