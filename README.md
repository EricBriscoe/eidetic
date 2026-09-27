# eidetic

A minimal iOS flashcard app. The app only lists sets and studies them with
[FSRS](https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-Algorithm)
spaced repetition. Sets are created and edited by an AI assistant over MCP,
served by a Cloudflare Worker.

```
┌──────────┐  REST (APP_TOKEN)   ┌───────────────────────────────┐
│ iOS app  │ ──────────────────▶ │ Cloudflare Worker (eidetic)    │
└──────────┘                     │  /api/*   app REST             │
┌──────────┐  MCP (OAuth)        │  /mcp     assistant tools      │
│ Claude … │ ──────────────────▶ │  /authorize  consent + code    │
└──────────┘                     │  D1 (sets, cards, reviews)     │
                                 └───────────────────────────────┘
```

It is single-user and build-it-yourself. Each person deploys their own
worker and builds the app with their own token baked in. There are no
accounts, so don't distribute a built binary: anyone holding it has your token.

## Setup

You need Node 20+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and a Cloudflare account.

### Backend

```sh
cd backend
npm install
cp wrangler.example.jsonc wrangler.jsonc
npx wrangler d1 create eidetic                 # paste database_id into wrangler.jsonc
npx wrangler kv namespace create eidetic-oauth # paste id into wrangler.jsonc
npm run db:migrate:remote
npm run deploy                                 # prints https://eidetic.<your-subdomain>.workers.dev
TOKEN="eid_$(openssl rand -hex 24)"; echo "$TOKEN"   # keep this; the app needs it
printf '%s' "$TOKEN" | npx wrangler secret put APP_TOKEN
```

Local development:

```sh
echo "APP_TOKEN=eid_$(openssl rand -hex 24)" > .dev.vars
npm run db:migrate:local
npm run dev                      # wrangler dev on :8898
npm test                         # service unit tests (vitest, workerd + D1)
npm run smoke                    # E2E against BASE_URL (default localhost:8898)
npm run typecheck
```

Smoke-test a deployment with `BASE_URL=https://eidetic.<your-subdomain>.workers.dev TOKEN=<APP_TOKEN> npm run smoke`.
It creates and deletes its own set.

### iOS

```sh
cd ios
cp Config.xcconfig.example Config.xcconfig   # API_BASE_URL, API_TOKEN, BUNDLE_ID, DEVELOPMENT_TEAM
xcodegen generate
./scripts/install-device.sh                  # Release build → paired iPhone
xcodebuild test -project Eidetic.xcodeproj -scheme Eidetic -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Connecting an assistant

- **claude.ai**: add a custom connector with URL
  `https://eidetic.<your-subdomain>.workers.dev/mcp`, or use
  **connect → add to claude** in the app. When the consent page asks for a
  code, tap **connect → get code** in the app. Codes are single-use and last
  10 minutes.
- **Claude Code**: `claude mcp add --transport http eidetic https://eidetic.<your-subdomain>.workers.dev/mcp --header "Authorization: Bearer <APP_TOKEN>"`.
  `eid_` bearer tokens skip OAuth.

Tools: `list_sets`, `get_set` (cards + progress + 30-day retention),
`create_set`, `update_set`, `delete_set`, `add_cards`, `update_cards`,
`delete_cards`, `reset_set_progress`.

## License

[MIT](LICENSE)
