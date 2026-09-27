import { createMiddleware } from 'hono/factory'
import type { AppEnv } from './types'

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** Constant-time check of an Authorization header against APP_TOKEN. Hashing
 *  first gives equal-length buffers, which timingSafeEqual requires. */
export async function isAppToken(header: string | undefined, appToken: string | undefined): Promise<boolean> {
  const token = header?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim()
  if (!token || !appToken) return false
  const enc = new TextEncoder()
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(token)),
    crypto.subtle.digest('SHA-256', enc.encode(appToken)),
  ])
  return crypto.subtle.timingSafeEqual(a, b)
}

export const requireAppToken = createMiddleware<AppEnv>(async (c, next) => {
  if (!(await isAppToken(c.req.header('authorization'), c.env.APP_TOKEN))) {
    return c.json({ error: 'unauthorized' }, 401)
  }
  await next()
})
