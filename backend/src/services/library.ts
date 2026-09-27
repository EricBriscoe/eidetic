import { NotFoundError } from '../errors'

const NOW = "strftime('%Y-%m-%dT%H:%M:%SZ','now')"
/** D1 caps bound parameters per statement at 100. */
const PARAM_CHUNK = 90

export type CardState = 'new' | 'learning' | 'review' | 'relearning'

export type SetRow = {
  id: string
  name: string
  description: string | null
  new_per_day: number
  created_at: string
  updated_at: string
}

export type CardRow = {
  id: string
  set_id: string
  front: string
  back: string
  position: number
  state: CardState
  step: number | null
  stability: number | null
  difficulty: number | null
  due: string | null
  last_review: string | null
  reps: number
  lapses: number
  introduced_at: string | null
  created_at: string
  updated_at: string
}

export type CardInput = { front: string; back: string }
export type SetInput = { name: string; description?: string | null; new_per_day?: number; cards?: CardInput[] }
export type SetPatch = { name?: string; description?: string | null; new_per_day?: number }
export type CardPatch = { card_id: string; front?: string; back?: string; reset_progress?: boolean }

export type SetSummary = SetRow & { card_count: number; new_count: number; due_count: number; learning_count: number }

export function chunk<T>(items: T[], size = PARAM_CHUNK): T[][] {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))
  return out
}

const SUMMARY_SQL = `
  SELECT s.*,
    COUNT(c.id) AS card_count,
    COALESCE(SUM(c.state = 'new'), 0) AS new_count,
    COALESCE(SUM(c.state != 'new' AND c.due <= ${NOW}), 0) AS due_count,
    COALESCE(SUM(c.state IN ('learning', 'relearning')), 0) AS learning_count
  FROM sets s LEFT JOIN cards c ON c.set_id = s.id`

export async function listSets(db: D1Database): Promise<SetSummary[]> {
  const { results } = await db.prepare(`${SUMMARY_SQL} GROUP BY s.id ORDER BY s.name COLLATE NOCASE`).all<SetSummary>()
  return results
}

export async function getSetSummary(db: D1Database, setId: string): Promise<SetSummary> {
  const row = await db.prepare(`${SUMMARY_SQL} WHERE s.id = ? GROUP BY s.id`).bind(setId).first<SetSummary>()
  if (!row) throw new NotFoundError(`no set ${setId}`)
  return row
}

export async function listCards(db: D1Database, setId: string): Promise<CardRow[]> {
  const { results } = await db.prepare('SELECT * FROM cards WHERE set_id = ? ORDER BY position').bind(setId).all<CardRow>()
  return results
}

/** Everything the app needs in one read: every set with every card. */
export async function library(db: D1Database): Promise<{ sets: (SetRow & { cards: CardRow[] })[] }> {
  const [sets, cards] = await db.batch([
    db.prepare('SELECT * FROM sets ORDER BY name COLLATE NOCASE'),
    db.prepare('SELECT * FROM cards ORDER BY set_id, position'),
  ])
  const bySet = new Map<string, CardRow[]>()
  for (const card of cards!.results as CardRow[]) {
    const list = bySet.get(card.set_id) ?? []
    list.push(card)
    bySet.set(card.set_id, list)
  }
  return { sets: (sets!.results as SetRow[]).map((s) => ({ ...s, cards: bySet.get(s.id) ?? [] })) }
}

function insertCardStmts(db: D1Database, setId: string, cards: CardInput[], startPosition: number) {
  return cards.map((card, i) =>
    db
      .prepare('INSERT INTO cards (id, set_id, front, back, position) VALUES (?, ?, ?, ?, ?)')
      .bind(crypto.randomUUID(), setId, card.front, card.back, startPosition + i),
  )
}

const touchSet = (db: D1Database, setId: string) =>
  db.prepare(`UPDATE sets SET updated_at = ${NOW} WHERE id = ?`).bind(setId)

export async function createSet(db: D1Database, input: SetInput): Promise<SetSummary> {
  const id = crypto.randomUUID()
  await db.batch([
    db
      .prepare('INSERT INTO sets (id, name, description, new_per_day) VALUES (?, ?, ?, ?)')
      .bind(id, input.name, input.description ?? null, input.new_per_day ?? 20),
    ...insertCardStmts(db, id, input.cards ?? [], 0),
  ])
  return getSetSummary(db, id)
}

export async function updateSet(db: D1Database, setId: string, patch: SetPatch): Promise<SetSummary> {
  const sets: string[] = []
  const binds: unknown[] = []
  for (const key of ['name', 'description', 'new_per_day'] as const) {
    if (patch[key] !== undefined) {
      sets.push(`${key} = ?`)
      binds.push(patch[key])
    }
  }
  const res = await db
    .prepare(`UPDATE sets SET ${[...sets, `updated_at = ${NOW}`].join(', ')} WHERE id = ?`)
    .bind(...binds, setId)
    .run()
  if (!res.meta.changes) throw new NotFoundError(`no set ${setId}`)
  return getSetSummary(db, setId)
}

export async function deleteSet(db: D1Database, setId: string): Promise<void> {
  const res = await db.prepare('DELETE FROM sets WHERE id = ?').bind(setId).run()
  if (!res.meta.changes) throw new NotFoundError(`no set ${setId}`)
}

/** Appends cards after the set's current last position. */
export async function addCards(db: D1Database, setId: string, cards: CardInput[]): Promise<CardRow[]> {
  const row = await db
    .prepare('SELECT (SELECT COALESCE(MAX(position) + 1, 0) FROM cards WHERE set_id = s.id) AS next FROM sets s WHERE s.id = ?')
    .bind(setId)
    .first<{ next: number }>()
  if (!row) throw new NotFoundError(`no set ${setId}`)
  const stmts = insertCardStmts(db, setId, cards, row.next)
  await db.batch([...stmts, touchSet(db, setId)])
  const { results } = await db
    .prepare('SELECT * FROM cards WHERE set_id = ? AND position >= ? ORDER BY position')
    .bind(setId, row.next)
    .all<CardRow>()
  return results
}

const RESET_PROGRESS =
  "state = 'new', step = NULL, stability = NULL, difficulty = NULL, due = NULL, last_review = NULL, reps = 0, lapses = 0, introduced_at = NULL"

/** Edits card text and/or resets scheduling. Content edits keep progress
 *  unless reset_progress is set — fixing a typo shouldn't restart a card. */
export async function updateCards(db: D1Database, patches: CardPatch[]): Promise<CardRow[]> {
  const ids = patches.map((p) => p.card_id)
  const existing = await cardSets(db, ids)
  const missing = ids.filter((id) => !existing.has(id))
  if (missing.length) throw new NotFoundError(`no cards ${missing.join(', ')}`)

  const stmts = patches.map((p) => {
    const cols: string[] = []
    const binds: unknown[] = []
    if (p.front !== undefined) cols.push('front = ?'), binds.push(p.front)
    if (p.back !== undefined) cols.push('back = ?'), binds.push(p.back)
    if (p.reset_progress) cols.push(RESET_PROGRESS)
    cols.push(`updated_at = ${NOW}`)
    return db.prepare(`UPDATE cards SET ${cols.join(', ')} WHERE id = ?`).bind(...binds, p.card_id)
  })
  const touched = [...new Set(existing.values())].map((setId) => touchSet(db, setId))
  await db.batch([...stmts, ...touched])
  return getCards(db, ids)
}

export async function resetSetProgress(db: D1Database, setId: string): Promise<SetSummary> {
  await getSetSummary(db, setId)
  await db.batch([
    db.prepare(`UPDATE cards SET ${RESET_PROGRESS}, updated_at = ${NOW} WHERE set_id = ?`).bind(setId),
    touchSet(db, setId),
  ])
  return getSetSummary(db, setId)
}

export async function deleteCards(db: D1Database, cardIds: string[]): Promise<{ deleted: string[]; missing: string[] }> {
  const existing = await cardSets(db, cardIds)
  const deleted = cardIds.filter((id) => existing.has(id))
  const stmts = chunk(deleted).map((ids) =>
    db.prepare(`DELETE FROM cards WHERE id IN (${ids.map(() => '?').join(',')})`).bind(...ids),
  )
  const touched = [...new Set(existing.values())].map((setId) => touchSet(db, setId))
  if (stmts.length) await db.batch([...stmts, ...touched])
  return { deleted, missing: cardIds.filter((id) => !existing.has(id)) }
}

/** card id → set id, for the ids that exist. */
async function cardSets(db: D1Database, cardIds: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>()
  for (const ids of chunk([...new Set(cardIds)])) {
    const { results } = await db
      .prepare(`SELECT id, set_id FROM cards WHERE id IN (${ids.map(() => '?').join(',')})`)
      .bind(...ids)
      .all<{ id: string; set_id: string }>()
    for (const r of results) out.set(r.id, r.set_id)
  }
  return out
}

async function getCards(db: D1Database, cardIds: string[]): Promise<CardRow[]> {
  const out: CardRow[] = []
  for (const ids of chunk(cardIds)) {
    const { results } = await db
      .prepare(`SELECT * FROM cards WHERE id IN (${ids.map(() => '?').join(',')})`)
      .bind(...ids)
      .all<CardRow>()
    out.push(...results)
  }
  const order = new Map(cardIds.map((id, i) => [id, i]))
  return out.sort((a, b) => order.get(a.id)! - order.get(b.id)!)
}

/** Review history for one set: how the learner is actually doing. */
export async function setStats(db: D1Database, setId: string) {
  const row = await db
    .prepare(
      `SELECT
        COUNT(*) AS reviews_30d,
        COALESCE(SUM(r.reviewed_at >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-7 days')), 0) AS reviews_7d,
        -- True retention: pass rate on graduated cards, excluding learning steps.
        AVG(CASE WHEN r.prior_state = 'review' THEN r.rating > 1 END) AS retention_30d,
        MAX(r.reviewed_at) AS last_reviewed_at
      FROM reviews r JOIN cards c ON c.id = r.card_id
      WHERE c.set_id = ? AND r.reviewed_at >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 days')`,
    )
    .bind(setId)
    .first<{ reviews_30d: number; reviews_7d: number; retention_30d: number | null; last_reviewed_at: string | null }>()
  return row!
}
