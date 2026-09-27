import { env } from 'cloudflare:test'
import { describe, expect, it } from 'vitest'
import { NotFoundError } from '../src/errors'
import {
  addCards, createSet, deleteCards, deleteSet, getSetSummary, library, listCards, resetSetProgress, updateCards, updateSet,
} from '../src/services/library'

const db = () => env.DB
const cards = (n: number, prefix = 'q') => Array.from({ length: n }, (_, i) => ({ front: `${prefix}${i}`, back: `a${i}` }))

async function study(cardId: string, due: string) {
  await db()
    .prepare("UPDATE cards SET state = 'review', stability = 3, difficulty = 5, due = ?, last_review = '2026-01-01T00:00:00Z', reps = 2 WHERE id = ?")
    .bind(due, cardId)
    .run()
}

describe('library', () => {
  it('creates a set with cards in order and summary counts', async () => {
    const set = await createSet(db(), { name: 'Spanish', cards: cards(3) })
    expect(set).toMatchObject({ name: 'Spanish', new_per_day: 20, card_count: 3, new_count: 3, due_count: 0 })
    const list = await listCards(db(), set.id)
    expect(list.map((c) => [c.front, c.position])).toEqual([['q0', 0], ['q1', 1], ['q2', 2]])

    await study(list[0]!.id, '2000-01-01T00:00:00Z')
    await study(list[1]!.id, '2999-01-01T00:00:00Z')
    expect(await getSetSummary(db(), set.id)).toMatchObject({ new_count: 1, due_count: 1 })
  })

  it('appends cards after the current last position', async () => {
    const set = await createSet(db(), { name: 'append', cards: cards(2) })
    await deleteCards(db(), [(await listCards(db(), set.id))[0]!.id])
    const added = await addCards(db(), set.id, cards(2, 'new'))
    expect(added.map((c) => [c.front, c.position])).toEqual([['new0', 2], ['new1', 3]])
  })

  it('keeps progress on text edits and clears it on reset', async () => {
    const set = await createSet(db(), { name: 'edits', cards: cards(2) })
    const [a, b] = await listCards(db(), set.id)
    await study(a!.id, '2999-01-01T00:00:00Z')
    await study(b!.id, '2999-01-01T00:00:00Z')

    const [edited] = await updateCards(db(), [{ card_id: a!.id, back: 'fixed typo' }])
    expect(edited).toMatchObject({ back: 'fixed typo', front: 'q0', state: 'review', reps: 2 })

    const [reset] = await updateCards(db(), [{ card_id: a!.id, reset_progress: true }])
    expect(reset).toMatchObject({ state: 'new', reps: 0, stability: null, due: null, last_review: null })

    expect(await resetSetProgress(db(), set.id)).toMatchObject({ new_count: 2 })
  })

  it('updates set fields selectively; null clears the description', async () => {
    const set = await createSet(db(), { name: 'old', description: 'desc', new_per_day: 5 })
    expect(await updateSet(db(), set.id, { name: 'new' })).toMatchObject({ name: 'new', description: 'desc', new_per_day: 5 })
    expect(await updateSet(db(), set.id, { description: null })).toMatchObject({ description: null })
  })

  it('reports missing ids', async () => {
    await expect(updateSet(db(), 'nope', { name: 'x' })).rejects.toBeInstanceOf(NotFoundError)
    await expect(addCards(db(), 'nope', cards(1))).rejects.toBeInstanceOf(NotFoundError)
    await expect(updateCards(db(), [{ card_id: 'nope', front: 'x' }])).rejects.toBeInstanceOf(NotFoundError)
    expect(await deleteCards(db(), ['nope'])).toEqual({ deleted: [], missing: ['nope'] })
  })

  it('deleting a set cascades to its cards', async () => {
    const set = await createSet(db(), { name: 'doomed', cards: cards(2) })
    await deleteSet(db(), set.id)
    expect((await library(db())).sets.find((s) => s.id === set.id)).toBeUndefined()
    expect(await listCards(db(), set.id)).toEqual([])
    await expect(deleteSet(db(), set.id)).rejects.toBeInstanceOf(NotFoundError)
  })

  it('handles more ids than one statement can bind', async () => {
    const set = await createSet(db(), { name: 'bulk', cards: cards(250) })
    const ids = (await listCards(db(), set.id)).map((c) => c.id)
    expect((await updateCards(db(), ids.map((card_id) => ({ card_id, back: 'b' })))).length).toBe(250)
    expect((await deleteCards(db(), ids)).deleted.length).toBe(250)
  })
})
