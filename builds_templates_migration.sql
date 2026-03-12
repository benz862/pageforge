-- ══════════════════════════════════════════════════════════════════════════════
-- PageForge by SkillBinder — Builds & Templates Database Migration
-- Run AFTER supabase_setup.sql in Supabase Dashboard → SQL Editor
-- ══════════════════════════════════════════════════════════════════════════════


-- ── 1. BUILDS TABLE ───────────────────────────────────────────────────────────
-- Stores every saved PDF project a user creates
create table if not exists public.builds (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,

  -- Identity
  title         text not null default 'Untitled Build',
  description   text,

  -- Book metadata (mirrors the sidebar fields)
  book_title    text,
  book_author   text,
  book_subject  text,
  book_publisher text,

  -- Content (the raw markup text)
  content       text,

  -- Page settings (stored as JSON for flexibility)
  page_settings jsonb default '{}'::jsonb,
  -- Example structure:
  -- {
  --   "pageSize": "letter",
  --   "orientation": "portrait",
  --   "margins": { "top": 25, "bottom": 25, "left": 28, "right": 28, "unit": "mm" },
  --   "paraSpacing": 3,
  --   "paraIndent": 7
  -- }

  -- Typography settings
  typography    jsonb default '{}'::jsonb,
  -- Example structure:
  -- {
  --   "body":    { "font": "times",    "size": 11, "lineHeight": 1.5, "color": "#1a1a1a" },
  --   "chapter": { "font": "same",     "size": 22, "color": "#1a1a1a" },
  --   "h2":      { "font": "same",     "size": 16, "color": "#1a1a1a" },
  --   "h3":      { "font": "same",     "size": 13, "color": "#1a1a1a" }
  -- }

  -- Layout options
  layout        jsonb default '{}'::jsonb,
  -- Example structure:
  -- {
  --   "showPageNums": true,
  --   "showToc": true,
  --   "coverPage": true,
  --   "chapterBreak": true
  -- }

  -- Cover images stored as base64 (null if none)
  -- Note: for large files consider Supabase Storage instead
  cover_front   text,
  cover_back    text,

  -- Tier at time of save (for future feature gating)
  saved_with_tier text default 'free',

  -- Stats
  page_count    integer,
  word_count    integer,

  -- Timestamps
  created_at    timestamptz default now(),
  updated_at    timestamptz default now(),
  last_exported timestamptz
);

-- Index for fast user lookups
create index builds_user_id_idx on public.builds(user_id);
create index builds_updated_at_idx on public.builds(updated_at desc);


-- ── 2. TEMPLATES TABLE ────────────────────────────────────────────────────────
-- Saves typography + page settings as reusable named presets (no content)
create table if not exists public.templates (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users(id) on delete cascade,
  -- user_id NULL = system template (shared for all users)

  name          text not null,
  description   text,
  category      text default 'custom',
  -- categories: 'custom' | 'fiction' | 'nonfiction' | 'textbook' | 'report' | 'system'

  is_system     boolean default false,  -- true = built-in preset, shown to all users
  is_public     boolean default false,  -- true = user shared template (future feature)

  -- Same structure as builds (but no content — templates are style-only)
  page_settings jsonb default '{}'::jsonb,
  typography    jsonb default '{}'::jsonb,
  layout        jsonb default '{}'::jsonb,

  -- Preview thumbnail (small base64 or description)
  preview_text  text,  -- short excerpt to show in template picker

  -- Usage tracking
  use_count     integer default 0,

  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

create index templates_user_id_idx  on public.templates(user_id);
create index templates_system_idx   on public.templates(is_system) where is_system = true;


-- ── 3. ROW LEVEL SECURITY — BUILDS ───────────────────────────────────────────
alter table public.builds enable row level security;

create policy "builds_select_own"
  on public.builds for select
  using (auth.uid() = user_id);

create policy "builds_insert_own"
  on public.builds for insert
  with check (auth.uid() = user_id);

create policy "builds_update_own"
  on public.builds for update
  using (auth.uid() = user_id);

create policy "builds_delete_own"
  on public.builds for delete
  using (auth.uid() = user_id);

-- Admin can read all builds
create policy "builds_admin_all"
  on public.builds for all
  using (
    exists (
      select 1 from public.user_tiers
      where user_id = auth.uid() and is_admin = true
    )
  );


-- ── 4. ROW LEVEL SECURITY — TEMPLATES ────────────────────────────────────────
alter table public.templates enable row level security;

-- Users see their own templates + all system templates
create policy "templates_select"
  on public.templates for select
  using (
    auth.uid() = user_id
    or is_system = true
    or is_public = true
  );

create policy "templates_insert_own"
  on public.templates for insert
  with check (auth.uid() = user_id and is_system = false);

create policy "templates_update_own"
  on public.templates for update
  using (auth.uid() = user_id and is_system = false);

create policy "templates_delete_own"
  on public.templates for delete
  using (auth.uid() = user_id and is_system = false);

-- Admins manage system templates
create policy "templates_admin_all"
  on public.templates for all
  using (
    exists (
      select 1 from public.user_tiers
      where user_id = auth.uid() and is_admin = true
    )
  );


-- ── 5. UPDATED_AT TRIGGERS ────────────────────────────────────────────────────
-- (reuses handle_updated_at() from supabase_setup.sql)

create trigger on_builds_updated
  before update on public.builds
  for each row execute procedure public.handle_updated_at();

create trigger on_templates_updated
  before update on public.templates
  for each row execute procedure public.handle_updated_at();


-- ── 6. TIER BUILD LIMITS VIEW ────────────────────────────────────────────────
-- Enforce per-tier saved build limits (Free: 3, Starter: 25, Author/Publisher: unlimited)
create or replace view public.build_limits as
select
  ut.user_id,
  ut.tier,
  count(b.id)::int                            as build_count,
  case ut.tier
    when 'free'      then 3
    when 'starter'   then 25
    when 'author'    then -1   -- unlimited
    when 'publisher' then -1   -- unlimited
    else 3
  end                                          as max_builds,
  case ut.tier
    when 'free'      then (count(b.id) >= 3)
    when 'starter'   then (count(b.id) >= 25)
    else false
  end                                          as at_limit
from public.user_tiers ut
left join public.builds b on b.user_id = ut.user_id
group by ut.user_id, ut.tier;


-- ── 7. SYSTEM TEMPLATES (built-in presets) ───────────────────────────────────
insert into public.templates
  (user_id, name, description, category, is_system, page_settings, typography, layout, preview_text)
values

-- Classic Novel
(null, 'Classic Novel', 'Traditional 6×9 trade paperback with Garamond serif typography', 'fiction', true,
  '{"pageSize":"sixbynine","orientation":"portrait","margins":{"top":22,"bottom":22,"left":25,"right":22,"unit":"mm"},"paraSpacing":2,"paraIndent":10}',
  '{"body":{"font":"garamond","size":11,"lineHeight":1.6,"color":"#1a1a1a"},"chapter":{"font":"garamond","size":20,"color":"#1a1a1a"},"h2":{"font":"garamond","size":14,"color":"#1a1a1a"},"h3":{"font":"garamond","size":12,"color":"#1a1a1a"}}',
  '{"showPageNums":true,"showToc":false,"coverPage":true,"chapterBreak":true}',
  'A timeless layout for literary fiction, memoirs, and narrative nonfiction.'),

-- Modern Textbook
(null, 'Modern Textbook', 'Clean A4 layout with Inter sans-serif, ideal for educational content', 'textbook', true,
  '{"pageSize":"a4","orientation":"portrait","margins":{"top":25,"bottom":25,"left":30,"right":25,"unit":"mm"},"paraSpacing":4,"paraIndent":0}',
  '{"body":{"font":"inter","size":10.5,"lineHeight":1.55,"color":"#1a2a3a"},"chapter":{"font":"inter","size":22,"color":"#1d3a52"},"h2":{"font":"inter","size":15,"color":"#1d3a52"},"h3":{"font":"inter","size":12,"color":"#254a68"}}',
  '{"showPageNums":true,"showToc":true,"coverPage":true,"chapterBreak":true}',
  'Professional academic and educational layout with clean sans-serif typography.'),

-- Business Report
(null, 'Business Report', 'Letter size professional report with Merriweather headings', 'report', true,
  '{"pageSize":"letter","orientation":"portrait","margins":{"top":28,"bottom":28,"left":32,"right":28,"unit":"mm"},"paraSpacing":3,"paraIndent":0}',
  '{"body":{"font":"sourcesans","size":11,"lineHeight":1.5,"color":"#2a2a2a"},"chapter":{"font":"merriweather","size":18,"color":"#1a2a3a"},"h2":{"font":"merriweather","size":14,"color":"#1a2a3a"},"h3":{"font":"merriweather","size":11,"color":"#2a4060"}}',
  '{"showPageNums":true,"showToc":true,"coverPage":true,"chapterBreak":false}',
  'Corporate-ready layout for business plans, white papers, and annual reports.'),

-- Poetry Collection
(null, 'Poetry Collection', 'Elegant A5 format with Playfair Display, generous spacing', 'fiction', true,
  '{"pageSize":"a5","orientation":"portrait","margins":{"top":30,"bottom":30,"left":32,"right":32,"unit":"mm"},"paraSpacing":8,"paraIndent":0}',
  '{"body":{"font":"playfair","size":11,"lineHeight":1.8,"color":"#2a1a0a"},"chapter":{"font":"playfair","size":18,"color":"#5a3010"},"h2":{"font":"playfair","size":13,"color":"#5a3010"},"h3":{"font":"playfair","size":11,"color":"#7a5030"}}',
  '{"showPageNums":true,"showToc":true,"coverPage":true,"chapterBreak":true}',
  'Refined layout for poetry, short stories, and literary collections.'),

-- Technical Manual
(null, 'Technical Manual', 'A4 layout with Courier code-friendly body text and clear headings', 'nonfiction', true,
  '{"pageSize":"a4","orientation":"portrait","margins":{"top":20,"bottom":20,"left":25,"right":20,"unit":"mm"},"paraSpacing":3,"paraIndent":5}',
  '{"body":{"font":"baskerville","size":10,"lineHeight":1.45,"color":"#1a1a1a"},"chapter":{"font":"inter","size":20,"color":"#0f2535"},"h2":{"font":"inter","size":13,"color":"#0f2535"},"h3":{"font":"inter","size":11,"color":"#254a68"}}',
  '{"showPageNums":true,"showToc":true,"coverPage":false,"chapterBreak":false}',
  'Dense, efficient layout for technical documentation, how-to guides, and manuals.')

on conflict do nothing;


-- ── 8. VERIFY ────────────────────────────────────────────────────────────────
-- select 'builds' as tbl, count(*) from public.builds
-- union all
-- select 'templates', count(*) from public.templates
-- union all
-- select 'system_templates', count(*) from public.templates where is_system=true;
