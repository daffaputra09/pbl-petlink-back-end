/**
 * Seed public.pet_types (lookup for customer_pets.pet_type_id).
 * Uses service role — not run from SQL migrations.
 *
 *   cd pbl-petlink-back-end
 *   npm run seed:pet-types
 *
 * Requires in .env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 */
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

/** Default species labels shown in the app dropdown. */
const DEFAULT_TYPES = [
  'Anjing',
  'Kucing',
  'Kelinci',
  'Burung',
  'Hamster',
  'Ikan',
  'Reptil',
  'Kura-kura',
  'Landak',
  'Lainnya',
];

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

if (!url) fail('Missing SUPABASE_URL.');
if (!serviceKey) {
  fail(
    [
      'Missing SUPABASE_SERVICE_ROLE_KEY.',
      'Supabase Dashboard → Project Settings → API → service_role',
    ].join('\n'),
  );
}

const admin = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const { data: existing, error: fetchError } = await admin
  .from('pet_types')
  .select('id, name')
  .is('deleted_at', null)
  .order('name');

if (fetchError) fail(`Fetch pet_types failed: ${fetchError.message}`);

const existingNames = new Set((existing ?? []).map((r) => r.name));
const toInsert = DEFAULT_TYPES.filter((name) => !existingNames.has(name));

if (toInsert.length > 0) {
  const { error: insertError } = await admin
    .from('pet_types')
    .insert(toInsert.map((name) => ({ name })));

  if (insertError) fail(`Insert pet_types failed: ${insertError.message}`);
  console.log(`Inserted ${toInsert.length}: ${toInsert.join(', ')}`);
} else {
  console.log('No new rows (all default types already present).');
}

const { data: all, error: listError } = await admin
  .from('pet_types')
  .select('id, name')
  .is('deleted_at', null)
  .order('name');

if (listError) fail(`List pet_types failed: ${listError.message}`);

console.log(`\nActive pet_types (${all?.length ?? 0}):`);
for (const row of all ?? []) {
  console.log(`  - ${row.name} (${row.id})`);
}
