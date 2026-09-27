import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { z } from 'zod'
import { NotFoundError } from './errors'
import {
  addCards,
  createSet,
  deleteCards,
  deleteSet,
  getSetSummary,
  listCards,
  listSets,
  resetSetProgress,
  setStats,
  updateCards,
  updateSet,
  type CardRow,
} from './services/library'

const INSTRUCTIONS = `Eidetic is the user's personal flashcard app. You manage the content: sets of front/back cards.
The iOS app schedules reviews with FSRS spaced repetition; you never schedule cards, but you can read progress to spot weak cards (high lapses/difficulty) and rewrite or split them.
Write atomic cards: one fact per card, a short prompt on the front, a minimal answer on the back. Both sides render inline Markdown (**bold**, *italic*, \`code\`) and newlines.`

const cardText = z.string().trim().min(1).max(4000)
const cardInput = z.object({
  front: cardText.describe('Prompt/question side'),
  back: cardText.describe('Answer side'),
})
const setName = z.string().trim().min(1).max(120)
const description = z.string().trim().max(1000)
const newPerDay = z.number().int().min(0).max(1000).describe('Max new cards introduced per day in the app (default 20)')

const json = (data: unknown) => ({ content: [{ type: 'text' as const, text: JSON.stringify(data) }] })
const failure = (message: string) => ({ content: [{ type: 'text' as const, text: JSON.stringify({ error: message }) }], isError: true })

/** Tool errors the model can act on (bad ids) come back as isError results, not protocol errors. */
function tool<A>(fn: (args: A) => Promise<unknown>) {
  return async (args: A) => {
    try {
      return json(await fn(args))
    } catch (err) {
      if (err instanceof NotFoundError) return failure(err.message)
      throw err
    }
  }
}

/** Compact card for the model: content plus just enough scheduling to judge progress. */
function cardView(c: CardRow, includeProgress: boolean) {
  const base = { id: c.id, front: c.front, back: c.back }
  if (!includeProgress) return base
  return {
    ...base,
    state: c.state,
    due: c.due,
    reps: c.reps,
    lapses: c.lapses,
    difficulty: c.difficulty == null ? null : Math.round(c.difficulty * 10) / 10,
    stability_days: c.stability == null ? null : Math.round(c.stability * 10) / 10,
  }
}

export function buildMcpServer(db: D1Database): McpServer {
  const server = new McpServer({ name: 'eidetic', version: '1.0.0' }, { instructions: INSTRUCTIONS })

  server.registerTool(
    'list_sets',
    {
      title: 'List flashcard sets',
      description: 'All flashcard sets with card counts: total, new (never studied), due now, and in learning.',
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    tool(async () => listSets(db)),
  )

  server.registerTool(
    'get_set',
    {
      title: 'Get a flashcard set',
      description:
        'One set with its cards (in order) and 30-day review stats. retention_30d is the pass rate on graduated cards. Per card: state, due, reps, lapses (times forgotten), difficulty (1-10), stability_days.',
      inputSchema: {
        set_id: z.string(),
        include_progress: z.boolean().optional().describe('Include per-card scheduling fields (default true)'),
      },
      annotations: { readOnlyHint: true },
    },
    tool(async ({ set_id, include_progress }: { set_id: string; include_progress?: boolean }) => {
      const [set, cards, stats] = await Promise.all([getSetSummary(db, set_id), listCards(db, set_id), setStats(db, set_id)])
      return { ...set, stats, cards: cards.map((c) => cardView(c, include_progress ?? true)) }
    }),
  )

  server.registerTool(
    'create_set',
    {
      title: 'Create a flashcard set',
      description: 'Creates a set, optionally with its initial cards. It appears in the app on next refresh.',
      inputSchema: {
        name: setName,
        description: description.optional(),
        new_per_day: newPerDay.optional(),
        cards: z.array(cardInput).max(500).optional(),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    },
    tool(async (args: { name: string; description?: string; new_per_day?: number; cards?: z.infer<typeof cardInput>[] }) =>
      createSet(db, args),
    ),
  )

  server.registerTool(
    'update_set',
    {
      title: 'Update a flashcard set',
      description: 'Renames a set or changes its description or daily new-card limit. Pass only the fields to change; description null clears it.',
      inputSchema: {
        set_id: z.string(),
        name: setName.optional(),
        description: description.nullable().optional(),
        new_per_day: newPerDay.optional(),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
    },
    tool(async ({ set_id, ...patch }: { set_id: string; name?: string; description?: string | null; new_per_day?: number }) =>
      updateSet(db, set_id, patch),
    ),
  )

  server.registerTool(
    'delete_set',
    {
      title: 'Delete a flashcard set',
      description: 'Permanently deletes a set, its cards, and their review history. Confirm with the user first.',
      inputSchema: { set_id: z.string() },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true },
    },
    tool(async ({ set_id }: { set_id: string }) => {
      await deleteSet(db, set_id)
      return { deleted: set_id }
    }),
  )

  server.registerTool(
    'add_cards',
    {
      title: 'Add cards',
      description: 'Appends cards to the end of a set. New cards start unstudied.',
      inputSchema: { set_id: z.string(), cards: z.array(cardInput).min(1).max(500) },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    },
    tool(async ({ set_id, cards }: { set_id: string; cards: z.infer<typeof cardInput>[] }) => ({
      added: (await addCards(db, set_id, cards)).map((c) => cardView(c, false)),
    })),
  )

  server.registerTool(
    'update_cards',
    {
      title: 'Edit cards',
      description:
        "Edits card text by id. Review progress is kept unless reset_progress is true — reset when the card's meaning changes, not for typo fixes.",
      inputSchema: {
        cards: z
          .array(
            z.object({
              card_id: z.string(),
              front: cardText.optional(),
              back: cardText.optional(),
              reset_progress: z.boolean().optional().describe('Restart this card as never studied'),
            }),
          )
          .min(1)
          .max(500),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
    },
    tool(async ({ cards }: { cards: { card_id: string; front?: string; back?: string; reset_progress?: boolean }[] }) => ({
      updated: (await updateCards(db, cards)).map((c) => cardView(c, true)),
    })),
  )

  server.registerTool(
    'delete_cards',
    {
      title: 'Delete cards',
      description: 'Permanently deletes cards (and their review history) by id.',
      inputSchema: { card_ids: z.array(z.string()).min(1).max(500) },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true },
    },
    tool(async ({ card_ids }: { card_ids: string[] }) => deleteCards(db, card_ids)),
  )

  server.registerTool(
    'reset_set_progress',
    {
      title: 'Reset set progress',
      description: 'Marks every card in a set as never studied. Review history is kept. Confirm with the user first.',
      inputSchema: { set_id: z.string() },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true },
    },
    tool(async ({ set_id }: { set_id: string }) => resetSetProgress(db, set_id)),
  )

  return server
}
