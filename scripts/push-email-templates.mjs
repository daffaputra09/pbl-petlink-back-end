#!/usr/bin/env node
/**
 * Deploy custom invite/recovery email templates + OTP expiry to hosted Supabase.
 *
 * Requires in .env:
 *   SUPABASE_URL (or SUPABASE_PROJECT_REF)
 *   SUPABASE_ACCESS_TOKEN — personal token from https://supabase.com/dashboard/account/tokens
 *   SUPABASE_SITE_URL (default https://petlink-app.vercel.app)
 *
 * Usage: npm run auth:templates:push
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function loadEnvFile(path) {
  try {
    const raw = readFileSync(path, "utf8");
    for (const line of raw.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim();
      let value = trimmed.slice(eq + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      if (!(key in process.env)) process.env[key] = value;
    }
  } catch {
    // optional
  }
}

loadEnvFile(resolve(root, ".env"));

const accessToken = process.env.SUPABASE_ACCESS_TOKEN?.trim();
const siteUrl =
  process.env.SUPABASE_SITE_URL?.trim() || "https://petlink-app.vercel.app";
const projectRef =
  process.env.SUPABASE_PROJECT_REF?.trim() ||
  process.env.SUPABASE_URL?.match(/https:\/\/([^.]+)\.supabase\.co/)?.[1];

if (!accessToken) {
  console.error(
    "Missing SUPABASE_ACCESS_TOKEN.\n" +
      "Create one at https://supabase.com/dashboard/account/tokens\n" +
      "Then add to pbl-petlink-back-end/.env and rerun: npm run auth:templates:push\n\n" +
      "Alternative: npm run auth:config:push (Supabase CLI login)"
  );
  process.exit(1);
}

if (!projectRef) {
  console.error("Set SUPABASE_URL or SUPABASE_PROJECT_REF in .env");
  process.exit(1);
}

const inviteHtml = readFileSync(
  resolve(root, "supabase/templates/invite.html"),
  "utf8"
);
const recoveryHtml = readFileSync(
  resolve(root, "supabase/templates/recovery.html"),
  "utf8"
);

const body = {
  site_url: siteUrl,
  mailer_otp_exp: 86400,
  mailer_subjects_invite: "Undangan Akun Dokter PetLink — Atur Kata Sandi",
  mailer_templates_invite_content: inviteHtml,
  mailer_subjects_recovery: "Reset Kata Sandi PetLink",
  mailer_templates_recovery_content: recoveryHtml,
};

console.log(`Pushing email templates to project: ${projectRef}`);
console.log(`  Site URL:   ${siteUrl}`);
console.log(`  OTP expiry: ${body.mailer_otp_exp}s (24 jam)`);

const response = await fetch(
  `https://api.supabase.com/v1/projects/${projectRef}/config/auth`,
  {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  }
);

const text = await response.text();
if (!response.ok) {
  console.error(`Failed (${response.status}):`, text);
  process.exit(1);
}

console.log("\nDone. Email invite/reset sekarang memakai template PetLink:");
console.log("  → /auth/accept-invite?token_hash=... (bukan supabase.co/auth/v1/verify)");
console.log("\nKirim ulang undangan/reset password untuk menguji tautan baru.");
