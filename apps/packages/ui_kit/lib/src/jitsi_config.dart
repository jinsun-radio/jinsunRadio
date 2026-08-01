/// Jitsi 伺服器位址（io 與 web 兩個 launcher 共用）。
///
/// 不用預設的 meet.jit.si：它自 2023 起要求每個新房間第一位進房者
/// 必須登入帳號當主持人，匿名使用者會卡在等候室，行動端還會被導去
/// 裝 Jitsi 官方 App——整個遮罩通話流程直接斷掉。
/// meet.ffmuc.net（Freifunk München 公益站）允許匿名開房，但站在德國，
/// 台灣連過去延遲高、接通慢。**要更快就換近一點／自架的伺服器**——
/// 用 --dart-define=JITSI_URL=https://你的-jitsi 覆寫，程式不用改。
/// 正式上線強烈建議自架（延遲、隱私、穩定都更好）。
const String kJitsiServerUrl = String.fromEnvironment(
  'JITSI_URL',
  defaultValue: 'https://meet.ffmuc.net',
);
