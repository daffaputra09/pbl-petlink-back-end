import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return json({ error: 'Unauthorized' }, 401);
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const serverKey = Deno.env.get('MIDTRANS_SERVER_KEY');
    const clientKey = Deno.env.get('MIDTRANS_CLIENT_KEY');
    const isProduction = Deno.env.get('MIDTRANS_IS_PRODUCTION') === 'true';

    if (!serverKey || !clientKey) {
      return json({ error: 'Midtrans not configured' }, 500);
    }

    const { payment_id: paymentId } = await req.json();
    if (!paymentId) {
      return json({ error: 'payment_id required' }, 400);
    }

    const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData.user) {
      return json({ error: 'Unauthorized' }, 401);
    }

    const admin = createClient(supabaseUrl, serviceKey);
    const { data: payment, error: payErr } = await admin
      .from('payments')
      .select(
        'id, customer_id, clinic_id, amount, status, midtrans_order_id, reference_id, reference_type',
      )
      .eq('id', paymentId)
      .single();

    if (payErr || !payment) {
      return json({ error: 'Payment not found' }, 404);
    }

    if (payment.customer_id !== userData.user.id) {
      return json({ error: 'Forbidden' }, 403);
    }

    if (payment.status !== 'pending') {
      return json({ error: 'Payment is not pending' }, 400);
    }

    const orderId =
      payment.midtrans_order_id ?? `PL-${String(payment.id).replace(/-/g, '')}`;

    const snapBase = isProduction
      ? 'https://app.midtrans.com'
      : 'https://app.sandbox.midtrans.com';

    const grossAmount = Math.round(Number(payment.amount));

    const snapBody = {
      transaction_details: {
        order_id: orderId,
        gross_amount: grossAmount,
      },
      customer_details: {
        email: userData.user.email ?? undefined,
      },
    };

    const snapRes = await fetch(`${snapBase}/snap/v1/transactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Basic ' + btoa(serverKey + ':'),
      },
      body: JSON.stringify(snapBody),
    });

    const snapJson = await snapRes.json();
    if (!snapRes.ok) {
      console.error('Midtrans error', snapJson);
      return json(
        { error: snapJson.error_messages?.join(', ') ?? 'Snap failed' },
        502,
      );
    }

    await admin
      .from('payments')
      .update({
        midtrans_order_id: orderId,
        midtrans_raw_response: snapJson,
      })
      .eq('id', paymentId);

    return json({
      snap_token: snapJson.token,
      client_key: clientKey,
      order_id: orderId,
      redirect_url: snapJson.redirect_url,
      is_production: isProduction,
    });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
