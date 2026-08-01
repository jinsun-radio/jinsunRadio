-- 修正：radio_events 寫入後同步長輩 severity「只升不降」。
-- 原本 fn_after_radio_event 一律 set severity = new.severity，導致「注意/緊急」處理中的
-- 長輩只要來一筆物資（normal）事件就被悄悄降回 normal。改成只升不降；降級一律由 App
-- 明確處理（confirmElderOk / resolveTask 直接改 elders）。冪等，對有資料的正式 DB 安全。

create or replace function fn_after_radio_event() returns trigger as $$
declare cur text;
begin
  select severity into cur from elders where id = new.elder_id;
  update elders
    set last_activity_at = new.occurred_at,
        severity = case
          when new.severity = 'emergency' then 'emergency'
          when new.severity = 'attention' and coalesce(cur,'normal') <> 'emergency' then 'attention'
          else coalesce(cur, new.severity)
        end
    where id = new.elder_id;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_after_radio_event on radio_events;
create trigger trg_after_radio_event after insert on radio_events
  for each row execute function fn_after_radio_event();
