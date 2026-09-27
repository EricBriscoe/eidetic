import path from 'node:path'
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers'
import { defineConfig } from 'vitest/config'

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, 'migrations'))
  return {
    plugins: [
      cloudflareTest({
        // No wrangler configPath on purpose: that would bundle src/index.ts and
        // the MCP SDK's CJS deps into workerd. These are service-layer tests;
        // they only need D1. HTTP, MCP and OAuth are covered by scripts/smoke.sh.
        miniflare: {
          // The pool's bundled workerd lags wrangler's; keep this at or below its newest date.
          compatibilityDate: '2026-08-01',
          compatibilityFlags: ['nodejs_compat'],
          d1Databases: ['DB'],
          bindings: { TEST_MIGRATIONS: migrations },
        },
      }),
    ],
    test: { setupFiles: ['./test/apply-migrations.ts'] },
  }
})
