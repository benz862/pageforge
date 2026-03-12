# PageForge by SkillBinder — Deployment Guide
## Edge Functions + Database Setup

---

## STEP 1 — Run Database Migrations

In Supabase Dashboard → SQL Editor, run in order:

1. `supabase_setup.sql`       — user_tiers table, RLS, triggers
2. `builds_templates_migration.sql` — builds + templates tables, RLS, 5 system templates

---

## STEP 2 — Set Edge Function Environment Variables

In Supabase Dashboard → Edge Functions → Manage Secrets, add:

| Key                        | Value                                      |
|----------------------------|--------------------------------------------|
| `STRIPE_SECRET_KEY`        | sk_live_... (from Stripe → API Keys)       |
| `STRIPE_WEBHOOK_SECRET`    | whsec_... (from Stripe → Webhooks)         |
| `SUPABASE_URL`             | https://ewqubxcuccukmodbtoah.supabase.co   |
| `SUPABASE_SERVICE_ROLE_KEY`| service_role key (Settings → API)          |

---

## STEP 3 — Deploy Edge Functions

### Option A: Supabase CLI (recommended)

```bash
# Install CLI
npm install -g supabase

# Login
supabase login

# Link project
supabase link --project-ref ewqubxcuccukmodbtoah

# Deploy stripe webhook handler
supabase functions deploy stripe-webhook

# Deploy checkout session creator
supabase functions deploy create-checkout
```

### Option B: Supabase Dashboard (manual)

1. Dashboard → Edge Functions → New Function
2. Name: `stripe-webhook` → paste contents of `stripe-webhook/index.ts`
3. Repeat for `create-checkout` → paste `create-checkout/index.ts`

---

## STEP 4 — Configure Stripe Webhook

1. Stripe Dashboard → Developers → Webhooks → Add Endpoint
2. Endpoint URL: `https://ewqubxcuccukmodbtoah.supabase.co/functions/v1/stripe-webhook`
3. Select events to listen for:
   - `checkout.session.completed`
   - `customer.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `customer.subscription.trial_will_end`
   - `invoice.payment_failed`
   - `invoice.payment_succeeded`
4. Copy the **Signing Secret** (whsec_...) → paste into Supabase secrets as `STRIPE_WEBHOOK_SECRET`

---

## STEP 5 — Create Demo Accounts

In Supabase Dashboard → Authentication → Users → Add User:

| Email                    | Password       | Tier      |
|--------------------------|----------------|-----------|
| support@skillbinder.com    | Canadian5698!  | free + is_admin=true |
| starter@demo.com         | Test123!       | starter   |
| author@demo.com          | Test123!       | author    |
| publisher@demo.com       | Test123!       | publisher |

After creating each user, note their UUID and run in SQL Editor:

```sql
-- Replace UUIDs with real values from Auth → Users
UPDATE public.user_tiers SET tier='free', is_admin=true
  WHERE email='support@skillbinder.com';

UPDATE public.user_tiers SET tier='starter', subscription_status='active'
  WHERE email='starter@demo.com';

UPDATE public.user_tiers SET tier='author', subscription_status='active'
  WHERE email='author@demo.com';

UPDATE public.user_tiers SET tier='publisher', subscription_status='active'
  WHERE email='publisher@demo.com';
```

---

## STEP 6 — Deploy HTML Files

Upload to your web server or Vercel:

| File                         | URL                                    |
|------------------------------|----------------------------------------|
| `login.html`                 | pageforge.skillbinder.com/login        |
| `pageforge-skillbinder.html` | pageforge.skillbinder.com/app          |
| `pageforge-admin.html`       | pageforge.skillbinder.com/admin        |

---

## Database Schema Summary

### `user_tiers`
Tracks subscription tier per user. Updated by Stripe webhook.

### `builds`
Saved PDF projects. Stores full content + all settings as JSON.
- Free: max 3 builds
- Starter: max 25 builds
- Author/Publisher: unlimited

### `templates`
Style presets (no content). Includes 5 built-in system templates:
- Classic Novel
- Modern Textbook
- Business Report
- Poetry Collection
- Technical Manual

Users can save their own custom templates.

---

## Tier Capabilities

| Feature              | Free | Starter | Author | Publisher |
|----------------------|------|---------|--------|-----------|
| Pages per export     | 20   | 100     | ∞      | ∞         |
| Watermark            | ✓    | —       | —      | —         |
| Fonts                | 3    | All 11  | All 11 | All 11    |
| Cover images         | —    | ✓       | ✓      | ✓         |
| Table of Contents    | —    | —       | ✓      | ✓         |
| Custom colours       | —    | —       | ✓      | ✓         |
| Saved builds         | 3    | 25      | ∞      | ∞         |
| Saved templates      | 2    | 10      | ∞      | ∞         |
| 7-day free trial     | —    | —       | ✓      | —         |
