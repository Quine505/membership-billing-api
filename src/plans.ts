import type { Hono } from 'hono'
import { COUNTRIES, isCountry } from './countries.ts'
import { ApiError, isInt, readBody, validation } from './http.ts'
import type { Plan, Store } from './store.ts'

export function planRoutes(app: Hono, store: Store) {
  app.post('/plans', async (c) => {
    const { id, country, monthly, joining_fee } = await readBody(c)

    if (typeof id !== 'string' || id === '') throw validation('id must be a non-empty string')
    if (!isCountry(country)) throw validation('country must be AE, SA or BH')
    if (!isInt(monthly, 1)) throw validation('monthly must be an integer above 0')
    if (!isInt(joining_fee, 0)) throw validation('joining_fee must be an integer of 0 or more')

    // No await between this check and the insert, so two racing requests cannot both pass.
    if (store.plans.has(id)) throw new ApiError(409, 'PLAN_EXISTS', 'a plan with this id already exists')
    const plan: Plan = { id, country, currency: COUNTRIES[country].currency, monthly, joining_fee }
    store.plans.set(id, plan)
    return c.json(plan, 201)
  })
}
