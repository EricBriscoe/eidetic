# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

eidetic is a single-user flashcard app. `ios/` is a SwiftUI app (iOS 18, Swift 6, strict concurrency). `backend/` is a Cloudflare Worker (TypeScript, Hono, D1) that serves REST to the app and MCP to assistants. README.md has setup and deploy details.

## Commands

```sh
# backend/  (wrangler.jsonc is gitignored; wrangler.example.jsonc is the template)
npm run dev                  # wrangler dev on :8898 (reads APP_TOKEN from .dev.vars)
npm test                     # vitest service tests in workerd with migrated D1 (test/*.test.ts)
npx vitest run test/reviews.test.ts -t "never moves"   # single file / test
npm run smoke                # scripts/smoke.sh: E2E against a running worker (REST, MCP, OAuth dance)
npm run typecheck
npm run db:migrate:local     # / db:migrate:remote; migrations/ is append-only
npm run deploy
BASE_URL=https://eidetic.<subdomain>.workers.dev TOKEN=<APP_TOKEN> npm run smoke

# ios/  (project.yml is the source of truth; the .xcodeproj and Config.xcconfig are gitignored)
xcodegen generate
xcodebuild test -project Eidetic.xcodeproj -scheme Eidetic -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test ... -only-testing:EideticTests/FSRSTests/testLapseRelearnsAndCounts   # single test
./scripts/install-device.sh  # Release build, install + launch on the paired iPhone
```

Backend unit tests cover services only. They don't load `src/index.ts`, because the MCP SDK's CommonJS deps don't run in the test pool, so HTTP, MCP and OAuth are covered by the smoke script. The test pool's bundled workerd lags wrangler's, so `vitest.config.ts` pins an older compatibility date. iOS unit tests cover FSRS, StudyQueue, and the review wire format. They never touch the network.

Account-specific values live only in gitignored files: `backend/wrangler.jsonc` (D1/KV ids), `backend/.dev.vars`, and `ios/Config.xcconfig` (URL, token, bundle id, team). Keep them out of committed files; this repo is meant to be open source.

## Architecture

**Who owns what.** Card *content* (sets, cards, text, order) is written only through MCP (`src/mcp.ts` → `src/services/library.ts`). The app never edits content. Card *scheduling* (state, step, stability, difficulty, due, reps, lapses, introduced_at) is computed only on the phone by `ios/Eidetic/Scheduling/FSRS.swift`. The server stores it verbatim through `POST /api/reviews`. MCP can reset scheduling to `new` but never computes it. Keep this split: don't add scheduling logic to the backend or content editing to the app.

**Review sync.** `Store.grade` applies the FSRS result locally, then appends to a persisted outbox (`Application Support/outbox.json`). The outbox flushes in batches. Review ids are client UUIDs, so replays are idempotent (`INSERT OR IGNORE`). The card UPDATE is guarded by `last_review <= reviewed_at`, so stale replays never rewind a card. Reviews of deleted cards come back as `missing`, and the app drops them. On refresh the app replaces its library with the server's copy, then re-applies any still-pending outbox entries.

**Timestamps** are second-resolution ISO 8601 UTC (`2026-09-20T10:10:00Z`) everywhere. SQL compares them as strings, and `schemas.ts` normalizes incoming values to this form. The Swift encoder omits nil optionals, so the review schema accepts missing keys as null (`orNull`).

**FSRS** is a port of py-fsrs 6: default parameters, learning steps 1m/10m, relearning step 10m, 90% retention, interval fuzz. `previews()` gives fuzz-free intervals for the button labels. `StudyQueue` is stateless and derives each pick from card scheduling. Order: due (re)learning, due reviews, new cards (capped per local day by `sets.new_per_day`, counted via `introduced_at`), then learning cards within a 20-minute learn-ahead window.

**Auth (single user, no users table).**
- The app sends `Authorization: Bearer <APP_TOKEN>`. That token is a Worker secret, locally in `.dev.vars`, and baked into the app from `ios/Config.xcconfig`.
- `/mcp` is OAuth-protected by `@cloudflare/workers-oauth-provider` 1.x. The provider needs a canonical resource URL, so `index.ts` builds one provider per request origin.
- The consent page (`routes/authorize.ts`) stands in for sign-in: the user types a one-time code that the app mints (`POST /api/connect-code`). The code is checked *before* `approveConsent`, because approving consumes the consent handle and a typo would otherwise strand the user.
- Codes live in D1, not KV, for read-after-write consistency. Wrong guesses are capped at 10 per client IP per hour, with a global backstop of 500, so a stranger can't lock the owner out.
- A bearer starting with `eid_` on `/mcp` skips OAuth, for Claude Code and the smoke test.

**MCP** (`src/mcp.ts`) builds a fresh stateless server per request. Unknown ids raise `NotFoundError`, which returns as an `isError` tool result, not a protocol error. Card text is inline Markdown and renders with `AttributedString(markdown:)` in `MarkdownText`.

## Design

Minimal and nearly unbranded. The UI uses system chrome, a monochrome tint (`.tint(.primary)`, AccentColor black/white), and lowercase one-word controls ("show", "again/hard/good/easy", "connect"). Prefer removing an element over adding one. The app has exactly three screens: the set list, study, and the connect sheet. Don't add features beyond reviewing unless asked.
