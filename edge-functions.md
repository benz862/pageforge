# PageForge Edge Functions

Deploy both functions via Supabase CLI or Dashboard.
See DEPLOYMENT.md for full instructions.

---

## Function 1: `stripe-webhook`
Handles all Stripe subscription events and updates user tiers in Supabase.

**Events handled:**
- `checkout.session.completed` → activates tier
- `customer.subscription.updated` → handles upgrades/downgrades
- `customer.subscription.deleted` → downgrades to free
- `invoice.payment_failed` → marks as past_due
- `invoice.payment_succeeded` → restores active

---

## Function 2: `create-checkout`
Creates a Stripe Checkout session and returns the redirect URL.
Called by the PageForge frontend when a user clicks "Upgrade".
