import OAuthProvider from '@cloudflare/workers-oauth-provider'
import { Hono, type Context } from 'hono'
import { isAppToken, requireAppToken } from './auth'
import { errorResponse, readJson } from './errors'
import { buildMcpServer } from './mcp'
import { handleMcpRequest } from './mcp-transport'
import { authorize } from './routes/authorize'
import { reviewsBody } from './schemas'
import { mintConnectCode } from './services/connect'
import { library } from './services/library'
import { recordReviews } from './services/reviews'
import type { AppEnv, Env, GrantProps } from './types'

const app = new Hono<AppEnv>()

app.get('/', (c) => c.json({ ok: true, service: 'eidetic' }))

// --- iOS app REST (APP_TOKEN bearer) ---
const api = new Hono<AppEnv>()
api.use('*', requireAppToken)
api.get('/library', async (c) => c.json(await library(c.env.DB)))
api.post('/reviews', async (c) => {
  const { reviews } = await readJson(c, reviewsBody)
  return c.json(await recordReviews(c.env.DB, reviews))
})
api.post('/connect-code', async (c) => c.json(await mintConnectCode(c.env.DB), 201))
app.route('/api', api)

// OAuth consent page (defaultHandler side; OAUTH_PROVIDER injected).
app.route('/authorize', authorize)

// Remote MCP (Streamable HTTP). Reached either through the OAuth provider
// (grant props on executionCtx) or the APP_TOKEN header bypass in fetch below.
async function serveMcp(c: Context<AppEnv>) {
  const props = (c.executionCtx as ExecutionContext & { props?: GrantProps }).props
  if (!props?.owner && !(await isAppToken(c.req.header('authorization'), c.env.APP_TOKEN))) {
    return c.json({ error: 'unauthorized' }, 401)
  }
  return handleMcpRequest(c, buildMcpServer(c.env.DB))
}
app.all('/mcp', serveMcp)

app.onError(errorResponse)

// OAuthProvider 1.x binds every token to one canonical resource URL, which
// depends on the host (workers.dev in prod, localhost in dev). Build one per
// origin; only hosts routed to this worker ever reach here.
const providers = new Map<string, OAuthProvider<Env>>()
function providerFor(origin: string): OAuthProvider<Env> {
  let provider = providers.get(origin)
  if (!provider) {
    const handler = app as unknown as ExportedHandler<Env> & { fetch: NonNullable<ExportedHandler<Env>['fetch']> }
    provider = new OAuthProvider<Env>({
      apiRoute: '/mcp',
      apiHandler: handler,
      defaultHandler: handler,
      authorizeEndpoint: '/authorize',
      tokenEndpoint: '/token',
      clientRegistrationEndpoint: '/register',
      scopesSupported: ['eidetic'],
      // Client ID Metadata Documents (MCP 2026 preferred); needs global_fetch_strictly_public.
      clientIdMetadataDocumentEnabled: true,
      resourceMetadata: { resource: `${origin}/mcp` },
    })
    providers.set(origin, provider)
  }
  return provider
}

export default {
  fetch(request, env, ctx) {
    const url = new URL(request.url)
    // APP_TOKEN bearer on /mcp (Claude Code --header, curl, smoke tests) skips
    // OAuth; serveMcp still verifies it. Provider-issued tokens never start eid_.
    if (url.pathname === '/mcp' && /^Bearer\s+eid_/i.test(request.headers.get('authorization') ?? '')) {
      return app.fetch(request, env, ctx)
    }
    return providerFor(url.origin).fetch(request, env, ctx)
  },
} satisfies ExportedHandler<Env>
