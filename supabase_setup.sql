-- ══════════════════════════════════════════════════════════════════════════════
-- PageForge by SkillBinder — Complete Supabase Setup
-- Run this entire script in Supabase Dashboard → SQL Editor
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. DROP & RECREATE user_tiers with email column ──────────────────────────
drop table if exists public.user_tiers cascade;

create table public.user_tiers (
  user_id               uuid primary key references auth.users(id) on delete cascade,
  email                 text,
  tier                  text not null default 'free'
                          check (tier in ('free','starter','author','publisher')),
  stripe_customer_id    text,
  stripe_subscription_id text,
  subscription_status   text,
  current_period_end    timestamptz,
  is_admin              boolean default false,
  created_at            timestamptz default now(),
  updated_at            timestamptz default now()
);

-- ── 2. Row Level Security ────────────────────────────────────────────────────
alter table public.user_tiers enable row level security;

-- Users read own record
create policy "read_own"
  on public.user_tiers for select
  using (auth.uid() = user_id);

-- Users insert own free record on signup
create policy "insert_own_free"
  on public.user_tiers for insert
  with check (auth.uid() = user_id);

-- Admins can read all records
create policy "admin_read_all"
  on public.user_tiers for select
  using (
    exists (
      select 1 from public.user_tiers
      where user_id = auth.uid() and is_admin = true
    )
  );

-- Service role full access (for webhooks)
create policy "service_role_all"
  on public.user_tiers for all
  using (auth.role() = 'service_role');

-- ── 3. Updated_at trigger ────────────────────────────────────────────────────
create or replace function public.handle_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_user_tiers_updated on public.user_tiers;
create trigger on_user_tiers_updated
  before update on public.user_tiers
  for each row execute procedure public.handle_updated_at();

-- ── 4. Auto-create tier record on new user signup ────────────────────────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.user_tiers (user_id, email, tier)
  values (new.id, new.email, 'free')
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ══════════════════════════════════════════════════════════════════════════════
-- DEMO ACCOUNTS SETUP
-- ══════════════════════════════════════════════════════════════════════════════
-- 
-- STEP 1: Create these users manually in Supabase Dashboard:
--   Authentication → Users → Add User (or Invite)
--
--   support@skillbinder.com     / Canadian5698!   → is_admin = true
--   starter@demo.com          / Test123!
--   author@demo.com           / Test123!
--   publisher@demo.com        / Test123!
--
-- STEP 2: After creating each user, run the UPDATE statements below,
--   replacing each <UUID> with the actual user ID shown in Auth → Users.
--
-- ══════════════════════════════════════════════════════════════════════════════

-- Template — fill in UUIDs after creating accounts:
-- (These will also be created automatically by the trigger above)

-- UPDATE public.user_tiers SET tier='free', is_admin=true, email='support@skillbinder.com'
--   WHERE user_id = '<ADMIN_UUID>';

-- UPDATE public.user_tiers SET tier='starter', email='starter@demo.com'
--   WHERE user_id = '<STARTER_UUID>';

-- UPDATE public.user_tiers SET tier='author', subscription_status='active', email='author@demo.com'
--   WHERE user_id = '<AUTHOR_UUID>';

-- UPDATE public.user_tiers SET tier='publisher', subscription_status='active', email='publisher@demo.com'
--   WHERE user_id = '<PUBLISHER_UUID>';


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY: check the table looks right
-- ══════════════════════════════════════════════════════════════════════════════
-- select * from public.user_tiers order by created_at desc;
