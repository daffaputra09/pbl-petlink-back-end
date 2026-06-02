/**
 * Seed public.services — minimal 3 layanan berbeda per klinik.
 * Menggunakan service role (bypass RLS).
 *
 *   cd pbl-petlink-back-end
 *   npm run seed:services
 *
 * Requires in .env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 *
 * Idempotent: melewati klinik yang sudah punya ≥3 layanan aktif dengan nama unik.
 */
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

const MIN_SERVICES_PER_CLINIC = 3;

/** Nama lama → baru (sinkronkan data yang sudah pernah di-seed). */
const SERVICE_RENAMES = [
  {
    from: 'Konsultasi Umum',
    to: 'Pemeriksaan Fisik Rutin',
    patch: {
      description:
        'Pemeriksaan fisik lengkap: suhu, denyut, kondisi kulit, mata, dan telinga.',
      duration_minutes: 30,
      price: 85000,
      is_clinic_service: true,
      is_home_service: false,
    },
  },
  {
    from: 'Kunjungan Dokter ke Rumah',
    to: 'Pemeriksaan Laboratorium Darah',
    patch: {
      description:
        'Pengambilan sampel darah dan pemeriksaan hematologi dasar di klinik.',
      duration_minutes: 45,
      price: 185000,
      is_clinic_service: true,
      is_home_service: false,
    },
  },
];

/** Katalog layanan; setiap klinik mendapat 3 nama berbeda (rotasi per indeks). */
const SERVICE_CATALOG = [
  {
    name: 'Pemeriksaan Fisik Rutin',
    description:
      'Pemeriksaan fisik lengkap: suhu, denyut, kondisi kulit, mata, dan telinga.',
    duration_minutes: 30,
    price: 85000,
    is_clinic_service: true,
    is_home_service: false,
  },
  {
    name: 'Vaksinasi',
    description:
      'Vaksinasi rutin untuk anjing, kucing, dan hewan peliharaan lainnya.',
    duration_minutes: 20,
    price: 120000,
    is_clinic_service: true,
    is_home_service: false,
  },
  {
    name: 'Medical Check-up',
    description:
      'Pemeriksaan menyeluruh termasuk berat badan, suhu, dan kondisi umum.',
    duration_minutes: 45,
    price: 150000,
    is_clinic_service: true,
    is_home_service: false,
  },
  {
    name: 'Grooming',
    description: 'Perawatan bulu, mandi, dan kebersihan hewan peliharaan.',
    duration_minutes: 60,
    price: 95000,
    is_clinic_service: true,
    is_home_service: false,
  },
  {
    name: 'Sterilisasi',
    description: 'Layanan sterilisasi/kastrasi dengan pemantauan pasca operasi.',
    duration_minutes: 90,
    price: 450000,
    is_clinic_service: true,
    is_home_service: false,
  },
  {
    name: 'Perawatan Luka',
    description: 'Pembersihan luka, perban, dan kontrol penyembuhan.',
    duration_minutes: 30,
    price: 110000,
    is_clinic_service: true,
    is_home_service: false,
  },
  {
    name: 'Pemeriksaan Laboratorium Darah',
    description:
      'Pengambilan sampel darah dan pemeriksaan hematologi dasar di klinik.',
    duration_minutes: 45,
    price: 185000,
    is_clinic_service: true,
    is_home_service: false,
  },
  {
    name: 'Pemeriksaan Gigi',
    description: 'Pemeriksaan kesehatan gigi dan scaling ringan.',
    duration_minutes: 40,
    price: 175000,
    is_clinic_service: true,
    is_home_service: false,
  },
  {
    name: 'Pengobatan Parasit',
    description: 'Pengobatan kutu, pinworm, dan parasit eksternal/internal.',
    duration_minutes: 25,
    price: 65000,
    is_clinic_service: true,
    is_home_service: true,
  },
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

function pickServicesForClinic(clinicIndex) {
  const picked = [];
  const used = new Set();
  let offset = 0;
  while (picked.length < MIN_SERVICES_PER_CLINIC) {
    const template =
      SERVICE_CATALOG[(clinicIndex * MIN_SERVICES_PER_CLINIC + offset) %
        SERVICE_CATALOG.length];
    offset += 1;
    if (used.has(template.name)) continue;
    used.add(template.name);
    picked.push(template);
  }
  return picked;
}

async function applyServiceRenames() {
  for (const { from, to, patch } of SERVICE_RENAMES) {
    const { data, error } = await admin
      .from('services')
      .update({ name: to, ...patch })
      .eq('name', from)
      .select('id');

    if (error) fail(`Rename "${from}" → "${to}" failed: ${error.message}`);
    if (data?.length) {
      console.log(`Renamed ${data.length} row(s): "${from}" → "${to}"`);
    }
  }
}

async function main() {
  await applyServiceRenames();

  const { data: clinics, error: clinicError } = await admin
    .from('clinic_profiles')
    .select('id, profiles!inner(name)')
    .order('id');

  if (clinicError) fail(`Fetch clinics failed: ${clinicError.message}`);
  if (!clinics?.length) {
    console.log('No clinic_profiles found. Run npm run seed:users first.');
    return;
  }

  let insertedTotal = 0;
  let skippedClinics = 0;

  for (let i = 0; i < clinics.length; i += 1) {
    const clinic = clinics[i];
    const clinicId = clinic.id;
    const profile = clinic.profiles;
    const clinicName =
      (Array.isArray(profile) ? profile[0]?.name : profile?.name) ??
      clinicId;

    const { data: existing, error: existingError } = await admin
      .from('services')
      .select('id, name')
      .eq('clinic_id', clinicId)
      .eq('is_active', true);

    if (existingError) {
      fail(`Fetch services for ${clinicName}: ${existingError.message}`);
    }

    const existingNames = new Set((existing ?? []).map((s) => s.name));
    if (existingNames.size >= MIN_SERVICES_PER_CLINIC) {
      console.log(
        `  skip ${clinicName}: already has ${existingNames.size} service(s)`,
      );
      skippedClinics += 1;
      continue;
    }

    const templates = pickServicesForClinic(i);
    const toInsert = templates
      .filter((t) => !existingNames.has(t.name))
      .map((t) => ({
        clinic_id: clinicId,
        name: t.name,
        description: t.description,
        duration_minutes: t.duration_minutes,
        price: t.price,
        is_active: true,
        is_clinic_service: t.is_clinic_service,
        is_home_service: t.is_home_service,
      }));

    if (toInsert.length === 0) {
      console.log(`  skip ${clinicName}: no new templates to add`);
      skippedClinics += 1;
      continue;
    }

    const { error: insertError } = await admin.from('services').insert(toInsert);
    if (insertError) {
      fail(`Insert services for ${clinicName}: ${insertError.message}`);
    }

    insertedTotal += toInsert.length;
    console.log(
      `  ${clinicName}: +${toInsert.length} → ${toInsert.map((s) => s.name).join(', ')}`,
    );
  }

  console.log(
    `\nDone. Clinics: ${clinics.length}, inserted: ${insertedTotal}, skipped: ${skippedClinics}`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
