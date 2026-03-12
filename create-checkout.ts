// ══════════════════════════════════════════════════════════════════════════════
// PageForge by SkillBinder — Create Checkout Session Edge Function
// Deploy as: "create-checkout"
// ══════════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@12.18.0?target=deno";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const stripeSecret = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseService = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const stripe = new Stripe(stripeSecret, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // ── Authenticate user from Bearer token ──────────────────────────────────
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "No auth token" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    }

    const sb = createClient(supabaseUrl, supabaseService);
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await sb.auth.getUser(token);

    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    }

    // ── Parse request body ────────────────────────────────────────────────────
    const { priceId, successUrl, cancelUrl } = await req.json();
    if (!priceId) {
      return new Response(JSON.stringify({ error: "Missing priceId" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    }

    // ── Get or create Stripe customer ─────────────────────────────────────────
    const { data: tierData } = await sb
      .from("user_tiers")
      .select("stripe_customer_id")
      .eq("user_id", user.id)
      .single();

    let customerId = tierData?.stripe_customer_id;

    if (!customerId) {
      const customer = await stripe.customers.create({
        email: user.email,
        metadata: { supabase_user_id: user.id },
      });
      customerId = customer.id;

      await sb.from("user_tiers")
        .update({ stripe_customer_id: customerId })
        .eq("user_id", user.id);
    }

    // ── Determine if price has trial (Author plans) ───────────────────────────
    const TRIAL_PRICES = [
      "price_1T8uD5E6oTidvpnUY4WoPdMo",
      "price_1T8uD5E6oTidvpnUDmxDmym3",
    ];
    const hasTrial = TRIAL_PRICES.includes(priceId);

    // ── Create Checkout Session ───────────────────────────────────────────────
    const sessionParams: Stripe.Checkout.SessionCreateParams = {
      customer: customerId,
      mode: "subscription",
      line_items: [{ price: priceId, quantity: 1 }],
      success_url: successUrl + "?checkout=success",
      cancel_url: cancelUrl + "?checkout=canceled",
      metadata: { supabase_user_id: user.id },
      subscription_data: {
        metadata: { supabase_user_id: user.id },
      },
      phone_number_collection: {
        enabled: true,
      },
      custom_fields: [
        {
          key: 'first_name',
          label: { type: 'custom', custom: 'First Name' },
          type: 'text',
          optional: false,
        },
        {
          key: 'last_name',
          label: { type: 'custom', custom: 'Last Name' },
          type: 'text',
          optional: false,
        }
      ],
    };

    if (hasTrial) {
      sessionParams.subscription_data!.trial_period_days = 7;
    }

    const session = await stripe.checkout.sessions.create(sessionParams);

    return new Response(JSON.stringify({ url: session.url }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("create-checkout error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
