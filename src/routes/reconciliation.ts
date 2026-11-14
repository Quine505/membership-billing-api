import type { Hono } from 'hono'
import { parseDate, parseMonth, type Day } from '../domain/dates.ts'
import { ApiError, isInt, readBody, validation } from '../http.ts'
import { invoicesBetween, type Invoice } from '../domain/schedule.ts'
import type { Store } from '../store.ts'

type Row = {
  gateway_txn_id: string
  agreement_id: string
  amount: number
  currency: string
  status: 'SETTLED' | 'DECLINED'
  attempted_on: string
}

type Verdict = 'MATCHED' | 'DUE_DAY_DRIFT' | 'DOUBLE_CHARGE_RISK' | 'MISSING_FROM_LEDGER' | 'DECLINED'

// Shape checks only. A row that fails here is malformed input: 422 VALIDATION.
function parseRow(value: unknown): Row {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw validation('each row must be an object')
  const { gateway_txn_id, agreement_id, amount, currency, status, attempted_on } = value as Record<string, unknown>

  if (typeof gateway_txn_id !== 'string' || gateway_txn_id === '') throw validation('gateway_txn_id must be a non-empty string')
  if (typeof agreement_id !== 'string') throw validation('agreement_id must be a string')
  if (!isInt(amount, 1)) throw validation('amount must be a positive integer')
  if (typeof currency !== 'string') throw validation('currency must be a string')
  if (status !== 'SETTLED' && status !== 'DECLINED') throw validation('status must be SETTLED or DECLINED')
  if (typeof attempted_on !== 'string' || !parseDate(attempted_on)) throw validation('attempted_on must be YYYY-MM-DD')

  return { gateway_txn_id, agreement_id, amount, currency, status, attempted_on }
}

// The three row rules. Returns one entry per offending row and code.
function rowErrors(store: Store, month: string, rows: Row[]) {
  const timesSeen = new Map<string, number>()
  for (const row of rows) timesSeen.set(row.gateway_txn_id, (timesSeen.get(row.gateway_txn_id) ?? 0) + 1)

  const errors: { gateway_txn_id: string; code: string }[] = []
  for (const row of rows) {
    const add = (code: string) => errors.push({ gateway_txn_id: row.gateway_txn_id, code })

    if (timesSeen.get(row.gateway_txn_id)! > 1) add('DUPLICATE_TXN')
    // Both strings are validated, so the first 7 characters of the date are its YYYY-MM.
    if (row.attempted_on.slice(0, 7) !== month) add('ROW_OUTSIDE_MONTH')
    const agreement = store.agreements.get(row.agreement_id)
    if (agreement && store.plans.get(agreement.plan_id)!.currency !== row.currency) add('CURRENCY_MISMATCH')
  }
  return errors
}

function reconcile(store: Store, from: Day, to: Day, rows: Row[]) {
  // Expected invoices: every invoice of every agreement that is due in the month.
  const expected = new Map<string, Invoice[]>()
  for (const agreement of store.agreements.values()) {
    expected.set(agreement.id, invoicesBetween(agreement, store.plans.get(agreement.plan_id)!, from, to))
  }

  // Each settled row links to one invoice or to none. The choice looks only at the row itself,
  // never at other rows, so the order of rows cannot change it.
  const links = rows.map((row) => {
    if (row.status !== 'SETTLED') return null
    const candidates = (expected.get(row.agreement_id) ?? []).filter((i) => Math.abs(i.total - row.amount) <= 1)
    // invoicesBetween returns invoices in due-date order, so the first candidate is the earliest.
    return candidates[0] ?? null
  })

  const linkCount = new Map<Invoice, number>()
  for (const invoice of links) if (invoice) linkCount.set(invoice, (linkCount.get(invoice) ?? 0) + 1)

  const summary: Record<Verdict, number> = { MATCHED: 0, DUE_DAY_DRIFT: 0, DOUBLE_CHARGE_RISK: 0, MISSING_FROM_LEDGER: 0, DECLINED: 0 }
  const verdicts = rows.map((row, index) => {
    const invoice = links[index]
    let verdict: Verdict
    if (row.status === 'DECLINED') verdict = 'DECLINED'
    else if (!invoice) verdict = 'MISSING_FROM_LEDGER'
    else if (linkCount.get(invoice)! > 1) verdict = 'DOUBLE_CHARGE_RISK'
    else verdict = row.attempted_on === invoice.due_date ? 'MATCHED' : 'DUE_DAY_DRIFT'

    summary[verdict]++
    return {
      gateway_txn_id: row.gateway_txn_id,
      verdict,
      invoice: invoice ? { agreement_id: row.agreement_id, invoice_no: invoice.invoice_no } : null,
    }
  })

  const unmatched_invoices = []
  for (const [agreement_id, invoices] of expected) {
    for (const invoice of invoices) {
      if (linkCount.has(invoice)) continue
      const { invoice_no, due_date, total, currency } = invoice
      unmatched_invoices.push({ agreement_id, invoice_no, due_date, total, currency })
    }
  }
  const compare = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0)
  unmatched_invoices.sort(
    (a, b) => compare(a.due_date, b.due_date) || compare(a.agreement_id, b.agreement_id) || a.invoice_no - b.invoice_no,
  )

  return { summary, rows: verdicts, unmatched_invoices }
}

export function reconciliationRoutes(app: Hono, store: Store) {
  app.post('/reconciliation/runs', async (c) => {
    const body = await readBody(c)

    const month = parseMonth(body.month)
    if (!month) throw validation('month must be YYYY-MM')
    if (!Array.isArray(body.rows)) throw validation('rows must be an array')
    const rows = body.rows.map(parseRow)

    const errors = rowErrors(store, body.month as string, rows)
    if (errors.length > 0) throw new ApiError(422, 'INVALID_ROWS', 'some rows break the row rules', { errors })

    const run = { id: crypto.randomUUID(), month: body.month, ...reconcile(store, month.from, month.to, rows) }
    store.runs.set(run.id, run)
    return c.json(run, 201)
  })

  app.get('/reconciliation/runs/:id', (c) => {
    const run = store.runs.get(c.req.param('id'))
    if (!run) throw new ApiError(404, 'NOT_FOUND', 'no run has this id')
    return c.json(run)
  })
}
