-- ══════════════════════════════════════════════════════════════════════════════
-- PageForge by SkillBinder — User Profiles & Monthly Limits Migration
-- Run in Supabase Dashboard → SQL Editor
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Update user_tiers with profile fields ────────────────────────────────
ALTER TABLE public.user_tiers
ADD COLUMN IF NOT EXISTS first_name text,
ADD COLUMN IF NOT EXISTS last_name text,
ADD COLUMN IF NOT EXISTS phone text;

-- ── 2. Recreate build_limits view for monthly rolling counts ────────────────
CREATE OR REPLACE VIEW public.build_limits AS
SELECT
  ut.user_id,
  ut.tier,
  count(b.id)::int                            AS build_count,
  CASE ut.tier
    WHEN 'free'      THEN 3
    WHEN 'starter'   THEN 25
    WHEN 'author'    THEN -1   -- unlimited
    WHEN 'publisher' THEN -1   -- unlimited
    ELSE 3
  END                                          AS max_builds,
  CASE ut.tier
    WHEN 'free'      THEN (count(b.id) >= 3)
    WHEN 'starter'   THEN (count(b.id) >= 25)
    ELSE false
  END                                          AS at_limit
FROM public.user_tiers ut
LEFT JOIN public.builds b ON b.user_id = ut.user_id AND b.created_at >= date_trunc('month', now())
GROUP BY ut.user_id, ut.tier;
