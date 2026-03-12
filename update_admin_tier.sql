-- Run this in your Supabase SQL Editor to make support@skillbinder.com an admin

UPDATE public.user_tiers
SET tier = 'publisher' -- or 'admin' / 'super_admin' depending on what tier unlocks your privileges locally
WHERE email = 'support@skillbinder.com';

-- You can confirm the change by running:
-- SELECT * FROM public.user_tiers WHERE email = 'support@skillbinder.com';
