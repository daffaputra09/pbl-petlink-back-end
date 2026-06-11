#!/usr/bin/env node
/**
 * Push auth + Gmail SMTP config from config.toml to linked Supabase project.
 * Requires .env with SUPABASE_SMTP_* and SUPABASE_SITE_URL.
 *
 * Usage: npm run auth:config:push
 */
import { spawnSync } from "node:child_process";
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

const required = [
  "SUPABASE_SMTP_HOST",
  "SUPABASE_SMTP_USER",
  "SUPABASE_SMTP_PASS",
  "SUPABASE_SMTP_ADMIN_EMAIL",
  "SUPABASE_SITE_URL",
];

const missing = required.filter((k) => !process.env[k]?.trim());
if (missing.length > 0) {
  console.error(
    `Missing env: ${missing.join(", ")}\nCopy .env.example → .env and fill Gmail SMTP credentials.`
  );
  process.exit(1);
}

const url = process.env.SUPABASE_URL ?? "";
const projectRef =
  process.env.SUPABASE_PROJECT_REF ??
  url.match(/https:\/\/([^.]+)\.supabase\.co/)?.[1];

if (!projectRef) {
  console.error(
    "Set SUPABASE_URL in .env (or SUPABASE_PROJECT_REF) to identify the remote project."
  );
  process.exit(1);
}

console.log(`Pushing auth config (Gmail SMTP) to project: ${projectRef}`);
console.log(`  SMTP host: ${process.env.SUPABASE_SMTP_HOST}`);
console.log(`  From:      ${process.env.SUPABASE_SMTP_ADMIN_EMAIL}`);
console.log(`  Site URL:  ${process.env.SUPABASE_SITE_URL}`);

const result = spawnSync(
  "supabase",
  ["config", "push", "--project-ref", projectRef, "--yes"],
  {
    cwd: root,
    stdio: "inherit",
    env: process.env,
  }
);

if (result.status !== 0) {
  console.error(
    "\nPush failed. Run `supabase login` first if not authenticated."
  );
  process.exit(result.status ?? 1);
}

console.log("\nDone. Auth emails (invite/reset) now use Gmail SMTP, not Supabase default.");
