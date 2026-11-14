import { Hono } from 'hono'
import { agreementRoutes } from './routes/agreements.ts'
import { ApiError } from './http.ts'
import { memberRoutes } from './routes/members.ts'
import { planRoutes } from './routes/plans.ts'
import { reconciliationRoutes } from './routes/reconciliation.ts'
import { createStore } from './store.ts'

// Each call builds an app with its own empty store, so tests never share state.
export function createApp() {
  const app = new Hono()
  const store = createStore()

  app.get('/health', (c) => c.json({ status: 'ok' }))
  memberRoutes(app, store)
  planRoutes(app, store)
  agreementRoutes(app, store)
  reconciliationRoutes(app, store)

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
