import { AuthorizationError, CimdFetchError, type AuthRequest, type ClientInfo } from '@cloudflare/workers-oauth-provider'
import { Hono, type Context } from 'hono'
import { redeemConnectCode } from '../services/connect'
import type { AppEnv, GrantProps } from '../types'

/** OAuth consent for assistants (Claude, ChatGPT…). There are no accounts, so
 *  "signing in" is proving you hold the phone: the app mints a one-time code
 *  and you type it here. Everything renders HTML — a browser is on the other end. */
export const authorize = new Hono<AppEnv>()

const esc = (s: string) => s.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`)

authorize.get('/', async (c) => {
  let request: AuthRequest
  let client: ClientInfo | null
  try {
    request = await c.env.OAUTH_PROVIDER.parseAuthRequest(c.req.raw)
    client = await c.env.OAUTH_PROVIDER.lookupClient(request.clientId)
  } catch (err) {
    return authError(c, err)
  }
  if (!client) return messagePage(c, "The app asking to connect isn't registered. Try adding the connector again.")
  const consent = await c.env.OAUTH_PROVIDER.beginConsent(request)
  consent.headers.set('Content-Type', 'text/html; charset=utf-8')
  const view = { clientId: client.clientId, clientName: client.clientName ?? null, redirectHost: new URL(request.redirectUri).hostname }
  return new Response(consentPage(view, consent.handle), { headers: consent.headers })
})

authorize.post('/', async (c) => {
  const form = await c.req.formData()
  const handle = String(form.get('handle') ?? '')
  const oauth = c.env.OAUTH_PROVIDER
  try {
    if (form.get('decision') !== 'approve') {
      const denied = await oauth.denyConsent(c.req.raw, handle)
      return new Response(null, { status: 302, headers: denied.headers })
    }
    // Check the code BEFORE approveConsent: approving consumes the handle, and
    // a typo should re-render this same form, not strand the user.
    const result = await redeemConnectCode(c.env.DB, String(form.get('code') ?? ''), c.req.header('cf-connecting-ip') ?? null)
    if (result !== 'ok') {
      // Display-only fields echoed from the form; approval itself uses the
      // server-stored request behind the handle, never these.
      const clientId = String(form.get('client_id') ?? '')
      const client = clientId ? await oauth.lookupClient(clientId) : null
      const view = { clientId, clientName: client?.clientName ?? null, redirectHost: String(form.get('redirect_host') ?? '') }
      const message =
        result === 'locked' ? 'Too many wrong codes. Wait an hour and try again.' : "That code didn't match. Mint a fresh one in the app."
      return c.html(consentPage(view, handle, message), 200, { 'X-Frame-Options': 'DENY' })
    }
    const approved = await oauth.approveConsent(c.req.raw, handle)
    const client = await oauth.lookupClient(approved.request.clientId)
    const { redirectTo } = await oauth.completeAuthorization({
      request: approved.request,
      userId: 'owner',
      metadata: { label: client?.clientName ?? 'unknown client', connectedAt: new Date().toISOString() },
      scope: approved.request.scope,
      props: { owner: true, clientName: client?.clientName ?? null } satisfies GrantProps,
    })
    approved.headers.set('Location', redirectTo)
    return new Response(null, { status: 302, headers: approved.headers })
  } catch (err) {
    return authError(c, err)
  }
})

function authError(c: Context<AppEnv>, err: unknown): Response {
  if (err instanceof AuthorizationError && err.redirectUri) {
    const redirect = new URL(err.redirectUri)
    redirect.searchParams.set('error', err.code)
    redirect.searchParams.set('error_description', err.description)
    if (err.state) redirect.searchParams.set('state', err.state)
    if (err.issuer) redirect.searchParams.set('iss', err.issuer)
    return Response.redirect(redirect.href, 302)
  }
  if (err instanceof AuthorizationError) return messagePage(c, `${err.description} Start again from your assistant.`)
  if (err instanceof CimdFetchError) return messagePage(c, 'The app asking to connect could not be verified.')
  throw err
}

function messagePage(c: Context<AppEnv>, message: string) {
  return c.html(shell(`<h1>eidetic</h1><p class="muted">${esc(message)}</p>`), 400, { 'X-Frame-Options': 'DENY' })
}

type ConsentView = { clientId: string; clientName: string | null; redirectHost: string }

function consentPage(view: ConsentView, handle: string, error?: string): string {
  const name = esc(view.clientName ?? 'An app')
  const local = /^(localhost|127(\.\d{1,3}){3}|\[::1\])$/.test(view.redirectHost)
  return shell(`
  <h1>eidetic</h1>
  <p><strong>${name}</strong> wants to read and edit your flashcard sets.</p>
  <p class="muted small">Access goes to <strong>${esc(view.redirectHost)}</strong>.${
    local ? ' That is an app on this computer — continue only if you just started connecting from it.' : ''
  }</p>
  <form method="post">
    <input type="hidden" name="handle" value="${esc(handle)}">
    <input type="hidden" name="client_id" value="${esc(view.clientId)}">
    <input type="hidden" name="redirect_host" value="${esc(view.redirectHost)}">
    <label for="code" class="muted small">In eidetic on your phone, tap <strong>connect</strong> and enter the code it shows.</label>
    <input id="code" name="code" autocomplete="one-time-code" autocapitalize="characters" spellcheck="false"
           placeholder="XXXX-XXXX" maxlength="12" required autofocus>
    ${error ? `<p class="error">${esc(error)}</p>` : ''}
    <button name="decision" value="approve">connect</button>
  </form>
  <form method="post">
    <input type="hidden" name="handle" value="${esc(handle)}">
    <button name="decision" value="deny" class="link">cancel</button>
  </form>`)
}

function shell(body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Connect to eidetic</title>
<style>
  :root { color-scheme: light dark; --fg: #1c1c1e; --bg: #fff; --muted: #6e6e73; --field: #f2f2f7; }
  @media (prefers-color-scheme: dark) { :root { --fg: #f2f2f7; --bg: #000; --muted: #98989e; --field: #1c1c1e; } }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--fg);
         font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  main { width: 100%; max-width: 22rem; padding: 2rem 1rem; }
  h1 { font-size: 1.1rem; font-weight: 600; letter-spacing: -0.01em; margin: 0 0 1.5rem; }
  .muted { color: var(--muted); } .small { font-size: 0.9rem; }
  .error { color: #d70015; font-size: 0.9rem; }
  input[name=code] { width: 100%; margin: 0.75rem 0; padding: 0.8rem; border: 0; border-radius: 12px; background: var(--field);
          color: var(--fg); font: 600 1.6rem/1 ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: 0.1em; text-align: center; }
  button { width: 100%; padding: 0.8rem; border: 0; border-radius: 12px; background: var(--fg); color: var(--bg);
           font: inherit; font-weight: 600; cursor: pointer; }
  button.link { background: none; color: var(--muted); font-weight: 400; margin-top: 0.25rem; }
</style>
</head>
<body><main>${body}</main></body>
</html>`
}
