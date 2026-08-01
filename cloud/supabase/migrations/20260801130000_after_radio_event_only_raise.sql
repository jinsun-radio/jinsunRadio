-- 修正：radio_events 寫入後同步長輩 severity「只升不降」。
-- 原本 fn_after_radio_event 一律 set severity = new.severity，導致「注意/緊急」處理中的
-- 長輩只要來一筆物資（normal）事件就被悄悄降回 normal。改成只升不降；降級一律由 App
-- 明確處理（confirmElderOk / resolveTask 直接改 elders）。冪等，對有資料的正式 DB 安全。
--
-- ⚠️ 2026-08-01 修正：本檔第一版把 `cur` 宣告成 text，造成
--     `coalesce(cur, new.severity)` ＝ coalesce(text, severity_t)
--     → 每一次 radio_events 寫入都以 42804 失敗。
--   症狀極具欺騙性：dispatch.js 對資料庫錯誤只 log 不中斷，外表看起來是
--   「派遣單開出來了，但沒有對應事件、而且 dispatch_tasks.elder_id 是 NULL」，
--   志工 App 會顯示「長輩（0 歲）」。已在 Aurora 上實際重現並驗證此修正版可用。
--   `cur` 一定要是 severity_t，兩個 coalesce 的兩邊型別才會一致。

create or replace function fn_after_radio_event() returns trigger as $$
declare cur severity_t;
begin
  select severity into cur from elders where id = new.elder_id;
  update elders
    set last_activity_at = new.occurred_at,
        severity = case
          when new.severity = 'emergency' then 'emergency'::severity_t
          when new.severity = 'attention'
               and coalesce(cur, 'normal'::severity_t) <> 'emergency'::severity_t
            then 'attention'::severity_t
          else coalesce(cur, new.severity)
        end
    where id = new.elder_id;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_after_radio_event on radio_events;
create trigger trg_after_radio_event after insert on radio_events
  for each row execute function fn_after_radio_event();
