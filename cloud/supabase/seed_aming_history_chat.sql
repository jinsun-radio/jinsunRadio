-- 為志工阿明的每一筆結案派遣單補上「歷史對話」（家屬↔志工）。
-- 語氣刻意寫得平淡、直接：志工第一句就是回報狀況，家屬回話簡短，不客套。
-- 冪等：先清掉先前灌的對話（保留真人測試單 7f5cae00），再重新插入。

-- 1) 補齊空白處置與備註
update dispatch_tasks
set outcome = case kind when 'emergency' then '確認沒事' else '已送達' end
where assignee_name = '阿明' and status = 'resolved'
  and (outcome is null or outcome = '');

update dispatch_tasks
set note = case kind
    when 'emergency' then '到場確認長輩無恙'
    else '物資已送達' end
where assignee_name = '阿明' and status = 'resolved'
  and (note is null or note = '');

-- 2) 清掉先前生成的對話（保留真人測試單 7f5cae00 的原始訊息）
delete from task_messages
where task_id in (
  select id from dispatch_tasks
  where assignee_name = '阿明' and status = 'resolved'
    and id <> '7f5cae00-6624-472d-84bc-0e98e340117c'
);

-- 3) 重新插入平淡版對話
with tks as (
  select t.id, t.kind, t.items, e.name as elder,
         coalesce(t.accepted_at, t.created_at) as t0,
         coalesce(nullif(array_to_string(t.items, '、'), ''), '東西') as items_str,
         row_number() over (order by t.created_at) as rn
  from dispatch_tasks t
  join elders e on e.id = t.elder_id
  where t.assignee_name = '阿明' and t.status = 'resolved'
    and not exists (select 1 from task_messages m where m.task_id = t.id)
)
-- 3a) 緊急派遣：志工第一句直接回報狀況，家屬回話簡短
insert into task_messages (task_id, from_role, text, created_at)
select tks.id, v.role::chat_from_t, v.txt, tks.t0 + (v.ord || ' min')::interval
from tks
cross join lateral (values
  (0, 'system', '系統就近指派阿明前往'),
  (1, 'family',
      case when tks.rn % 2 = 0
        then tks.elder || '剛跌倒，麻煩你去看一下'
        else tks.elder || '按了 SOS，麻煩了' end),
  (4, 'volunteer',
      case when tks.rn % 2 = 0
        then '到了，人沒事，坐在地上喘而已，扶起來了'
        else '人到了，沒外傷，意識清楚' end),
  (6, 'volunteer',
      case when tks.rn % 2 = 0
        then '血壓正常，我再看一下'
        else '先陪一下，有狀況再跟你說' end),
  (8, 'family',
      case when tks.rn % 2 = 0 then '好，謝謝' else '了解' end)
) as v(ord, role, txt)
where tks.kind = 'emergency';

-- 3b) 物資代購：買好回報，家屬簡短收到
with tks as (
  select t.id, t.kind, t.items, e.name as elder,
         coalesce(t.accepted_at, t.created_at) as t0,
         coalesce(nullif(array_to_string(t.items, '、'), ''), '東西') as items_str
  from dispatch_tasks t
  join elders e on e.id = t.elder_id
  where t.assignee_name = '阿明' and t.status = 'resolved'
    and not exists (select 1 from task_messages m where m.task_id = t.id)
)
insert into task_messages (task_id, from_role, text, created_at)
select tks.id, v.role::chat_from_t, v.txt, tks.t0 + (v.ord || ' min')::interval
from tks
cross join lateral (values
  (0, 'family', '麻煩幫 ' || tks.elder || ' 買' || tks.items_str),
  (2, 'volunteer', '好'),
  (18, 'volunteer', tks.items_str || '買好放桌上了'),
  (20, 'family', '收到')
) as v(ord, role, txt)
where tks.kind = 'supply';
