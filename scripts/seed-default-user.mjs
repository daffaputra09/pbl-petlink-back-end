/**
 * Creates a default Supabase Auth user and upserts public.profiles.
 * Requires SUPABASE_SERVICE_ROLE_KEY (Admin API). Loads env from .env via:
 *   node --env-file=.env scripts/seed-default-user.mjs
 */
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

const email =
  process.env.SEED_DEFAULT_USER_EMAIL ?? 'admin@petlink.local';
const password =
  process.env.SEED_DEFAULT_USER_PASSWORD ?? 'petlink';
const profileName =
  process.env.SEED_DEFAULT_PROFILE_NAME ?? 'Petlink Default Admin';
const profileRole = process.env.SEED_DEFAULT_PROFILE_ROLE ?? 'admin';

const VALID_ROLES = new Set(['customer', 'clinic', 'doctor', 'admin']);

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

if (!url) fail('Missing SUPABASE_URL.');
if (!serviceKey)
  fail(
    [
      'Missing SUPABASE_SERVICE_ROLE_KEY in .env (required for auth.admin).',
      'Add it from Supabase Dashboard → Project Settings → API → service_role key.',
      'See .env.example. Never expose this key to clients.',
    ].join('\n'),
  );
if (!VALID_ROLES.has(profileRole))
  fail(
    `SEED_DEFAULT_PROFILE_ROLE must be one of: ${[...VALID_ROLES].join(', ')} (got "${profileRole}").`,
  );

const admin = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

async function findUserIdByEmail(targetEmail) {
  const normalized = targetEmail.toLowerCase();
  let page = 1;
  const perPage = 200;
  for (;;) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage });
    if (error) throw error;
    const found = data.users.find(
      (u) => u.email?.toLowerCase() === normalized,
    );
    if (found) return found.id;
    if (data.users.length < perPage) return null;
    page += 1;
  }
}

async function main() {
  let userId = await findUserIdByEmail(email);

  if (userId) {
    console.log(`Auth user already exists: ${email} (${userId}). Skipping create.`);
  } else {
    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { name: profileName },
    });
    if (error) {
      const m = error.message?.toLowerCase() ?? '';
      if (
        m.includes('already') ||
        m.includes('registered') ||
        m.includes('exists')
      ) {
        userId = await findUserIdByEmail(email);
        if (!userId) throw error;
        console.log(`Auth user already exists: ${email} (${userId}).`);
      } else {
        throw error;
      }
    } else {
      userId = data.user.id;
      console.log(`Created Auth user: ${email} (${userId}).`);
    }
  }

  const { error: profileError } = await admin.from('profiles').upsert(
    {
      id: userId,
      name: profileName,
      role: profileRole,
      is_active: true,
    },
    { onConflict: 'id' },
  );
  if (profileError) throw profileError;

  console.log(`Upserted public.profiles for ${userId} (role=${profileRole}).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
