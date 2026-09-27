import type { Context } from 'hono'
import { HTTPException } from 'hono/http-exception'
import type { ZodError, ZodTypeAny, z } from 'zod'

export class ValidationError extends Error {
  constructor(public zodError: ZodError) {
    super('validation failed')
  }
}

/** Thrown by services for ids that don't exist; mapped to 404 (REST) or an MCP tool error. */
export class NotFoundError extends Error {}

/** Parse and validate a JSON body; throws ValidationError → mapped to 400 in onError. */
export async function readJson<S extends ZodTypeAny>(c: Context, schema: S): Promise<z.infer<S>> {
  let raw: unknown
  try {
    raw = await c.req.json()
  } catch {
    throw new ValidationError({ issues: [{ message: 'body must be JSON' }] } as unknown as ZodError)
  }
  const parsed = schema.safeParse(raw)
  if (!parsed.success) throw new ValidationError(parsed.error)
  return parsed.data
}

export function errorResponse(err: Error, c: Context): Response {
  if (err instanceof HTTPException) return err.getResponse()
  if (err instanceof ValidationError) return c.json({ error: 'invalid_body', issues: err.zodError.issues }, 400)
  if (err instanceof NotFoundError) return c.json({ error: 'not_found', detail: err.message }, 404)
  console.error('unhandled error:', err)
  return c.json({ error: 'internal' }, 500)
}
