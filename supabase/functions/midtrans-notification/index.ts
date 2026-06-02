import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  try {
    const serverKey = Deno.env.get('MIDTRANS_SERVER_KEY');
    if (!serverKey) {
      return new Response('Not configured', { status: 500 });
    }

    const body = await req.json();
    const orderId = body.order_id as string;
    const statusCode = body.status_code as string;
    const grossAmount = body.gross_amount as string;
    const signatureKey = body.signature_key as string;
    const transactionStatus = body.transaction_status as string;

    const expectedSig = await sha512Hex(
      orderId + statusCode + grossAmount + serverKey,
    );
    if (signatureKey !== expectedSig) {
      console.error('Invalid signature');
      return new Response('Invalid signature', { status: 403 });
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: payment, error } = await admin
      .from('payments')
      .select('id, status, amount')
      .eq('midtrans_order_id', orderId)
      .maybeSingle();

    if (error || !payment) {
      console.error('Payment not found', orderId);
      return new Response('OK', { status: 200 });
    }

    let newStatus = payment.status;
    if (
      transactionStatus === 'capture' ||
      transactionStatus === 'settlement'
    ) {
      newStatus = 'paid';
    } else if (
      transactionStatus === 'deny' ||
      transactionStatus === 'cancel' ||
      transactionStatus === 'expire'
    ) {
      newStatus = transactionStatus === 'expire' ? 'expired' : 'failed';
    } else if (transactionStatus === 'pending') {
      newStatus = 'pending';
    }

    const updatePayload: Record<string, unknown> = {
      status: newStatus,
      midtrans_transaction_id: body.transaction_id,
      midtrans_payment_type: body.payment_type,
      midtrans_raw_response: body,
    };

    if (newStatus === 'paid') {
      updatePayload.paid_at = new Date().toISOString();
    }

    await admin.from('payments').update(updatePayload).eq('id', payment.id);

    if (newStatus === 'paid') {
      await admin.rpc('confirm_booking_after_payment', {
        p_payment_id: payment.id,
      });
    } else if (newStatus === 'failed' || newStatus === 'expired') {
      await admin.rpc('cancel_booking_after_payment_failed', {
        p_payment_id: payment.id,
      });
    }

    return new Response('OK', { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response('Error', { status: 500 });
  }
});

async function sha512Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const hash = await crypto.subtle.digest('SHA-512', data);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
