// 依 device_serial 查長輩偏好語言（收音機所有下行語音都帶 lang，裝置端據此選國語／台語語音）。
// 不快取，讓家屬在 App 改語言後立刻生效（低頻查詢，成本可忽略）。

const URL = process.env.SUPABASE_URL || 'https://ykfxmoubynnbhnburawl.supabase.co';
const KEY =
  process.env.SUPABASE_SERVICE_KEY ||
  process.env.SUPABASE_SECRET_KEY ||
  process.env.SUPABASE_ANON_KEY ||
  '';

let _sb = null;
async function client() {
  if (_sb !== null) return _sb;
  if (!KEY) return (_sb = false);
  try {
    const { createClient } = await import('@supabase/supabase-js');
    _sb = createClient(URL, KEY, { auth: { persistSession: false } });
  } catch {
    _sb = false;
  }
  return _sb;
}

export function createElderLookup() {
  return {
    /** 回傳 'mandarin' | 'taigi'（查不到／無 Supabase → 'mandarin'）。 */
    async langOf(deviceSerial) {
      if (!deviceSerial) return 'mandarin';
      const sb = await client();
      if (!sb) return 'mandarin';
      try {
        const { data } = await sb
          .from('elders')
          .select('preferred_lang')
          .eq('device_serial', deviceSerial)
          .single();
        return data?.preferred_lang || 'mandarin';
      } catch {
        return 'mandarin';
      }
    },
  };
}
