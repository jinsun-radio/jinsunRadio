// Agent 5 · Memory Agent —— 記住長輩反覆出現的狀態/偏好，供 Conversation Agent 呼應。
// 原型用記憶體 Map；正式對應 DynamoDB（key = elderKey）。

/** @type {Map<string, {notes:string[], updatedAt:number}>} */
const store = new Map();
const MAX_NOTES = 8;

export function createMemoryAgent() {
  return {
    /** 記一筆觀察（去重、限量）。 */
    remember(elderKey, note) {
      if (!note) return;
      const rec = store.get(elderKey) || { notes: [], updatedAt: 0 };
      if (!rec.notes.includes(note)) {
        rec.notes.push(note);
        if (rec.notes.length > MAX_NOTES) rec.notes.shift();
      }
      rec.updatedAt = Date.now?.() ?? 0;
      store.set(elderKey, rec);
    },

    /** 給 Conversation Agent 的摘要字串。 */
    summary(elderKey) {
      const rec = store.get(elderKey);
      return rec ? rec.notes.join('；') : '';
    },

    _store: store,
  };
}
