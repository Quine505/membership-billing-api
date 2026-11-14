import type { Hono } from 'hono'
import { dayNumber, parseDate } from './dates.ts'
import { ApiError, isInt, readBody, validation } from './http.ts'
import { invoicesBetween } from './schedule.ts'
import type { Agreement, Store } from './store.ts'

export function agreementRoutes(app: Hono, store: Store) {
  app.post('/agreements', async (c) => {
    const { member_id, plan_id, start_date, due_day } = await readBody(c)

    if (typeof member_id !== 'string') throw validation('member_id must be a string')
    if (typeof plan_id !== 'string') throw validation('plan_id must be a string')
    if (typeof start_date !== 'string' || !parseDate(start_date)) throw validation('start_date must be YYYY-MM-DD')
    if (!isInt(due_day, 1) || due_day > 31) throw validation('due_day must be an integer from 1 to 31')

    const member = store.members.get(member_id)
    if (!member) throw new ApiError(422, 'UNKNOWN_MEMBER', 'no member has this id')
    const plan = store.plans.get(plan_id)
    if (!plan) throw new ApiError(422, 'UNKNOWN_PLAN', 'no plan has this id')
    if (plan.country !== member.country) {
      throw new ApiError(422, 'PLAN_COUNTRY_MISMATCH', 'the plan and the member are in different countries')
    }

    const agreement: Agreement = { id: crypto.randomUUID(), member_id, plan_id, start_date, due_day }
    store.agreements.set(agreement.id, agreement)
    return c.json(agreement, 201)
  })

  app.get('/agreements/:id/invoices', (c) => {
    const agreement = store.agreements.get(c.req.param('id'))
    if (!agreement) throw new ApiError(404, 'NOT_FOUND', 'no agreement has this id')

    const from = parseDate(c.req.query('from'))
    const to = parseDate(c.req.query('to'))
    if (!from) throw validation('from must be YYYY-MM-DD')
    if (!to) throw validation('to must be YYYY-MM-DD')
    const span = dayNumber(to) - dayNumber(from)
    if (span < 0 || span > 366) {
      throw new ApiError(422, 'INVALID_RANGE', 'to must be on or after from, and at most 366 days after it')
    }

    // Plans are never deleted, so the agreement's plan always exists.
    const plan = store.plans.get(agreement.plan_id)!
    return c.json(invoicesBetween(agreement, plan, from, to))
  })
}
