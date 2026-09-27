import { z } from 'zod'

export const cardState = z.enum(['new', 'learning', 'review', 'relearning'])

/** Second-resolution UTC, the one timestamp format stored anywhere — string
 *  comparison in SQL depends on it. */
const isoTimestamp = z
  .string()
  .datetime({ offset: false })
  .transform((s) => new Date(s).toISOString().replace(/\.\d{3}Z$/, 'Z'))

/** Swift's JSONEncoder omits nil optionals rather than writing null. */
const orNull = <T extends z.ZodTypeAny>(t: T) => t.nullish().transform((v) => v ?? null)

export const reviewsBody = z.object({
  reviews: z
    .array(
      z.object({
        id: z.string().uuid(),
        card_id: z.string().min(1).max(64),
        rating: z.union([z.literal(1), z.literal(2), z.literal(3), z.literal(4)]),
        reviewed_at: isoTimestamp,
        duration_ms: z.number().int().min(0).max(86_400_000).nullish(),
        prior_state: cardState,
        card: z.object({
          state: cardState,
          step: orNull(z.number().int().min(0).max(100)),
          stability: orNull(z.number().positive().max(1e6)),
          difficulty: orNull(z.number().min(1).max(10)),
          due: orNull(isoTimestamp),
          reps: z.number().int().min(0),
          lapses: z.number().int().min(0),
          introduced_at: orNull(isoTimestamp),
        }),
      }),
    )
    .max(1000),
})
