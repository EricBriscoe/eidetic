import { env } from 'cloudflare:test'
import { describe, expect, it } from 'vitest'
import { mintConnectCode, redeemConnectCode } from '../src/services/connect'

const db = () => env.DB

describe('connect codes', () => {
  it('formats as XXXX-XXXX from the unambiguous alphabet', async () => {
    const { code, expires_at } = await mintConnectCode(db())
    expect(code).toMatch(/^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$/)
    expect(Date.parse(expires_at) - Date.now()).toBeGreaterThan(9 * 60_000)
  })

  it('redeems once, ignoring case and separators', async () => {
    const { code } = await mintConnectCode(db())
    expect(await redeemConnectCode(db(), ` ${code.toLowerCase().replace('-', ' ')} `, '10.0.0.1')).toBe('ok')
    expect(await redeemConnectCode(db(), code, '10.0.0.1')).toBe('invalid')
  })

  it('keeps only the newest code live', async () => {
    const first = await mintConnectCode(db())
    const second = await mintConnectCode(db())
    expect(await redeemConnectCode(db(), first.code, '10.0.0.2')).toBe('invalid')
    expect(await redeemConnectCode(db(), second.code, '10.0.0.2')).toBe('ok')
  })

  it('rejects expired codes', async () => {
    const { code } = await mintConnectCode(db())
    await db().prepare("UPDATE connect_codes SET expires_at = '2000-01-01T00:00:00Z'").run()
    expect(await redeemConnectCode(db(), code, '10.0.0.3')).toBe('invalid')
  })

  it('locks out a guessing IP without locking out everyone else', async () => {
    for (let i = 0; i < 10; i++) expect(await redeemConnectCode(db(), 'WRONG', '203.0.113.9')).toBe('invalid')
    const { code } = await mintConnectCode(db())
    expect(await redeemConnectCode(db(), code, '203.0.113.9')).toBe('locked')
    expect(await redeemConnectCode(db(), code, '198.51.100.7')).toBe('ok')
  })
})
