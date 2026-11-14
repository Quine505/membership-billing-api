import { Hono } from 'hono'
import { ApiError } from './http.ts'

// Each call builds a fresh app, so tests never share state.
export function createApp() {
  const app = new Hono()

  app.get('/health', (c) => c.json({ status: 'ok' }))

  app.notFound((c) => c.json({ error: { code: 'NOT_FOUND', message: 'no such route' } }, 404))
  app.onError((err, c) => {
    if (err instanceof ApiError) {
      return c.json({ error: { code: err.code, message: err.message, ...err.extra } }, err.status)
    }
    console.error(err)
    return c.json({ error: { code: 'INTERNAL', message: 'internal error' } }, 500)
  })

  return app
}
