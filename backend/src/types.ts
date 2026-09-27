import type { OAuthHelpers } from '@cloudflare/workers-oauth-provider'

export interface Env {
  DB: D1Database
  OAUTH_KV: KVNamespace
  /** Bearer token for the iOS app (and Claude Code via header). Worker secret; `eid_`-prefixed. */
  APP_TOKEN: string
  /** Injected by OAuthProvider on defaultHandler requests (everything except /mcp*). */
  OAUTH_PROVIDER: OAuthHelpers
}

/** Stored (encrypted) with each OAuth grant; arrives on /mcp as `executionCtx.props`. */
export type GrantProps = { owner: true; clientName?: string | null }

export type AppEnv = { Bindings: Env }
