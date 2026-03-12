-- ── PageForge by SkillBinder ─────────────────────────────────────────────────
-- Run this in Supabase Dashboard → SQL Editor

-- 1. user_tiers table
create table if not exists public.user_tiers (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  tier        text not null default 'free' check (tier in ('free','starter','author','publisher')),
  stripe_customer_id    text,
  stripe_subscription_id text,
  subscription_status   text,
  current_period_end    timestamptz,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- 2. Enable Row Level Security
alter table public.user_tiers enable row level security;

-- 3. Users can only read their own tier
drop policy if exists "Users can read own tier" on public.user_tiers;
create policy "Users can read own tier"
  on public.user_tiers for select
  using (auth.uid() = user_id);

-- 4. Only service role can write (webhook updates tiers)
drop policy if exists "Service role can manage tiers" on public.user_tiers;
create policy "Service role can manage tiers"
  on public.user_tiers for all
  using (auth.role() = 'service_role');

-- 5. Allow users to insert their own free record on signup
drop policy if exists "Users can insert own free tier" on public.user_tiers;
create policy "Users can insert own free tier"
  on public.user_tiers for insert
  with check (auth.uid() = user_id and tier = 'free');

-- 6. Updated_at trigger
create or replace function public.handle_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists on_user_tiers_updated on public.user_tiers;
create trigger on_user_tiers_updated
  before update on public.user_tiers
  for each row execute procedure public.handle_updated_at();
