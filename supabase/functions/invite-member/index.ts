import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.7.1"

const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
    if (req.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders })
    }

    try {
        const supabaseClient = createClient(
            Deno.env.get('SUPABASE_URL') ?? '',
            Deno.env.get('SUPABASE_ANON_KEY') ?? '',
            { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
        )

        const supabaseAdmin = createClient(
            Deno.env.get('SUPABASE_URL') ?? '',
            Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
        )

        // 1. Authenticate caller
        const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
        if (userError || !user) throw new Error('Not authorized')

        const { email } = await req.json()
        if (!email) throw new Error('Email is required')

        // 2. Look up the publisher's team to ensure they actually own one
        const { data: teamData, error: teamErr } = await supabaseAdmin
            .from('teams')
            .select('id')
            .eq('owner_id', user.id)
            .single()

        if (teamErr || !teamData) throw new Error('You do not own a Publisher team.')

        // 3. Enforce 3-seat limit logic before inviting
        const { data: membersCheck } = await supabaseAdmin
            .from('team_members')
            .select('id')
            .eq('team_id', teamData.id)

        if (membersCheck && membersCheck.length >= 3) {
            throw new Error('Publisher tier is limited to 3 team seats. Purchase an add-on to expand capacity.')
        }

        // 4. Send the Supabase Invite Email
        // This physically dispatches the 'Invite User' template to their inbox
        const { data: inviteData, error: inviteErr } = await supabaseAdmin.auth.admin.inviteUserByEmail(email)

        if (inviteErr) {
            // Ignore "user already exists" errors when trying to invite someone who is already signed up, 
            // because we still want to add them to the team_members table below.
            if (!inviteErr.message.includes('User already registered')) {
                throw inviteErr
            }
        }

        // 5. Add them to the public.team_members access table
        const targetUserId = inviteData?.user?.id || null;
        const { error: insertErr } = await supabaseAdmin
            .from('team_members')
            .insert({
                team_id: teamData.id,
                email: email,
                user_id: targetUserId
            })

        if (insertErr) {
            if (insertErr.code === '23505') throw new Error('User is already in your team.')
            throw insertErr
        }

        return new Response(
            JSON.stringify({ success: true, message: 'Invitation sent.' }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
        )

    } catch (error) {
        return new Response(
            JSON.stringify({ error: error.message }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
        )
    }
})
