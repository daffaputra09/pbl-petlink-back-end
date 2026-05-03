/**
 * Smoke test: sign in with email/password using the publishable (anon) key.
 *   node --env-file=.env scripts/test-auth-login.mjs
 */
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_PUBLISHABLE_KEY;
const email =
  process.env.TEST_LOGIN_EMAIL ??
  process.env.SEED_DEFAULT_USER_EMAIL ??
  'admin@petlink.local';
const password =
  process.env.TEST_LOGIN_PASSWORD ??
  process.env.SEED_DEFAULT_USER_PASSWORD ??
  'petlink';

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

if (!url) fail('Missing SUPABASE_URL in .env');
if (!key) fail('Missing SUPABASE_PUBLISHABLE_KEY in .env');

const supabase = createClient(url, key);

const { data, error } = await supabase.auth.signInWithPassword({
  email,
  password,
});

if (error) {
  console.error('Login failed:', error.message);
  process.exit(1);
}

const token = data.session?.access_token;
console.log('Login OK');
console.log('  user id:', data.user?.id);
console.log('  email:', data.user?.email);
console.log(
  '  access_token (first 24 chars):',
  token ? `${token.slice(0, 24)}…` : '(none)',
);
console.log(
  '\nUse this JWT as Authorization: Bearer <access_token> against Supabase REST or your Nest guard after you wire JWT verification.',
);
