import { chunk, type CardState } from './library'

export type ReviewInput = {
  id: string
  card_id: string
  rating: 1 | 2 | 3 | 4
  reviewed_at: string
  duration_ms?: number | null
  prior_state: CardState
  /** Scheduling the app computed (FSRS runs on-device); stored verbatim. */
  card: {
    state: CardState
    step: number | null
    stability: number | null
    difficulty: number | null
    due: string | null
    reps: number
    lapses: number
    introduced_at: string | null
  }
}

/** Records reviews from the app's outbox. Idempotent on review id. A card's
 *  scheduling only moves forward: an older review replayed after a newer one
 *  (or after an MCP progress reset older than it) is logged but doesn't
 *  overwrite. Reviews of deleted cards come back in `missing` so the app can
 *  drop them. */
export async function recordReviews(
  db: D1Database,
  reviews: ReviewInput[],
): Promise<{ accepted: string[]; missing: string[] }> {
  const exists = new Set<string>()
  for (const ids of chunk([...new Set(reviews.map((r) => r.card_id))])) {
    const { results } = await db
      .prepare(`SELECT id FROM cards WHERE id IN (${ids.map(() => '?').join(',')})`)
      .bind(...ids)
      .all<{ id: string }>()
    for (const r of results) exists.add(r.id)
  }
  const accepted = reviews.filter((r) => exists.has(r.card_id))
  const missing = reviews.filter((r) => !exists.has(r.card_id)).map((r) => r.id)

  const sorted = [...accepted].sort((a, b) => a.reviewed_at.localeCompare(b.reviewed_at))
  const stmts = sorted.flatMap((r) => [
    db
      .prepare(
        `INSERT OR IGNORE INTO reviews (id, card_id, rating, reviewed_at, duration_ms, prior_state, state, stability, difficulty, due)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(r.id, r.card_id, r.rating, r.reviewed_at, r.duration_ms ?? null, r.prior_state, r.card.state, r.card.stability, r.card.difficulty, r.card.due),
    db
      .prepare(
        `UPDATE cards SET state = ?, step = ?, stability = ?, difficulty = ?, due = ?, last_review = ?,
           reps = ?, lapses = ?, introduced_at = COALESCE(introduced_at, ?)
         WHERE id = ? AND (last_review IS NULL OR last_review <= ?)`,
      )
      .bind(
        r.card.state, r.card.step, r.card.stability, r.card.difficulty, r.card.due, r.reviewed_at,
        r.card.reps, r.card.lapses, r.card.introduced_at, r.card_id, r.reviewed_at,
      ),
  ])
  if (stmts.length) await db.batch(stmts)
  return { accepted: accepted.map((r) => r.id), missing }
}
