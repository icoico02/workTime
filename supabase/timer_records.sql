create table if not exists public.timer_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  start_time timestamptz not null,
  end_time timestamptz not null,
  total_milliseconds bigint not null,
  total_seconds integer not null,
  created_at timestamptz not null default now()
);

alter table public.timer_records
  add column if not exists total_milliseconds bigint;

update public.timer_records
set total_milliseconds = total_seconds::bigint * 1000
where total_milliseconds is null;

alter table public.timer_records
  alter column total_milliseconds set not null;

alter table public.timer_records enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'timer_records'
      and policyname = 'Users can view own timer records'
  ) then
    create policy "Users can view own timer records"
    on public.timer_records
    for select
    to authenticated
    using (auth.uid() = user_id);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'timer_records'
      and policyname = 'Users can insert own timer records'
  ) then
    create policy "Users can insert own timer records"
    on public.timer_records
    for insert
    to authenticated
    with check (auth.uid() = user_id);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'timer_records'
      and policyname = 'Users can update own timer records'
  ) then
    create policy "Users can update own timer records"
    on public.timer_records
    for update
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'timer_records'
      and policyname = 'Users can delete own timer records'
  ) then
    create policy "Users can delete own timer records"
    on public.timer_records
    for delete
    to authenticated
    using (auth.uid() = user_id);
  end if;
end
$$;
