/**
 * Seeds Petlink users for all roles with complete role-specific profiles.
 * Requires SUPABASE_SERVICE_ROLE_KEY (Auth Admin API). Run:
 *   node --env-file=.env scripts/seed-users.mjs
 *
 * Clinic operating_hours: ISO weekday 1 = Monday … 7 = Sunday.
 * Each day may be closed or have one or more open periods (Google Maps style).
 */
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const defaultPassword = process.env.SEED_DEFAULT_PASSWORD ?? 'petlink';

const SEED_USERS = [
  {
    email: 'admin@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Admin 1', role: 'admin' },
  },
  {
    email: 'fathinatiqahf@gmail.com',
    password: defaultPassword,
    profile: { name: 'Atiqah Fathin Fauziyyah', role: 'customer' },
    customer: {
      gender: 'female',
      birth_date: '2002-03-15',
      address: 'Jl. Soekarno Hatta No. 9, Malang',
    },
  },
  {
    email: 'daffaputra863@gmail.com',
    password: defaultPassword,
    profile: { name: 'Daffa Putra Prasetya', role: 'customer' },
    customer: {
      gender: 'male',
      birth_date: '2001-07-22',
      address: 'Jl. Veteran No. 8, Malang',
    },
  },
  {
    email: 'desypuspita685@gmail.com',
    password: defaultPassword,
    profile: { name: 'Desy Dwi Puspita', role: 'customer' },
    customer: {
      gender: 'female',
      birth_date: '2003-01-08',
      address: 'Jl. Ijen No. 25, Malang',
    },
  },
  {
    email: 'naylaannora@gmail.com',
    password: defaultPassword,
    profile: { name: 'Nayla Annora Nobel Widyonarko', role: 'customer' },
    customer: {
      gender: 'female',
      birth_date: '2002-11-30',
      address: 'Jl. Merdeka Selatan No. 3, Malang',
    },
  },
  {
    email: 'nikytania0701@gmail.com',
    password: defaultPassword,
    profile: { name: 'Niky Tania Sari', role: 'customer' },
    customer: {
      gender: 'female',
      birth_date: '2001-05-18',
      address: 'Jl. Candi Agung I No. 12, Malang',
    },
  },
  {
    email: 'clinic.pnm@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Klinik Hewan Politeknik Negeri Malang', role: 'clinic' },
    clinic: {
      description: 'Klinik hewan dekat kampus Politeknik Negeri Malang.',
      address: 'Jl. Soekarno Hatta, Malang (area PNM)',
      latitude: -7.9468859,
      longitude: 112.613546,
      is_verified: true,
      operating_hours: [
        {
          day_of_week: 1,
          is_closed: false,
          periods: [
            { opens_at: '08:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '17:00:00' },
          ],
        },
        {
          day_of_week: 2,
          is_closed: false,
          periods: [
            { opens_at: '08:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '17:00:00' },
          ],
        },
        {
          day_of_week: 3,
          is_closed: false,
          periods: [
            { opens_at: '08:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '17:00:00' },
          ],
        },
        {
          day_of_week: 4,
          is_closed: false,
          periods: [
            { opens_at: '08:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '17:00:00' },
          ],
        },
        {
          day_of_week: 5,
          is_closed: false,
          periods: [
            { opens_at: '08:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '17:00:00' },
          ],
        },
        {
          day_of_week: 6,
          is_closed: false,
          periods: [{ opens_at: '08:00:00', closes_at: '14:00:00' }],
        },
        { day_of_week: 7, is_closed: true, periods: [] },
      ],
    },
  },
  {
    email: 'clinic.ub@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Klinik Hewan Universitas Brawijaya', role: 'clinic' },
    clinic: {
      description: 'Klinik hewan dekat kampus Universitas Brawijaya.',
      address: 'Jl. Veteran, Malang (area UB)',
      latitude: -7.9524597,
      longitude: 112.6111021,
      is_verified: true,
      operating_hours: [
        {
          day_of_week: 1,
          is_closed: false,
          periods: [{ opens_at: '08:00:00', closes_at: '20:00:00' }],
        },
        {
          day_of_week: 2,
          is_closed: false,
          periods: [{ opens_at: '08:00:00', closes_at: '20:00:00' }],
        },
        {
          day_of_week: 3,
          is_closed: false,
          periods: [{ opens_at: '08:00:00', closes_at: '20:00:00' }],
        },
        {
          day_of_week: 4,
          is_closed: false,
          periods: [{ opens_at: '08:00:00', closes_at: '20:00:00' }],
        },
        {
          day_of_week: 5,
          is_closed: false,
          periods: [{ opens_at: '08:00:00', closes_at: '20:00:00' }],
        },
        {
          day_of_week: 6,
          is_closed: false,
          periods: [{ opens_at: '09:00:00', closes_at: '17:00:00' }],
        },
        {
          day_of_week: 7,
          is_closed: false,
          periods: [{ opens_at: '10:00:00', closes_at: '16:00:00' }],
        },
      ],
    },
  },
  {
    email: 'clinic.asia@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Klinik Hewan Institut Asia Malang', role: 'clinic' },
    clinic: {
      description: 'Klinik hewan dekat Institut Asia Malang.',
      address: 'Jl. Kalimantan, Malang (area Institut Asia)',
      latitude: -7.9379677,
      longitude: 112.6240478,
      is_verified: true,
      operating_hours: [
        {
          day_of_week: 1,
          is_closed: false,
          periods: [
            { opens_at: '09:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '18:00:00' },
          ],
        },
        {
          day_of_week: 2,
          is_closed: false,
          periods: [
            { opens_at: '09:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '18:00:00' },
          ],
        },
        {
          day_of_week: 3,
          is_closed: false,
          periods: [
            { opens_at: '09:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '18:00:00' },
          ],
        },
        {
          day_of_week: 4,
          is_closed: false,
          periods: [
            { opens_at: '09:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '18:00:00' },
          ],
        },
        {
          day_of_week: 5,
          is_closed: false,
          periods: [
            { opens_at: '09:00:00', closes_at: '12:00:00' },
            { opens_at: '13:00:00', closes_at: '18:00:00' },
          ],
        },
        { day_of_week: 6, is_closed: true, periods: [] },
        { day_of_week: 7, is_closed: true, periods: [] },
      ],
    },
  },
  {
    email: 'doctor.daffa@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Daffa Putra Prasetya', role: 'doctor' },
    doctor: {
      clinicEmail: 'clinic.pnm@petlink-app.vercel.app',
      bio: 'Dokter hewan dengan fokus perawatan kucing dan anjing.',
      specialization: 'Dokter Hewan Umum',
      license_number: 'DVM-PNM-001',
      consultation_fee: 150000,
    },
  },
  {
    email: 'doctor.desy@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Desy Dwi Puspita', role: 'doctor' },
    doctor: {
      clinicEmail: 'clinic.ub@petlink-app.vercel.app',
      bio: 'Spesialis bedah minor dan vaksinasi hewan peliharaan.',
      specialization: 'Bedah Minor Hewan',
      license_number: 'DVM-UB-002',
      consultation_fee: 175000,
    },
  },
  {
    email: 'doctor.niky@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Niky Tania Sari', role: 'doctor' },
    doctor: {
      clinicEmail: 'clinic.asia@petlink-app.vercel.app',
      bio: 'Berpengalaman menangani hewan eksotik dan reptil.',
      specialization: 'Hewan Eksotik',
      license_number: 'DVM-ASIA-003',
      consultation_fee: 200000,
    },
  },
  {
    email: 'doctor.atiqah@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Atiqah Fathin Fauziyyah', role: 'doctor' },
    doctor: {
      clinicEmail: 'clinic.pnm@petlink-app.vercel.app',
      bio: 'Dokter hewan dengan minat nutrisi dan perawatan preventif.',
      specialization: 'Nutrisi Hewan',
      license_number: 'DVM-PNM-004',
      consultation_fee: 160000,
    },
  },
  {
    email: 'doctor.nayla@petlink-app.vercel.app',
    password: defaultPassword,
    profile: { name: 'Nayla Annora Nobel Widyonarko', role: 'doctor' },
    doctor: {
      clinicEmail: 'clinic.ub@petlink-app.vercel.app',
      bio: 'Fokus pada dermatologi dan perawatan kulit hewan peliharaan.',
      specialization: 'Dermatologi Hewan',
      license_number: 'DVM-UB-005',
      consultation_fee: 180000,
    },
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
      'Missing SUPABASE_SERVICE_ROLE_KEY in .env (required for auth.admin).',
      'Add it from Supabase Dashboard → Project Settings → API → service_role key.',
    ].join('\n'),
  );
}

const admin = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

async function listAllUsers() {
  const byEmail = new Map();
  let page = 1;
  const perPage = 200;
  for (;;) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage });
    if (error) throw error;
    for (const user of data.users) {
      if (user.email) byEmail.set(user.email.toLowerCase(), user);
    }
    if (data.users.length < perPage) break;
    page += 1;
  }
  return byEmail;
}

async function ensureAuthUser(seed, usersByEmail) {
  const normalized = seed.email.toLowerCase();
  const existing = usersByEmail.get(normalized);
  if (existing) {
    console.log(`  auth: exists ${seed.email} (${existing.id})`);
    return existing.id;
  }

  const { data, error } = await admin.auth.admin.createUser({
    email: seed.email,
    password: seed.password,
    email_confirm: true,
    user_metadata: { name: seed.profile.name },
  });

  if (error) {
    const m = error.message?.toLowerCase() ?? '';
    if (m.includes('already') || m.includes('registered') || m.includes('exists')) {
      const refreshed = await listAllUsers();
      const found = refreshed.get(normalized);
      if (!found) throw error;
      console.log(`  auth: exists ${seed.email} (${found.id})`);
      return found.id;
    }
    throw error;
  }

  usersByEmail.set(normalized, data.user);
  console.log(`  auth: created ${seed.email} (${data.user.id})`);
  return data.user.id;
}

async function upsertProfile(userId, profile) {
  const { error } = await admin.from('profiles').upsert(
    {
      id: userId,
      name: profile.name,
      role: profile.role,
      is_active: true,
    },
    { onConflict: 'id' },
  );
  if (error) throw error;
  console.log(`  profiles: upserted (${profile.role})`);
}

async function upsertCustomerProfile(userId, customer) {
  const { error } = await admin.from('customer_profiles').upsert(
    {
      id: userId,
      gender: customer.gender,
      birth_date: customer.birth_date,
      address: customer.address,
    },
    { onConflict: 'id' },
  );
  if (error) throw error;
  console.log('  customer_profiles: upserted');
}

async function upsertClinicProfile(userId, clinic) {
  const { error } = await admin.from('clinic_profiles').upsert(
    {
      id: userId,
      description: clinic.description,
      address: clinic.address,
      latitude: clinic.latitude,
      longitude: clinic.longitude,
      is_verified: clinic.is_verified ?? true,
    },
    { onConflict: 'id' },
  );
  if (error) throw error;
  console.log('  clinic_profiles: upserted');

  if (clinic.operating_hours?.length) {
    const { error: hoursError } = await admin.rpc('replace_clinic_opening_hours', {
      p_clinic_id: userId,
      p_days: clinic.operating_hours,
    });
    if (hoursError) throw hoursError;
    console.log(
      `  clinic_opening_hours: replaced (${clinic.operating_hours.length} day(s))`,
    );
  }
}

async function upsertDoctorProfile(userId, doctor, clinicIdsByEmail) {
  const clinicId = clinicIdsByEmail.get(doctor.clinicEmail.toLowerCase());
  if (!clinicId) {
    throw new Error(
      `Clinic not found for doctor ${userId}: ${doctor.clinicEmail}. Seed clinics first.`,
    );
  }

  const { error } = await admin.from('doctor_profiles').upsert(
    {
      id: userId,
      clinic_id: clinicId,
      bio: doctor.bio,
      specialization: doctor.specialization,
      license_number: doctor.license_number,
      consultation_fee: doctor.consultation_fee,
      is_active: true,
    },
    { onConflict: 'id' },
  );
  if (error) throw error;
  console.log(`  doctor_profiles: upserted (clinic=${doctor.clinicEmail})`);
}

async function main() {
  const usersByEmail = await listAllUsers();
  const clinicIdsByEmail = new Map();

  const clinics = SEED_USERS.filter((u) => u.profile.role === 'clinic');
  const nonDoctors = SEED_USERS.filter((u) => u.profile.role !== 'doctor');
  const doctors = SEED_USERS.filter((u) => u.profile.role === 'doctor');

  console.log('--- Phase 1: admin, customers, clinics ---');
  for (const seed of nonDoctors) {
    console.log(`\n[${seed.profile.role}] ${seed.email}`);
    const userId = await ensureAuthUser(seed, usersByEmail);
    await upsertProfile(userId, seed.profile);

    if (seed.customer) await upsertCustomerProfile(userId, seed.customer);
    if (seed.clinic) {
      await upsertClinicProfile(userId, seed.clinic);
      clinicIdsByEmail.set(seed.email.toLowerCase(), userId);
    }
  }

  console.log('\n--- Phase 2: doctors (require clinic profiles) ---');
  for (const seed of doctors) {
    console.log(`\n[${seed.profile.role}] ${seed.email}`);
    const userId = await ensureAuthUser(seed, usersByEmail);
    await upsertProfile(userId, seed.profile);
    await upsertDoctorProfile(userId, seed.doctor, clinicIdsByEmail);
  }

  console.log('\nDone. Seeded users:');
  console.log(`  admin:     1`);
  console.log(`  customer:  ${SEED_USERS.filter((u) => u.profile.role === 'customer').length}`);
  console.log(`  clinic:    ${clinics.length}`);
  console.log(`  doctor:    ${doctors.length}`);
  console.log(`  password:  ${defaultPassword}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
