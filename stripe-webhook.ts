// ══════════════════════════════════════════════════════════════════════════════
// PageForge by SkillBinder — Stripe Webhook Edge Function
// Deploy to: Supabase Dashboard → Edge Functions → New Function → "stripe-webhook"
// ══════════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@12.18.0?target=deno";

// ── Price ID → Tier mapping ───────────────────────────────────────────────────
const PRICE_TO_TIER: Record<string, string> = {
  "price_1T8uD0E6oTidvpnUCvqU37ac": "starter",   // Starter Monthly
  "price_1T8uD0E6oTidvpnUJ4tuIEsc": "starter",   // Starter Yearly
  "price_1T8uD5E6oTidvpnUY4WoPdMo": "author",    // Author Monthly (trial)
  "price_1T8uD5E6oTidvpnUDmxDmym3": "author",    // Author Yearly (trial)
  "price_1T8uD1E6oTidvpnUglAFkCcP": "publisher", // Publisher Monthly
  "price_1T8uD2E6oTidvpnUt2hl4ijz": "publisher", // Publisher Yearly
};

serve(async (req: Request) => {
  // ── Only accept POST ────────────────────────────────────────────────────────
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  // ── Verify Stripe webhook signature ────────────────────────────────────────
  const stripeSecret = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseService = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  const stripe = new Stripe(stripeSecret, {
    apiVersion: "2023-10-16",
    httpClient: Stripe.createFetchHttpClient(),
  });

  const body = await req.text();
  const signature = req.headers.get("stripe-signature") ?? "";

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature, webhookSecret);
  } catch (err) {
    console.error("Webhook signature verification failed:", err);
    return new Response(`Webhook Error: ${err}`, { status: 400 });
  }

  // ── Supabase admin client (bypasses RLS) ────────────────────────────────────
  const sb = createClient(supabaseUrl, supabaseService);

  console.log(`Processing Stripe event: ${event.type}`);

  // ── Handle events ───────────────────────────────────────────────────────────
  try {
    switch (event.type) {

      // Customer created — store customer ID against user
      case "customer.created": {
        const customer = event.data.object as Stripe.Customer;
        const email = customer.email;
        if (!email) break;
        await sb.from("user_tiers")
          .update({ stripe_customer_id: customer.id })
          .eq("email", email);
        console.log(`Linked customer ${customer.id} → ${email}`);
        break;
      }

      // Checkout completed — activate subscription
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const customerId = session.customer as string;
        const subId = session.subscription as string;

        if (!customerId || !subId) break;

        // Fetch subscription to get price & period
        const sub = await stripe.subscriptions.retrieve(subId);
        const priceId = sub.items.data[0]?.price?.id ?? "";
        const tier = PRICE_TO_TIER[priceId] ?? "starter";
        const periodEnd = new Date(sub.current_period_end * 1000).toISOString();
        const status = sub.status; // "trialing" | "active"

        // Extract profile custom fields
        const firstName = session.custom_fields?.find(f => f.key === 'first_name')?.text?.value || null;
        const lastName = session.custom_fields?.find(f => f.key === 'last_name')?.text?.value || null;
        const phone = session.customer_details?.phone || null;

        const updatePayload: any = {
          tier,
          stripe_customer_id: customerId,
          stripe_subscription_id: subId,
          subscription_status: status,
          current_period_end: periodEnd,
          updated_at: new Date().toISOString(),
        };

        if (firstName) updatePayload.first_name = firstName;
        if (lastName) updatePayload.last_name = lastName;
        if (phone) updatePayload.phone = phone;

        const { error } = await sb.from("user_tiers")
          .update(updatePayload)
          .eq("stripe_customer_id", customerId);

        if (error) console.error("DB update error:", error);
        else console.log(`Checkout complete → tier=${tier}, status=${status}, customer=${customerId}`);
        break;
      }

      // Subscription updated (upgrade/downgrade/renewal)
      case "customer.subscription.updated": {
        const sub = event.data.object as Stripe.Subscription;
        const customerId = sub.customer as string;
        const priceId = sub.items.data[0]?.price?.id ?? "";
        const tier = PRICE_TO_TIER[priceId] ?? "free";
        const periodEnd = new Date(sub.current_period_end * 1000).toISOString();

        await sb.from("user_tiers")
          .update({
            tier,
            stripe_subscription_id: sub.id,
            subscription_status: sub.status,
            current_period_end: periodEnd,
            updated_at: new Date().toISOString(),
          })
          .eq("stripe_customer_id", customerId);

        console.log(`Subscription updated → tier=${tier}, status=${sub.status}`);
        break;
      }

      // Trial ended — stays active, just no longer trialing
      case "customer.subscription.trial_will_end": {
        const sub = event.data.object as Stripe.Subscription;
        const customerId = sub.customer as string;
        console.log(`Trial ending soon for customer ${customerId}`);
        // Could trigger a reminder email here via Supabase Edge Function
        break;
      }

      // Subscription canceled or expired
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const customerId = sub.customer as string;

        await sb.from("user_tiers")
          .update({
            tier: "free",
            subscription_status: "canceled",
            stripe_subscription_id: null,
            current_period_end: null,
            updated_at: new Date().toISOString(),
          })
          .eq("stripe_customer_id", customerId);

        console.log(`Subscription canceled → downgraded to free for ${customerId}`);
        break;
      }

      // Payment failed — mark as past_due
      case "invoice.payment_failed": {
        const invoice = event.data.object as Stripe.Invoice;
        const customerId = invoice.customer as string;

        await sb.from("user_tiers")
          .update({
            subscription_status: "past_due",
            updated_at: new Date().toISOString(),
          })
          .eq("stripe_customer_id", customerId);

        console.log(`Payment failed → past_due for customer ${customerId}`);
        break;
      }

      // Payment succeeded after past_due — restore active
      case "invoice.payment_succeeded": {
        const invoice = event.data.object as Stripe.Invoice;
        const customerId = invoice.customer as string;

        await sb.from("user_tiers")
          .update({
            subscription_status: "active",
            updated_at: new Date().toISOString(),
          })
          .eq("stripe_customer_id", customerId);

        console.log(`Payment succeeded → restored active for ${customerId}`);
        break;
      }

      default:
        console.log(`Unhandled event type: ${event.type}`);
    }
  } catch (err) {
    console.error("Handler error:", err);
    return new Response(`Handler error: ${err}`, { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
