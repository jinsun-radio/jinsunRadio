-- 裝置推播 token（FCM）。App 登入後上報；send-push 依此查收件者。
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
alter table device_tokens enable row level security;
do $$
begin
  drop policy if exists "own_tokens" on device_tokens;
  create policy "own_tokens" on device_tokens for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());
end $$;
