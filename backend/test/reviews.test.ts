import { env } from 'cloudflare:test'
import { beforeEach, describe, expect, it } from 'vitest'
import { createSet, listCards, setStats } from '../src/services/library'
import { recordReviews, type ReviewInput } from '../src/services/reviews'

const db = () => env.DB
let setId: string
let cardId: string

function review(reviewedAt: string, due: string, overrides: Partial<ReviewInput> = {}): ReviewInput {
  return {
    id: crypto.randomUUID(),
    card_id: cardId,
    rating: 3,
    reviewed_at: reviewedAt,
    duration_ms: 1000,
    prior_state: 'new',
    card: { state: 'learning', step: 1, stability: 2.3, difficulty: 5, due, reps: 1, lapses: 0, introduced_at: reviewedAt },
    ...overrides,
  }
}

const card = async () => (await listCards(db(), setId))[0]!

beforeEach(async () => {
  setId = (await createSet(db(), { name: 'reviews', cards: [{ front: 'f', back: 'b' }] })).id
  cardId = (await card()).id
})

describe('review sync', () => {
  it('stores the scheduling the app computed', async () => {
    const r = review('2026-09-20T10:00:00Z', '2026-09-20T10:10:00Z')
    expect(await recordReviews(db(), [r])).toEqual({ accepted: [r.id], missing: [] })
    expect(await card()).toMatchObject({
      state: 'learning', step: 1, due: '2026-09-20T10:10:00Z', last_review: '2026-09-20T10:00:00Z', introduced_at: '2026-09-20T10:00:00Z',
    })
  })

  it('is idempotent on review id', async () => {
    const r = review('2026-09-20T10:00:00Z', '2026-09-20T10:10:00Z')
    await recordReviews(db(), [r])
    await recordReviews(db(), [r])
    const { n } = (await db().prepare('SELECT COUNT(*) AS n FROM reviews WHERE card_id = ?').bind(cardId).first<{ n: number }>())!
    expect(n).toBe(1)
  })

  it('never moves scheduling backwards, whatever the arrival order', async () => {
    const newer = review('2026-09-21T10:00:00Z', '2026-09-25T00:00:00Z')
    const older = review('2026-09-20T10:00:00Z', '2030-01-01T00:00:00Z')
    await recordReviews(db(), [newer])
    await recordReviews(db(), [older])
    expect((await card()).due).toBe('2026-09-25T00:00:00Z')

    // Same pair in one batch, out of order.
    const later = review('2026-09-23T10:00:00Z', '2026-10-01T00:00:00Z')
    const earlier = review('2026-09-22T10:00:00Z', '2031-01-01T00:00:00Z')
    await recordReviews(db(), [later, earlier])
    expect((await card()).due).toBe('2026-10-01T00:00:00Z')
  })

  it('keeps the first introduction date', async () => {
    await recordReviews(db(), [review('2026-09-20T10:00:00Z', '2026-09-20T10:10:00Z')])
    await recordReviews(db(), [review('2026-09-21T10:00:00Z', '2026-09-25T00:00:00Z', { prior_state: 'learning' })])
    expect((await card()).introduced_at).toBe('2026-09-20T10:00:00Z')
  })

  it('reports reviews of deleted cards as missing and accepts the rest', async () => {
    const ghost = review('2026-09-20T10:00:00Z', '2026-09-21T00:00:00Z', { card_id: 'deleted' })
    const real = review('2026-09-20T10:00:00Z', '2026-09-21T00:00:00Z')
    expect(await recordReviews(db(), [ghost, real])).toEqual({ accepted: [real.id], missing: [ghost.id] })
  })

  it('counts retention only on graduated cards', async () => {
    const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
    await recordReviews(db(), [
      review(now, now, { prior_state: 'new', rating: 1 }),
      review(now, now, { prior_state: 'review', rating: 3 }),
      review(now, now, { prior_state: 'review', rating: 1 }),
    ])
    expect(await setStats(db(), setId)).toMatchObject({ reviews_30d: 3, retention_30d: 0.5 })
  })
})
