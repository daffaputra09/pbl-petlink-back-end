#!/usr/bin/env node
/**
 * Sinkronkan supabase_migrations.schema_migrations dengan file lokal.
 *
 * Masalah: migrasi yang di-apply lewat Supabase MCP/Dashboard memakai timestamp
 * otomatis (mis. 20260611143136) yang tidak ada di supabase/migrations/.
 * File lokal memakai timestamp berbeda (mis. 20260618120000) dengan SQL sama.
 *
 * Perbaikan: tandai entri orphan di remote sebagai reverted, lalu tandai file
 * lokal sebagai applied (SQL sudah ada di database).
 *
 * Usage: npm run db:repair:history
 */
import { spawnSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const steps = [
  {
    label: "Revert orphan MCP migrations (no local file)",
    args: [
      "migration",
      "repair",
      "--status",
      "reverted",
      "20260611143136",
      "20260611144616",
    ],
  },
  {
    label: "Mark local migrations as applied (SQL already on remote)",
    args: [
      "migration",
      "repair",
      "--status",
      "applied",
      "20260618120000",
      "20260619120000",
    ],
  },
];

console.log("Repairing remote migration history...\n");

for (const step of steps) {
  console.log(`→ ${step.label}`);
  const result = spawnSync("supabase", step.args, {
    cwd: root,
    stdio: "inherit",
  });
  if (result.status !== 0) {
    console.error(`\nFailed: supabase ${step.args.join(" ")}`);
    process.exit(result.status ?? 1);
  }
  console.log("");
}

console.log("Done. Verify with: npm run db:push");
console.log("(Should report: Remote database is up to date.)");
