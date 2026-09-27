import { sha256Hex } from '../auth'

/** No 0/O, 1/I/L — codes survive being squinted at on a phone. */
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
const LENGTH = 8
const TTL_MINUTES = 10
const MAX_FAILURES_PER_IP_HOUR = 10
/** Backstop against distributed guessing: 500 guesses/hour over a ~8.5e11
 *  code space with one live code is still hopeless for the attacker. */
const MAX_FAILURES_PER_HOUR = 500

const iso = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z')

function randomCode(): string {
  // Rejection sampling keeps the distribution uniform over the alphabet.
  const limit = 256 - (256 % ALPHABET.length)
  let code = ''
  while (code.length < LENGTH) {
    for (const b of crypto.getRandomValues(new Uint8Array(LENGTH * 2))) {
      if (b < limit && code.length < LENGTH) code += ALPHABET[b % ALPHABET.length]
    }
  }
  return code
}

export const normalizeCode = (raw: string) => raw.toUpperCase().replace(/[^A-Z0-9]/g, '')
export const formatCode = (code: string) => `${code.slice(0, 4)}-${code.slice(4)}`

/** Mints the single live connect code, replacing any earlier one. Only the hash is stored. */
export async function mintConnectCode(db: D1Database): Promise<{ code: string; expires_at: string }> {
  const code = randomCode()
  const expires_at = iso(Date.now() + TTL_MINUTES * 60_000)
  await db.batch([
    db.prepare('DELETE FROM connect_codes'),
    db.prepare('INSERT INTO connect_codes (code_hash, expires_at) VALUES (?, ?)').bind(await sha256Hex(code), expires_at),
  ])
  return { code: formatCode(code), expires_at }
}

export type RedeemResult = 'ok' | 'invalid' | 'locked'

/** Single-use: a valid code is deleted as it's redeemed. Misses count per
 *  client IP (and globally, as a backstop); past either cap, attempts fail
 *  until the hour drains. */
export async function redeemConnectCode(db: D1Database, raw: string, ip: string | null): Promise<RedeemResult> {
  const now = iso(Date.now())
  const hourAgo = iso(Date.now() - 3_600_000)
  const failures = await db
    .prepare('SELECT COUNT(*) AS total, COALESCE(SUM(ip IS ?), 0) AS mine FROM connect_failures WHERE at > ?')
    .bind(ip, hourAgo)
    .first<{ total: number; mine: number }>()
  if ((failures?.mine ?? 0) >= MAX_FAILURES_PER_IP_HOUR || (failures?.total ?? 0) >= MAX_FAILURES_PER_HOUR) return 'locked'

  const hit = await db
    .prepare('DELETE FROM connect_codes WHERE code_hash = ? AND expires_at > ? RETURNING code_hash')
    .bind(await sha256Hex(normalizeCode(raw)), now)
    .first()
  if (hit) return 'ok'
  await db.batch([
    db.prepare('INSERT INTO connect_failures (at, ip) VALUES (?, ?)').bind(now, ip),
    db.prepare("DELETE FROM connect_failures WHERE at < strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 day')"),
  ])
  return 'invalid'
}
