-- ══════════════════════════════════════════════════════════════════════════════
-- PageForge by SkillBinder — Publisher Tier Teams Migration
-- Run in Supabase Dashboard → SQL Editor
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Create Teams Table ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.teams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE(owner_id) -- One team per owner for now
);

ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;

-- ── 2. Create Team Members Table ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.team_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE, -- Can be null if invited but not registered yet
  email text NOT NULL, -- To map invitations
  role text DEFAULT 'member',
  created_at timestamptz DEFAULT now(),
  UNIQUE(team_id, email)
);

ALTER TABLE public.team_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team owners can manage members" ON public.team_members;
CREATE POLICY "Team owners can manage members"
  ON public.team_members FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.teams
      WHERE id = public.team_members.team_id AND owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Members can view other members in their team" ON public.team_members;
CREATE POLICY "Members can view other members in their team"
  ON public.team_members FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.team_members tm
      WHERE tm.team_id = public.team_members.team_id AND tm.user_id = auth.uid()
    )
  );

-- ── 3. Policies for Teams table ───────────────────────────────────────────────

DROP POLICY IF EXISTS "Team owners can manage their team" ON public.teams;
CREATE POLICY "Team owners can manage their team"
  ON public.teams FOR ALL
  USING (auth.uid() = owner_id);

DROP POLICY IF EXISTS "Team members can view their team" ON public.teams;
CREATE POLICY "Team members can view their team"
  ON public.teams FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.team_members
      WHERE team_id = public.teams.id AND user_id = auth.uid()
    )
  );

-- ── 4. Helper Function/View for effective tier ──────────────────────────────
-- This securely determines whether the user is a publisher directly, or
-- indirectly via a team owner.
CREATE OR REPLACE FUNCTION public.get_effective_tier(user_uuid uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  direct_tier text;
  team_owner_tier text;
BEGIN
  -- 1. Get their direct tier
  SELECT tier INTO direct_tier FROM public.user_tiers WHERE user_id = user_uuid;
  
  -- If they are already a publisher, return immediately
  IF direct_tier = 'publisher' THEN
    RETURN 'publisher';
  END IF;

  -- 2. Check if they belong to a team where the owner is a publisher
  SELECT ut.tier INTO team_owner_tier
  FROM public.team_members tm
  JOIN public.teams t ON t.id = tm.team_id
  JOIN public.user_tiers ut ON ut.user_id = t.owner_id
  WHERE tm.user_id = user_uuid AND ut.tier = 'publisher'
  LIMIT 1;

  IF team_owner_tier = 'publisher' THEN
    RETURN 'publisher';
  END IF;

  -- 3. Fallback to their direct tier, or 'free' if none exists
  RETURN COALESCE(direct_tier, 'free');
END;
$$;

-- ── 5. Auto-create Team for Publishers ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_publisher_team_creation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- If tier changed to publisher, ensure they have a team
  IF NEW.tier = 'publisher' AND (OLD.tier IS DISTINCT FROM 'publisher') THEN
    INSERT INTO public.teams (owner_id) 
    VALUES (NEW.user_id) 
    ON CONFLICT (owner_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_publisher_upgrade ON public.user_tiers;
CREATE TRIGGER on_publisher_upgrade
  AFTER UPDATE OF tier ON public.user_tiers
  FOR EACH ROW EXECUTE PROCEDURE public.handle_publisher_team_creation();
