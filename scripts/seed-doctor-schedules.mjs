/**
 * Hapus baris seed "ketersediaan" lama (salah model: tanpa acara = free).
 *
 *   cd pbl-petlink-back-end
 *   npm run seed:doctor-schedules
 *
 * doctor_schedules hanya untuk acara nyata (libur, konsultasi, booking, dll.).
 * Jangan seed blok standby — itu membuat dokter terlihat sibuk seharian.
 */
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

if (!url) fail('Missing SUPABASE_URL.');
if (!serviceKey) fail('Missing SUPABASE_SERVICE_ROLE_KEY.');

const admin = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const LEGACY_NOTES = ['Seed availability', 'Standby klinik'];

async function main() {
  const { data, error } = await admin
    .from('doctor_schedules')
    .select('id, notes')
    .is('booking_id', null)
    .is('consultation_id', null)
    .in('notes', LEGACY_NOTES);

  if (error) fail(error.message);

  if (!data?.length) {
    console.log('No legacy availability rows to remove.');
    return;
  }

  const ids = data.map((r) => r.id);
  const { error: delErr } = await admin.from('doctor_schedules').delete().in('id', ids);

  if (delErr) fail(delErr.message);

  console.log(`Removed ${ids.length} legacy seed row(s).`);
  console.log('Add real events via clinic/doctor tools when doctors are busy.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
