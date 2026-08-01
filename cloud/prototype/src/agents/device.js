// Agent 6 · Device Agent —— 把「音量大一點／關掉」轉成下發給硬體的指令。
// 正式走 AWS IoT Core（MQTT）下發；原型只回一個 command 物件由 server 轉發。

import { DEVICE_WORDS, normalize } from '../config/triggers.js';

const REPLY = {
  volume_up: '好，我把聲音調大一點。',
  volume_down: '好，我把聲音調小一點。',
  stop_speak: '好，我先安靜，需要我再叫我「金孫」。',
  repeat: '好，我再說一次。',
};

export function createDeviceAgent() {
  return {
    async handle({ text }) {
      const n = normalize(text);
      let command = 'repeat';
      for (const g of DEVICE_WORDS) {
        if (g.match.some((m) => n.includes(normalize(m)))) {
          command = g.command;
          break;
        }
      }
      return {
        reply: REPLY[command] || '好的。',
        action: { type: 'device_command', command },
      };
    },
  };
}
