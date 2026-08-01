-- 金孫收音機 · Supabase Schema v1
-- 對應 jinsun_core 的資料模型，並支援：硬體事件 HTTP 上報、跨端聊天、即時推播。
-- 執行方式：psql "$CONN" -f schema.sql  或貼到 Supabase Dashboard → SQL Editor。
-- 可安全重跑（idempotent migration）：型別以「不存在才建立」的 do-block 建置、資料表／索引
--   用 if not exists、function 用 create or replace、trigger／policy 先 drop if exists 再建、
--   種子資料一律 on conflict do update/nothing。全程不 drop 任何資料表或欄位，重跑不會掉資料。

-- ========== 型別 ==========
-- 可安全重跑：型別「不存在才建立」，絕不 drop——drop type cascade 會連帶刪掉所有
-- 使用該 enum 的欄位（severity/status/kind…），而下方 create table if not exists 不會補回。
-- 若日後要為某個 enum 新增值，用：alter type <型別> add value if not exists '<新值>';（勿改動這裡）
do $$ begin create type user_role as enum ('family','volunteer','worker'); exception when duplicate_object then null; end $$;
do $$ begin create type severity_t as enum ('normal','attention','emergency'); exception when duplicate_object then null; end $$;
do $$ begin create type event_type_t as enum ('sos','fall_suspected','supply_request'); exception when duplicate_object then null; end $$;
do $$ begin create type event_status_t as enum ('open','confirmed_ok','escalated','closed'); exception when duplicate_object then null; end $$;
do $$ begin create type dispatch_kind_t as enum ('emergency','supply'); exception when duplicate_object then null; end $$;
do $$ begin create type dispatch_status_t as enum ('pending','accepted','arrived','resolved'); exception when duplicate_object then null; end $$;
do $$ begin create type chat_from_t as enum ('family','volunteer','system'); exception when duplicate_object then null; end $$;
do $$ begin create type lang_t as enum ('mandarin','taigi'); exception when duplicate_object then null; end $$;   -- 長輩偏好語言：國語／台語（收音機 TTS 用）

-- ========== 資料表 ==========

-- 使用者 profile（連 Supabase Auth 的 auth.users）
create table if not exists profiles (
  id uuid primary key references auth.users on delete cascade,
  role user_role not null default 'family',
  name text not null default '',
  phone text,
  created_at timestamptz not null default now()
);

-- 長輩（收音機裝置對應的被照顧者）
create table if not exists elders (
  id text primary key,                 -- elder-1…（demo 沿用 mock id）
  device_serial text unique,           -- JS-0001（硬體序號）
  name text not null,
  age int,
  address text,
  phone text,                          -- 長輩／家中聯絡電話（家屬緊急撥打用）
  lat double precision default 0,
  lng double precision default 0,
  severity severity_t not null default 'normal',
  preferred_lang lang_t not null default 'mandarin',   -- 長輩偏好語言（家屬 App 設定；收音機播報用）
  note text,                           -- 簡單狀況注記（獨居／慢性病／行動狀況等，社工填寫）
  last_activity_at timestamptz default now()
);
-- 既有資料庫（create table 已存在時不會補欄位）→ 補上新欄位
alter table elders add column if not exists preferred_lang lang_t not null default 'mandarin';
alter table elders add column if not exists note text;
alter table elders add column if not exists supervisor_worker_name text;      -- 督導社工（長期指定）
alter table elders add column if not exists supervisor_volunteer_name text;    -- 督導志工（長期關懷）
alter table elders add column if not exists phone text;                        -- 長輩／家中聯絡電話

-- 家屬綁定長輩（一位家屬可綁多台，一台可多位家屬）
create table if not exists family_bindings (
  family_id uuid references auth.users on delete cascade,
  elder_id text references elders on delete cascade,
  created_at timestamptz default now(),
  primary key (family_id, elder_id)
);

-- 社工名單與班表
create table if not exists social_workers (
  id text primary key,
  name text not null,
  phone text,
  shift_start_hour int not null,
  shift_end_hour int not null
);

-- 志工（時間銀行人力，可被社工指派）＋可服務時段
-- service_hours：JSON 陣列，每筆 {"weekdays":[1..7], "start":h, "end":h}（weekday 1=一…7=日）
create table if not exists volunteers (
  id text primary key,
  name text not null,
  phone text default '',
  lat double precision default 0,
  lng double precision default 0,
  online boolean not null default true,
  points int not null default 0,
  intro text default '',
  service_hours jsonb not null default '[]'::jsonb,
  location_updated_at timestamptz          -- 座標最後一次「真實 GPS」回報時間（seed 為 null）
);
alter table volunteers add column if not exists location_updated_at timestamptz;

-- 志工證件紀錄與狀態（良民證／志工意外險／基礎照護證書）
-- kind: good_citizen | insurance | basic_training
-- status: none | pending | valid | expired
create table if not exists volunteer_certificates (
  id uuid primary key default gen_random_uuid(),
  volunteer_id text references volunteers on delete cascade,
  kind text not null,
  status text not null default 'none',
  issued_at date,
  expires_at date,
  note text,
  unique (volunteer_id, kind)
);

-- 系統設定（後台可即時切換的 key/value；例：llm_provider = mock|apikey|bedrock）
-- 語音 Agent server 每次呼叫 LLM 前讀這裡（短快取），社工後台改了免重新部署。
create table if not exists app_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);
insert into app_settings (key, value) values ('llm_provider', 'apikey')
on conflict (key) do nothing;
-- 派遣定位模式：simulate（模擬出發，demo 用）｜real（只用真實 GPS，否則定位中）
insert into app_settings (key, value) values ('dispatch_tracking', 'simulate')
on conflict (key) do nothing;

-- 生活歷史紀錄（家屬視角的活動流）：每日平安、吃藥、用餐、志工探訪、散步、購物、
-- 血壓、家屬查看、夜間平安…等。家屬 App「歷史紀錄」與「即時紀錄」由此呈現。
-- 一律用家屬看得懂的文字（不放系統術語如「派遣單」）。
create table if not exists life_events (
  id uuid primary key default gen_random_uuid(),
  elder_id text references elders on delete cascade,
  at timestamptz not null,
  kind text not null,                       -- daily|med|meal|visit|walk|errand|vital|family|night|fall|supply|help|dispatch
  text text not null,                       -- 家屬視角文字
  severity text not null default 'normal'   -- normal|attention|emergency（決定圖示顏色）
);
create index if not exists idx_life_elder on life_events(elder_id, at desc);

-- 收音機事件（硬體 HTTP POST 進來；只送 device_serial，trigger 補 elder_id）
create table if not exists radio_events (
  id uuid primary key default gen_random_uuid(),
  elder_id text references elders on delete cascade,
  device_serial text,
  type event_type_t not null,
  status event_status_t not null default 'open',
  severity severity_t not null default 'attention',
  transcript text,
  occurred_at timestamptz not null default now()
);

-- 派遣單
create table if not exists dispatch_tasks (
  id uuid primary key default gen_random_uuid(),
  elder_id text references elders on delete cascade,
  event_id uuid references radio_events on delete set null,
  kind dispatch_kind_t not null,
  status dispatch_status_t not null default 'pending',
  assignee_name text,                  -- 到場志工顯示名
  assignee_id uuid,                    -- 接單志工 auth uid
  worker_name text,                    -- 督導社工（依值班＋單量指派）
  eta_minutes int,
  items text[] default '{}',
  note text,                           -- 志工到場回報備註（家屬可見）
  offered_until timestamptz,           -- 物資單寬限期：此時間前只 offer 給督導志工＋家屬；到期或「請求支援」才廣播全體
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
-- 既有資料庫補欄位
alter table dispatch_tasks add column if not exists offered_until timestamptz;
-- 任務時間軸：接單/出發、到場的時間點；結案處置（確認沒事／送往醫院…）
alter table dispatch_tasks add column if not exists accepted_at timestamptz;
alter table dispatch_tasks add column if not exists arrived_at timestamptz;
alter table dispatch_tasks add column if not exists outcome text;

-- 派遣單聊天訊息（家屬↔志工，限時遮罩，隨派遣單存活）
create table if not exists task_messages (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references dispatch_tasks on delete cascade,
  from_role chat_from_t not null,
  sender_id uuid,
  text text not null,
  created_at timestamptz not null default now()
);

-- 時間銀行點數帳本（志工）
create table if not exists time_bank_ledger (
  id uuid primary key default gen_random_uuid(),
  volunteer_id uuid,
  volunteer_name text,
  task_id uuid references dispatch_tasks on delete set null,
  points int not null,
  reason text,
  created_at timestamptz default now()
);

-- 限時遮罩通話號誌（家屬↔志工，Jitsi in-app 通話 + 來電響鈴）
-- 一通話一列；狀態流轉 ringing→accepted/declined/canceled/ended。
-- 沒有任何電話號碼欄位——遮罩天生成立（雙方只共用 room 名稱）。
create table if not exists call_signals (
  id uuid primary key default gen_random_uuid(),
  task_id text not null,               -- 對應派遣單（分組用；不設 FK 以相容 demo id）
  room text not null,                  -- Jitsi 房間名（不可猜；雙方進同一房）
  from_role text not null,             -- 'family' | 'volunteer'
  to_role text not null,
  status text not null default 'ringing',  -- ringing|accepted|declined|canceled|ended
  from_name text,                      -- 來電顯示名（志工可露名；家屬顯示「家屬」）
  created_at timestamptz not null default now()
);
create index if not exists idx_calls_task on call_signals(task_id, created_at desc);

create index if not exists idx_events_elder on radio_events(elder_id, occurred_at desc);
create index if not exists idx_tasks_status on dispatch_tasks(status, created_at desc);
create index if not exists idx_msgs_task on task_messages(task_id, created_at);

-- ========== 觸發器：硬體只送序號，補上 elder_id 並更新長輩狀態 ==========
create or replace function fn_on_radio_event() returns trigger as $$
begin
  if new.elder_id is null and new.device_serial is not null then
    select id into new.elder_id from elders where device_serial = new.device_serial;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_radio_event on radio_events;
create trigger trg_radio_event before insert on radio_events
  for each row execute function fn_on_radio_event();

-- 事件寫入後，把長輩狀態同步為事件分級——但「只升不降」：
-- 物資（normal）等低分級事件不可把「注意／緊急」中的長輩降回 normal（否則長輩處理中
-- 又來一筆物資就被悄悄降級）。降級一律由 App 明確處理（confirmElderOk／resolveTask
-- 直接改 elders）。升級的 escalate 走 radio_events UPDATE，其 elders 同步由 App 端處理。
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

-- 新帳號自動建 profile
create or replace function fn_handle_new_user() returns trigger as $$
begin
  insert into profiles (id, role, name)
  values (new.id,
          coalesce((new.raw_user_meta_data->>'role')::user_role, 'family'),
          coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists trg_new_user on auth.users;
create trigger trg_new_user after insert on auth.users
  for each row execute function fn_handle_new_user();

-- 裝置推播 token（FCM registration token）。三端 App 登入後上報，
-- send-push Edge Function 依此查收件者。role=收件角色；elder_ids=家屬綁定的長輩
-- （只收這些長輩的事件通知）；志工／社工的 elder_ids 為空，靠 role 廣播。
create table if not exists device_tokens (
  token       text primary key,
  user_id     uuid references auth.users(id) on delete cascade,
  role        text not null,
  platform    text,
  elder_ids   text[] not null default '{}',
  updated_at  timestamptz not null default now()
);
create index if not exists idx_device_tokens_role on device_tokens (role);
create index if not exists idx_device_tokens_elder on device_tokens using gin (elder_ids);

-- ========== 即時推播 ==========
alter table elders replica identity full;
alter table radio_events replica identity full;
alter table dispatch_tasks replica identity full;
alter table task_messages replica identity full;
alter table call_signals replica identity full;
alter table volunteers replica identity full;

do $$
begin
  begin alter publication supabase_realtime add table elders; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table radio_events; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table dispatch_tasks; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table task_messages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table call_signals; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table volunteers; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table app_settings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table life_events; exception when duplicate_object then null; end;
end $$;

-- ========== RLS ==========
-- Demo 階段：讀取全開放、寫入開放給登入者；radio_events 額外允許 anon insert（硬體用）。
-- ⚠️ 正式版需按角色收緊（家屬只看綁定的長輩、志工只看接到的單…），此處為 demo 求快。
alter table elders enable row level security;
alter table radio_events enable row level security;
alter table dispatch_tasks enable row level security;
alter table task_messages enable row level security;
alter table social_workers enable row level security;
alter table time_bank_ledger enable row level security;
alter table profiles enable row level security;
alter table family_bindings enable row level security;
alter table call_signals enable row level security;
alter table volunteers enable row level security;
alter table volunteer_certificates enable row level security;
alter table app_settings enable row level security;
alter table life_events enable row level security;

do $$
declare t text;
begin
  foreach t in array array['elders','radio_events','dispatch_tasks','task_messages',
                           'social_workers','time_bank_ledger','profiles','family_bindings',
                           'call_signals','volunteers','volunteer_certificates','app_settings','life_events']
  loop
    execute format('drop policy if exists "demo_read" on %I', t);
    execute format('drop policy if exists "demo_write" on %I', t);
    execute format('create policy "demo_read" on %I for select using (true)', t);
    execute format('create policy "demo_write" on %I for all to authenticated using (true) with check (true)', t);
  end loop;
  -- 硬體以 anon key 上報事件
  drop policy if exists "device_insert" on radio_events;
  create policy "device_insert" on radio_events for insert to anon with check (true);
end $$;

-- device_tokens：使用者只能讀寫自己的 token（不套用 demo 全開）。
-- send-push Edge Function 用 service_role key，繞過 RLS 讀全部 token。
alter table device_tokens enable row level security;
do $$
begin
  drop policy if exists "own_tokens" on device_tokens;
  create policy "own_tokens" on device_tokens for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());
end $$;

-- ========== 種子資料（對應目前三端 mock，接上就有資料、紀錄不空）==========
insert into elders (id, device_serial, name, age, address, lat, lng, preferred_lang) values
  ('elder-1','JS-0001','林阿春',82,'110臺北市信義區安康里松仁路123號',25.0358,121.5665,'taigi'),
  ('elder-2','JS-0002','王金火',78,'台北市大同區重慶北路二段50號',25.0630,121.5130,'mandarin'),
  ('elder-3','JS-0003','陳玉蘭',86,'台北市中山區民生東路二段100號',25.0578,121.5300,'taigi'),
  ('elder-4','JS-0004','李水發',80,'台北市大安區信義路四段20號',25.0330,121.5450,'taigi'),
  ('elder-5','JS-0005','張秀英',75,'台北市松山區八德路四段60號',25.0500,121.5580,'mandarin'),
  ('elder-6','JS-0006','黃進財',88,'台北市信義區松山路200號',25.0380,121.5680,'taigi'),
  ('elder-7','JS-0007','吳罔市',90,'台北市萬華區西園路一段80號',25.0360,121.5010,'taigi'),
  ('elder-8','JS-0008','劉金龍',84,'台北市中正區羅斯福路二段10號',25.0260,121.5190,'mandarin'),
  ('elder-9','JS-0009','蔡阿好',79,'台北市大安區復興南路一段150號',25.0420,121.5440,'taigi'),
  ('elder-10','JS-0010','鄭天送',83,'台北市中山區林森北路300號',25.0560,121.5230,'mandarin'),
  ('elder-11','JS-0011','許免',87,'台北市大同區延平北路三段20號',25.0700,121.5100,'taigi'),
  ('elder-12','JS-0012','周罔腰',91,'台北市松山區南京東路五段100號',25.0520,121.5620,'taigi'),
  ('elder-13','JS-0013','楊金水',76,'台北市信義區忠孝東路五段400號',25.0410,121.5710,'mandarin'),
  ('elder-14','JS-0014','郭春枝',82,'台北市大安區和平東路二段50號',25.0260,121.5380,'taigi'),
  ('elder-15','JS-0015','何進',85,'台北市中正區南昌路一段20號',25.0290,121.5150,'mandarin'),
  ('elder-16','JS-0016','曾罔市',88,'台北市萬華區康定路100號',25.0380,121.4990,'taigi'),
  ('elder-17','JS-0017','賴阿盆',80,'台北市中山區松江路200號',25.0570,121.5340,'taigi'),
  ('elder-18','JS-0018','廖金生',77,'台北市松山區敦化北路150號',25.0530,121.5490,'mandarin'),
  ('elder-19','JS-0019','江秀琴',84,'台北市大安區敦化南路一段200號',25.0410,121.5490,'taigi'),
  ('elder-20','JS-0020','邱火旺',89,'台北市信義區基隆路一段180號',25.0440,121.5650,'taigi'),
  ('elder-21','JS-0021','石阿桃',81,'台北市中正區和平西路一段10號',25.0250,121.5110,'taigi'),
  ('elder-22','JS-0022','高天賜',78,'台北市大同區民權西路50號',25.0630,121.5180,'mandarin')
on conflict (id) do update set name=excluded.name, address=excluded.address,
  lat=excluded.lat, lng=excluded.lng, device_serial=excluded.device_serial,
  preferred_lang=excluded.preferred_lang;

-- 簡單狀況注記（代表性幾筆；其餘留空由社工補填）
update elders set note='獨居，膝關節退化行動較慢，需注意跌倒'   where id='elder-1';
update elders set note='高血壓，與女兒同住但白天獨自在家'       where id='elder-2';
update elders set note='獨居，輕度失智，作息日夜顛倒需留意'     where id='elder-3';
update elders set note='曾中風，右側行動不便，備有助行器'       where id='elder-4';
update elders set note='獨居，聽力退化，需大聲或重複提醒'       where id='elder-5';
update elders set note='糖尿病，需定時服藥與量血糖'           where id='elder-6';

-- 長輩／家中聯絡電話（家屬 App 緊急撥打用；demo 代表性幾筆）
update elders set phone='02-2758-1234' where id='elder-1';
update elders set phone='02-2557-2233' where id='elder-2';
update elders set phone='02-2503-9988' where id='elder-3';
update elders set phone='02-2708-4561' where id='elder-4';
update elders set phone='02-2760-1122' where id='elder-5';
update elders set phone='02-2345-6789' where id='elder-6';

insert into social_workers (id,name,phone,shift_start_hour,shift_end_hour) values
  ('worker-1','王淑芬','0921-111-222',8,16),
  ('worker-2','李建成','0933-333-444',16,24),
  ('worker-3','張美惠','0955-555-666',0,8)
on conflict (id) do nothing;

-- 志工＋可服務時段（weekday 1=一…7=日）。座標散布台北各區，供緊急單「就近＋負載」派單。
insert into volunteers (id,name,phone,lat,lng,online,points,intro,service_hours) values
  ('vol-1','阿明','0921-000-111',25.0345,121.5672,true,12,'信義在地・機車代購快手',
    '[{"weekdays":[1,2,3,4,5,6,7],"start":0,"end":24}]'::jsonb),
  ('vol-2','秀蘭','0921-222-333',25.0270,121.5440,true,8,'大安・退休護理師',
    '[{"weekdays":[1,2,3,4,5],"start":9,"end":17}]'::jsonb),
  ('vol-3','俊傑','0921-444-555',25.0500,121.5580,false,20,'松山・週末志工',
    '[{"weekdays":[6,7],"start":8,"end":20}]'::jsonb),
  ('vol-4','家豪','0921-666-777',25.0410,121.5710,true,5,'信義・下班順路幫手',
    '[{"weekdays":[1,2,3,4,5,6,7],"start":0,"end":24}]'::jsonb),
  ('vol-5','淑惠','0921-888-999',25.0570,121.5330,true,15,'中山・全職照服員',
    '[{"weekdays":[1,2,3,4,5],"start":8,"end":18}]'::jsonb),
  ('vol-6','志偉','0922-111-000',25.0630,121.5150,true,3,'大同・熱血青年',
    '[{"weekdays":[1,2,3,4,5,6,7],"start":0,"end":24}]'::jsonb)
on conflict (id) do update set name=excluded.name, phone=excluded.phone,
  lat=excluded.lat, lng=excluded.lng, online=excluded.online,
  intro=excluded.intro, service_hours=excluded.service_hours;

-- 志工證件紀錄與狀態
insert into volunteer_certificates (volunteer_id,kind,status,issued_at,expires_at,note) values
  ('vol-1','good_citizen','valid','2025-06-01','2027-06-01',null),
  ('vol-1','insurance','valid','2026-01-01','2026-12-31',null),
  ('vol-1','basic_training','valid','2025-03-10',null,'已完成 8 小時基礎照護課程'),
  ('vol-2','good_citizen','valid','2024-11-01','2026-11-01',null),
  ('vol-2','insurance','pending',null,null,null),
  ('vol-2','basic_training','valid','2024-05-20',null,'護理背景，已認列基礎照護'),
  ('vol-3','good_citizen','none',null,null,null),
  ('vol-3','insurance','none',null,null,null),
  ('vol-3','basic_training','pending',null,null,null),
  ('vol-4','good_citizen','valid','2025-09-01','2027-09-01',null),
  ('vol-4','insurance','valid','2026-01-01','2026-12-31',null),
  ('vol-4','basic_training','pending',null,null,null),
  ('vol-5','good_citizen','valid','2025-02-15','2027-02-15',null),
  ('vol-5','insurance','valid','2026-01-01','2026-12-31',null),
  ('vol-5','basic_training','valid','2024-08-01',null,'照服員資格，已認列基礎照護'),
  ('vol-6','good_citizen','valid','2026-03-01','2028-03-01',null),
  ('vol-6','insurance','pending',null,null,null),
  ('vol-6','basic_training','none',null,null,null)
on conflict (volunteer_id,kind) do update set status=excluded.status,
  issued_at=excluded.issued_at, expires_at=excluded.expires_at, note=excluded.note;

-- 長輩督導人員（督導社工＋督導志工，長期指定）
update elders set supervisor_worker_name='王淑芬', supervisor_volunteer_name='阿明' where id='elder-1';
update elders set supervisor_worker_name='李建成', supervisor_volunteer_name='秀蘭' where id='elder-2';
update elders set supervisor_worker_name='張美惠', supervisor_volunteer_name='俊傑' where id='elder-3';
update elders set supervisor_worker_name='王淑芬', supervisor_volunteer_name='阿明' where id='elder-4';
update elders set supervisor_worker_name='李建成', supervisor_volunteer_name='秀蘭' where id='elder-5';
update elders set supervisor_worker_name='張美惠', supervisor_volunteer_name='俊傑' where id='elder-6';
-- 其餘長輩：依序號輪派督導社工／志工，確保「沒有長輩漏分社工」
update elders set
  supervisor_worker_name = (array['王淑芬','李建成','張美惠'])[((coalesce(substring(id from '[0-9]+'),'0'))::int % 3) + 1]
where supervisor_worker_name is null;
update elders set
  supervisor_volunteer_name = (array['阿明','秀蘭','俊傑'])[((coalesce(substring(id from '[0-9]+'),'0'))::int % 3) + 1]
where supervisor_volunteer_name is null;
