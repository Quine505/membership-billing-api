import type { Context } from 'hono'

// Thrown anywhere in a handler. app.ts turns it into the error JSON.
export class ApiError extends Error {
  status: 404 | 409 | 422
  code: string
  extra: Record<string, unknown>

  constructor(status: 404 | 409 | 422, code: string, message: string, extra: Record<string, unknown> = {}) {
    super(message)
    this.status = status
    this.code = code
    this.extra = extra
  }
}

export function validation(message: string): ApiError {
  return new ApiError(422, 'VALIDATION', message)
}

// A whole number that JSON carries exactly, at or above `min`.
export function isInt(value: unknown, min: number): value is number {
  return Number.isSafeInteger(value) && (value as number) >= min
}

export async function readBody(c: Context): Promise<Record<string, unknown>> {
  const body: unknown = await c.req.json().catch(() => null)
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw validation('body must be a JSON object')
  }
  return body as Record<string, unknown>
}
