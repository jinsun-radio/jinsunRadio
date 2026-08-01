-- 來電推播：call_signals 新增（ringing）→ send-push。
-- 背景／被系統凍結的 App 收不到 realtime 號誌，靠 FCM 推播叫醒。
-- 只掛 INSERT：接聽／掛斷等狀態變化由 App 內 realtime 處理，不需要推播。
drop trigger if exists trg_push_call_signals on public.call_signals;
create trigger trg_push_call_signals
  after insert on public.call_signals
  for each row execute function public.notify_send_push();
