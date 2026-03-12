-- 1. Create a lightweight table specifically for tracking PDF generations
CREATE TABLE IF NOT EXISTS public.usage_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    action text NOT NULL DEFAULT 'export_pdf',
    created_at timestamptz DEFAULT now()
);

-- RLS policies for usage_logs
ALTER TABLE public.usage_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own usage logs"
  ON public.usage_logs FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own usage logs"
  ON public.usage_logs FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 2. Refactor the `build_limits` view to count `usage_logs` from the CURRENT MONTH
DROP VIEW IF EXISTS public.build_limits CASCADE;
CREATE OR REPLACE VIEW public.build_limits AS
SELECT
  ut.user_id,
  ut.tier,
  COALESCE(u.current_month_count, 0)::int AS build_count,
  CASE ut.tier
    WHEN 'free'      THEN 3
    WHEN 'starter'   THEN 25
    WHEN 'author'    THEN -1   -- unlimited
    WHEN 'publisher' THEN -1   -- unlimited
    ELSE 3
  END AS max_builds,
  CASE ut.tier
    WHEN 'free'      THEN (COALESCE(u.current_month_count, 0) >= 3)
    WHEN 'starter'   THEN (COALESCE(u.current_month_count, 0) >= 25)
    ELSE false
  END AS at_limit
FROM public.user_tiers ut
LEFT JOIN (
  SELECT user_id, count(id) as current_month_count
  FROM public.usage_logs
  -- Only count exports created in the current calendar month
  WHERE date_trunc('month', created_at) = date_trunc('month', now())
  GROUP BY user_id
) u ON u.user_id = ut.user_id;
