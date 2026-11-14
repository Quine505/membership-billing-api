import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createApp } from '../src/app.ts'
import { create, expectError, post, PHONES } from './helpers.ts'

// Three agreements. Their invoices due in October 2026, worked out by hand:
//   sa#2  due 2026-10-01  total 34385 SAR   (29900 + 15%)
//   bh#2  due 2026-10-01  total 26950 BHD   (24500 + 10%)
//   ae#1  due 2026-10-05  total  3257 AED   (3100 × 15/30 = 1550, + fee 1552 = 3102, + 5% = 155)
//   ae#2  due 2026-10-20  total  3255 AED   (3100 + 5% = 155)
// The AE agreement has two invoices in one month, two minor units apart, for the candidate rules.
async function seeded() {
  const app = createApp()
  const ids: Record<string, string> = {}
  const add = async (key: 'sa' | 'bh' | 'ae', country: string, monthly: number, fee: number, start: string, dueDay: number) => {
    const member = await create(app, '/members', { name: key, country, phone: PHONES[country as keyof typeof PHONES] })
    await create(app, '/plans', { id: key, country, monthly, joining_fee: fee })
    const agreement = await create(app, '/agreements', { member_id: member.id, plan_id: key, start_date: start, due_day: dueDay })
    ids[key] = agreement.id
  }
  await add('sa', 'SA', 29900, 0, '2026-09-20', 1)
  await add('bh', 'BH', 24500, 0, '2026-09-15', 1)
  await add('ae', 'AE', 3100, 1552, '2026-10-05', 20)
  return { app, ids }
}

const CURRENCY: Record<string, string> = { sa: 'SAR', bh: 'BHD', ae: 'AED' }

// A row in short form: "txn agreement amount day [DECLINED] [currency]".
// The agreement is sa, bh, ae, or any other word for an agreement that does not exist.
function row(ids: Record<string, string>, short: string) {
  const [txn, key, amount, day, ...rest] = short.split(' ') as [string, string, string, string, ...string[]]
  const declined = rest.includes('DECLINED')
  const currency = rest.find((word) => word !== 'DECLINED') ?? CURRENCY[key] ?? 'SAR'
  return {
    gateway_txn_id: txn,
    agreement_id: ids[key] ?? key,
    amount: Number(amount),
    currency,
    status: declined ? 'DECLINED' : 'SETTLED',
    attempted_on: day.length === 2 ? `2026-10-${day}` : day,
  }
}

// One result row as text: "txn VERDICT sa#2", or "txn VERDICT null".
function verdictLine(ids: Record<string, string>, r: any): string {
  const name = (id: string) => Object.keys(ids).find((key) => ids[key] === id) ?? id
  return `${r.gateway_txn_id} ${r.verdict} ${r.invoice ? `${name(r.invoice.agreement_id)}#${r.invoice.invoice_no}` : 'null'}`
}

// Unmatched invoices as a set of "sa#2" names. Their order is tested separately.
function unmatchedNames(ids: Record<string, string>, run: any): string[] {
  const name = (id: string) => Object.keys(ids).find((key) => ids[key] === id)
  return run.unmatched_invoices.map((i: any) => `${name(i.agreement_id)}#${i.invoice_no}`).sort()
}

type Case = { rule: string; month?: string; rows: string[]; expect: string[]; unmatched: string[] }

const CASES: Case[] = [
  // --- The verdict table ---
  {
    rule: 'spec example: one settled on the due date, one declined',
    rows: ['T1 sa 34385 01', 'T2 bh 26950 02 DECLINED'],
    expect: ['T1 MATCHED sa#2', 'T2 DECLINED null'],
    unmatched: ['ae#1', 'ae#2', 'bh#2'],
  },
  {
    rule: 'DUE_DAY_DRIFT: the only row on its invoice, attempted on another day',
    rows: ['T1 sa 34385 03'],
    expect: ['T1 DUE_DAY_DRIFT sa#2'],
    unmatched: ['ae#1', 'ae#2', 'bh#2'],
  },
  {
    rule: 'DUE_DAY_DRIFT also for the last day of the month',
    rows: ['T1 sa 34385 31'],
    expect: ['T1 DUE_DAY_DRIFT sa#2'],
    unmatched: ['ae#1', 'ae#2', 'bh#2'],
  },
  {
    rule: 'DOUBLE_CHARGE_RISK: two settled rows on one invoice, even the one on the due date',
    rows: ['T1 sa 34385 01', 'T2 sa 34385 02'],
    expect: ['T1 DOUBLE_CHARGE_RISK sa#2', 'T2 DOUBLE_CHARGE_RISK sa#2'],
    unmatched: ['ae#1', 'ae#2', 'bh#2'],
  },
  {
    rule: 'DOUBLE_CHARGE_RISK: three rows, with amounts one below, exact and one above',
    rows: ['T1 sa 34384 01', 'T2 sa 34385 01', 'T3 sa 34386 09'],
    expect: ['T1 DOUBLE_CHARGE_RISK sa#2', 'T2 DOUBLE_CHARGE_RISK sa#2', 'T3 DOUBLE_CHARGE_RISK sa#2'],
    unmatched: ['ae#1', 'ae#2', 'bh#2'],
  },
  {
    rule: 'a declined row takes no part: settled + declined on one invoice is MATCHED, not a double charge',
    rows: ['T1 sa 34385 01', 'T2 sa 34385 01 DECLINED'],
    expect: ['T1 MATCHED sa#2', 'T2 DECLINED null'],
    unmatched: ['ae#1', 'ae#2', 'bh#2'],
  },
  {
    rule: 'an invoice whose only rows were declined is unmatched',
    rows: ['T1 sa 34385 01 DECLINED', 'T2 sa 34385 02 DECLINED'],
    expect: ['T1 DECLINED null', 'T2 DECLINED null'],
    unmatched: ['ae#1', 'ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: 'MISSING_FROM_LEDGER: unknown agreement, whatever its currency',
    rows: ['T1 ghost 34385 01', 'T2 ghost 100 01 USD'],
    expect: ['T1 MISSING_FROM_LEDGER null', 'T2 MISSING_FROM_LEDGER null'],
    unmatched: ['ae#1', 'ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: 'a declined row for an unknown agreement is DECLINED',
    rows: ['T1 ghost 34385 01 DECLINED'],
    expect: ['T1 DECLINED null'],
    unmatched: ['ae#1', 'ae#2', 'bh#2', 'sa#2'],
  },

  // --- Candidates: within 1 minor unit ---
  {
    rule: 'amount one above or one below the total is a candidate',
    rows: ['T1 sa 34386 01', 'T2 bh 26949 01'],
    expect: ['T1 MATCHED sa#2', 'T2 MATCHED bh#2'],
    unmatched: ['ae#1', 'ae#2'],
  },
  {
    rule: 'amount two above or two below is no candidate: MISSING_FROM_LEDGER',
    rows: ['T1 sa 34387 01', 'T2 bh 26948 01'],
    expect: ['T1 MISSING_FROM_LEDGER null', 'T2 MISSING_FROM_LEDGER null'],
    unmatched: ['ae#1', 'ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: 'the net amount without VAT is no candidate: amount is compared with total',
    rows: ['T1 sa 29900 01'],
    expect: ['T1 MISSING_FROM_LEDGER null'],
    unmatched: ['ae#1', 'ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: "another agreement's total is no candidate: candidates come from the row's own agreement",
    rows: ['T1 sa 26950 01', 'T2 bh 34385 01'],
    expect: ['T1 MISSING_FROM_LEDGER null', 'T2 MISSING_FROM_LEDGER null'],
    unmatched: ['ae#1', 'ae#2', 'bh#2', 'sa#2'],
  },

  // --- Picking a candidate: ae#1 is 3257 due the 5th, ae#2 is 3255 due the 20th ---
  {
    rule: '3256 is within 1 of both: the earliest due date wins, so ae#1, and the 20th is a drift',
    rows: ['T1 ae 3256 20'],
    expect: ['T1 DUE_DAY_DRIFT ae#1'],
    unmatched: ['ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: '3256 attempted on the 5th: ae#1 MATCHED',
    rows: ['T1 ae 3256 05'],
    expect: ['T1 MATCHED ae#1'],
    unmatched: ['ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: '3254 is within 1 of ae#2 only',
    rows: ['T1 ae 3254 20'],
    expect: ['T1 MATCHED ae#2'],
    unmatched: ['ae#1', 'bh#2', 'sa#2'],
  },
  {
    rule: '3255 and 3257 each fit one invoice exactly: both invoices matched',
    rows: ['T1 ae 3257 05', 'T2 ae 3255 20'],
    expect: ['T1 MATCHED ae#1', 'T2 MATCHED ae#2'],
    unmatched: ['bh#2', 'sa#2'],
  },
  {
    rule: '3258 is within 1 of ae#1 only, and 3259 of neither',
    rows: ['T1 ae 3258 05', 'T2 ae 3259 05'],
    expect: ['T1 MATCHED ae#1', 'T2 MISSING_FROM_LEDGER null'],
    unmatched: ['ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: 'a linked invoice still counts: two 3256 rows both take ae#1, and ae#2 stays unmatched',
    rows: ['T1 ae 3256 05', 'T2 ae 3256 20'],
    expect: ['T1 DOUBLE_CHARGE_RISK ae#1', 'T2 DOUBLE_CHARGE_RISK ae#1'],
    unmatched: ['ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: 'a declined 3256 row does not hold ae#1 for anyone',
    rows: ['T1 ae 3256 05 DECLINED', 'T2 ae 3256 05'],
    expect: ['T1 DECLINED null', 'T2 MATCHED ae#1'],
    unmatched: ['ae#2', 'bh#2', 'sa#2'],
  },

  // --- Expected invoices come from the month ---
  {
    rule: 'September: the FIRST invoice is expected, and matches as invoice_no 1',
    month: '2026-09',
    rows: ['T1 sa 12607 2026-09-20'],
    expect: ['T1 MATCHED sa#1'],
    unmatched: ['bh#1'],
  },
  {
    rule: "September: October's monthly total has no candidate yet",
    month: '2026-09',
    rows: ['T1 sa 34385 2026-09-20'],
    expect: ['T1 MISSING_FROM_LEDGER null'],
    unmatched: ['bh#1', 'sa#1'],
  },
  {
    rule: 'August: no agreement has started, so nothing is expected and every row is missing',
    month: '2026-08',
    rows: ['T1 sa 34385 2026-08-01'],
    expect: ['T1 MISSING_FROM_LEDGER null'],
    unmatched: [],
  },
  {
    rule: 'February of a leap year accepts the 29th',
    month: '2028-02',
    rows: ['T1 sa 34385 2028-02-29'],
    expect: ['T1 DUE_DAY_DRIFT sa#18'],
    unmatched: ['ae#18', 'bh#18'],
  },
  {
    rule: 'no rows at all: every expected invoice is unmatched',
    rows: [],
    expect: [],
    unmatched: ['ae#1', 'ae#2', 'bh#2', 'sa#2'],
  },
  {
    rule: 'every verdict in one run',
    rows: ['T1 bh 26950 01', 'T2 sa 34385 02', 'T3 ae 3256 05', 'T4 ae 3257 06', 'T5 ghost 5 07', 'T6 ae 3255 20 DECLINED'],
    expect: [
      'T1 MATCHED bh#2',
      'T2 DUE_DAY_DRIFT sa#2',
      'T3 DOUBLE_CHARGE_RISK ae#1',
      'T4 DOUBLE_CHARGE_RISK ae#1',
      'T5 MISSING_FROM_LEDGER null',
      'T6 DECLINED null',
    ],
    unmatched: ['ae#2'],
  },
]

const VERDICTS = ['MATCHED', 'DUE_DAY_DRIFT', 'DOUBLE_CHARGE_RISK', 'MISSING_FROM_LEDGER', 'DECLINED']

for (const c of CASES) {
  test(`reconcile | ${c.rule}`, async () => {
    const { app, ids } = await seeded()
    const month = c.month ?? '2026-10'
    const run = await create(app, '/reconciliation/runs', { month, rows: c.rows.map((short) => row(ids, short)) })

    assert.equal(run.month, month)
    assert.deepEqual(run.rows.map((r: any) => verdictLine(ids, r)), c.expect)
    assert.deepEqual(unmatchedNames(ids, run), c.unmatched)

    // The summary has every verdict as a key, and counts what the rows say.
    assert.deepEqual(Object.keys(run.summary), VERDICTS)
    for (const verdict of VERDICTS) {
      assert.equal(run.summary[verdict], c.expect.filter((line) => line.split(' ')[1] === verdict).length)
    }
  })
}

// ---------------------------------------------------------------------------
// Response shape, order and storage
// ---------------------------------------------------------------------------

test('the spec example byte for byte: keys, order, null invoice and the unmatched invoice fields', async () => {
  const app = createApp()
  const noura = await create(app, '/members', { name: 'Noura', country: 'SA', phone: PHONES.SA })
  const ali = await create(app, '/members', { name: 'Ali', country: 'BH', phone: PHONES.BH })
  await create(app, '/plans', { id: 'sa', country: 'SA', monthly: 29900, joining_fee: 0 })
  await create(app, '/plans', { id: 'bh', country: 'BH', monthly: 24500, joining_fee: 0 })
  const sa = await create(app, '/agreements', { member_id: noura.id, plan_id: 'sa', start_date: '2026-09-20', due_day: 1 })
  const bh = await create(app, '/agreements', { member_id: ali.id, plan_id: 'bh', start_date: '2026-09-15', due_day: 1 })

  const res = await post(app, '/reconciliation/runs', {
    month: '2026-10',
    rows: [
      { gateway_txn_id: 'T-88121', agreement_id: sa.id, amount: 34385, currency: 'SAR', status: 'SETTLED', attempted_on: '2026-10-01' },
      { gateway_txn_id: 'T-88122', agreement_id: bh.id, amount: 26950, currency: 'BHD', status: 'DECLINED', attempted_on: '2026-10-02' },
    ],
  })
  const text = await res.text()
  const id = JSON.parse(text).id
  assert.equal(res.status, 201)
  assert.equal(typeof id, 'string')
  assert.equal(
    text,
    `{"id":"${id}","month":"2026-10",` +
      '"summary":{"MATCHED":1,"DUE_DAY_DRIFT":0,"DOUBLE_CHARGE_RISK":0,"MISSING_FROM_LEDGER":0,"DECLINED":1},' +
      `"rows":[{"gateway_txn_id":"T-88121","verdict":"MATCHED","invoice":{"agreement_id":"${sa.id}","invoice_no":2}},` +
      '{"gateway_txn_id":"T-88122","verdict":"DECLINED","invoice":null}],' +
      `"unmatched_invoices":[{"agreement_id":"${bh.id}","invoice_no":2,"due_date":"2026-10-01","total":26950,"currency":"BHD"}]}`,
  )

  // GET returns the same body, byte for byte.
  const read = await app.request(`/reconciliation/runs/${id}`)
  assert.equal(read.status, 200)
  assert.equal(await read.text(), text)
})

test('rows come back in request order', async () => {
  const { app, ids } = await seeded()
  const shorts = ['Z9 ghost 1 31', 'A1 sa 34385 01', 'M5 bh 26950 15 DECLINED', 'B2 ae 3255 20']
  const run = await create(app, '/reconciliation/runs', { month: '2026-10', rows: shorts.map((s) => row(ids, s)) })
  assert.deepEqual(run.rows.map((r: any) => r.gateway_txn_id), ['Z9', 'A1', 'M5', 'B2'])
})

test('the result does not depend on the order of rows: all 120 orders of 5 rows agree', async () => {
  const { app, ids } = await seeded()
  const shorts = ['T1 ae 3256 20', 'T2 ae 3256 05', 'T3 ae 3254 20', 'T4 sa 34385 01', 'T5 sa 34386 02 DECLINED']
  const permutations = (items: string[]): string[][] =>
    items.length <= 1 ? [items] : items.flatMap((item, i) => permutations(items.filter((_, j) => j !== i)).map((rest) => [item, ...rest]))

  const results = new Set<string>()
  for (const order of permutations(shorts)) {
    const run = await create(app, '/reconciliation/runs', { month: '2026-10', rows: order.map((s) => row(ids, s)) })
    const byTxn = run.rows.map((r: any) => verdictLine(ids, r)).sort()
    results.add(JSON.stringify([byTxn, run.summary, run.unmatched_invoices]))
  }
  assert.equal(results.size, 1)
  assert.deepEqual(JSON.parse([...results][0]!)[0], [
    'T1 DOUBLE_CHARGE_RISK ae#1',
    'T2 DOUBLE_CHARGE_RISK ae#1',
    'T3 MATCHED ae#2',
    'T4 MATCHED sa#2',
    'T5 DECLINED null',
  ])
})

test('unmatched_invoices sort by due_date, then agreement_id, then invoice_no', async () => {
  const app = createApp()
  const member = await create(app, '/members', { name: 'M', country: 'AE', phone: PHONES.AE })
  await create(app, '/plans', { id: 'p', country: 'AE', monthly: 10000, joining_fee: 0 })
  // Start on the 1st, due on the 31st: invoice 1 and invoice 2 of one agreement fall in the same month.
  // Six agreements give several invoices on each due date, so every sort key is exercised.
  for (const [start, dueDay] of [['2026-10-01', 31], ['2026-10-01', 31], ['2026-09-10', 1], ['2026-10-31', 1], ['2026-10-01', 15], ['2026-09-10', 1]] as const) {
    await create(app, '/agreements', { member_id: member.id, plan_id: 'p', start_date: start, due_day: dueDay })
  }
  const run = await create(app, '/reconciliation/runs', { month: '2026-10', rows: [] })
  const got = run.unmatched_invoices.map((i: any) => [i.due_date, i.agreement_id, i.invoice_no])

  // 2 agreements × 2 invoices, 2 × 1, 1 × 1 and 1 × 2: nine invoices in all.
  assert.equal(got.length, 9)
  const sorted = [...got].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : a[2] - b[2]))
  assert.deepEqual(got, sorted)
  assert.deepEqual([...new Set(got.map((g: any) => g[0]))], ['2026-10-01', '2026-10-15', '2026-10-31'])
})

test('unmatched invoices carry agreement_id, invoice_no, due_date, total and currency', async () => {
  const { app, ids } = await seeded()
  const run = await create(app, '/reconciliation/runs', { month: '2026-10', rows: [] })
  const ae = run.unmatched_invoices.filter((i: any) => i.agreement_id === ids.ae)
  assert.deepEqual(ae.map((i: any) => [i.invoice_no, i.due_date, i.total, i.currency]), [
    [1, '2026-10-05', 3257, 'AED'],
    [2, '2026-10-20', 3255, 'AED'],
  ])
})

test('a run is a snapshot: it reads back unchanged after new agreements arrive', async () => {
  const { app, ids } = await seeded()
  const run = await create(app, '/reconciliation/runs', { month: '2026-10', rows: [row(ids, 'T1 sa 34385 01')] })
  const before = await (await app.request(`/reconciliation/runs/${run.id}`)).text()

  const member = await create(app, '/members', { name: 'Late', country: 'SA', phone: '0559999999' })
  await create(app, '/agreements', { member_id: member.id, plan_id: 'sa', start_date: '2026-10-10', due_day: 10 })

  assert.equal(await (await app.request(`/reconciliation/runs/${run.id}`)).text(), before)
  // A new run does see the new agreement.
  const next = await create(app, '/reconciliation/runs', { month: '2026-10', rows: [] })
  assert.equal(next.unmatched_invoices.length, 5)
})

test('a run never changes members or agreements', async () => {
  const { app, ids } = await seeded()
  const url = `/agreements/${ids.sa}/invoices?from=2026-09-01&to=2026-12-31`
  const before = await (await app.request(url)).text()
  await create(app, '/reconciliation/runs', { month: '2026-10', rows: [row(ids, 'T1 sa 34385 01'), row(ids, 'T2 sa 34385 02')] })
  assert.equal(await (await app.request(url)).text(), before)
  assert.equal((await app.request('/members/lookup?phone=%2B966551234567')).status, 200)
})

test('each run gets its own id, and the same transaction may appear in two runs', async () => {
  const { app, ids } = await seeded()
  const body = { month: '2026-10', rows: [row(ids, 'T1 sa 34385 01')] }
  const a = await create(app, '/reconciliation/runs', body)
  const b = await create(app, '/reconciliation/runs', body)
  assert.notEqual(a.id, b.id)
  assert.deepEqual({ ...a, id: '' }, { ...b, id: '' })
  assert.equal((await app.request(`/reconciliation/runs/${a.id}`)).status, 200)
  assert.equal((await app.request(`/reconciliation/runs/${b.id}`)).status, 200)
})

test('GET an unknown run is 404 NOT_FOUND', async () => {
  const { app } = await seeded()
  await expectError(await app.request('/reconciliation/runs/nope'), 404, 'NOT_FOUND')
})

// ---------------------------------------------------------------------------
// INVALID_ROWS
// ---------------------------------------------------------------------------

type RowsCase = { rule: string; month?: string; rows: string[]; errors: string[] }

const INVALID_ROWS: RowsCase[] = [
  {
    rule: 'DUPLICATE_TXN: both rows that share an id get an entry',
    rows: ['T1 sa 34385 01', 'T1 bh 26950 01'],
    errors: ['T1 DUPLICATE_TXN', 'T1 DUPLICATE_TXN'],
  },
  {
    rule: 'DUPLICATE_TXN: three rows give three entries, and the clean row gets none',
    rows: ['T1 sa 34385 01', 'T1 sa 34385 02', 'T2 bh 26950 01', 'T1 ghost 5 03'],
    errors: ['T1 DUPLICATE_TXN', 'T1 DUPLICATE_TXN', 'T1 DUPLICATE_TXN'],
  },
  {
    rule: 'DUPLICATE_TXN: a declined row counts as a duplicate too',
    rows: ['T1 sa 34385 01', 'T1 sa 34385 01 DECLINED'],
    errors: ['T1 DUPLICATE_TXN', 'T1 DUPLICATE_TXN'],
  },
  {
    rule: 'ROW_OUTSIDE_MONTH: the last day of the month before',
    rows: ['T1 sa 34385 2026-09-30'],
    errors: ['T1 ROW_OUTSIDE_MONTH'],
  },
  {
    rule: 'ROW_OUTSIDE_MONTH: the first day of the month after',
    rows: ['T1 sa 34385 2026-11-01'],
    errors: ['T1 ROW_OUTSIDE_MONTH'],
  },
  {
    rule: 'ROW_OUTSIDE_MONTH: the same month in another year',
    rows: ['T1 sa 34385 2025-10-01'],
    errors: ['T1 ROW_OUTSIDE_MONTH'],
  },
  {
    rule: 'ROW_OUTSIDE_MONTH: applies to declined rows and unknown agreements',
    rows: ['T1 sa 34385 2026-11-01 DECLINED', 'T2 ghost 5 2026-09-30'],
    errors: ['T1 ROW_OUTSIDE_MONTH', 'T2 ROW_OUTSIDE_MONTH'],
  },
  {
    rule: 'CURRENCY_MISMATCH: a SAR agreement paid in AED',
    rows: ['T1 sa 34385 01 AED'],
    errors: ['T1 CURRENCY_MISMATCH'],
  },
  {
    rule: 'CURRENCY_MISMATCH: a currency we do not know, and a lowercase one',
    rows: ['T1 sa 34385 01 USD', 'T2 bh 26950 01 bhd'],
    errors: ['T1 CURRENCY_MISMATCH', 'T2 CURRENCY_MISMATCH'],
  },
  {
    rule: 'CURRENCY_MISMATCH: applies to declined rows',
    rows: ['T1 bh 26950 01 DECLINED SAR'],
    errors: ['T1 CURRENCY_MISMATCH'],
  },
  {
    rule: 'one row can break all three rules: one entry per code',
    rows: ['T1 sa 34385 2026-11-01 AED', 'T1 bh 26950 01'],
    errors: ['T1 CURRENCY_MISMATCH', 'T1 DUPLICATE_TXN', 'T1 DUPLICATE_TXN', 'T1 ROW_OUTSIDE_MONTH'],
  },
  {
    rule: 'several offending rows: only they are listed',
    rows: ['T1 sa 34385 01', 'T2 sa 34385 2026-09-30', 'T3 bh 26950 01 AED', 'T4 ghost 5 01 USD'],
    errors: ['T2 ROW_OUTSIDE_MONTH', 'T3 CURRENCY_MISMATCH'],
  },
]

for (const c of INVALID_ROWS) {
  test(`INVALID_ROWS | ${c.rule}`, async () => {
    const { app, ids } = await seeded()
    const res = await post(app, '/reconciliation/runs', { month: c.month ?? '2026-10', rows: c.rows.map((s) => row(ids, s)) })
    const error = await expectError(res, 422, 'INVALID_ROWS')
    for (const entry of error.errors) assert.deepEqual(Object.keys(entry), ['gateway_txn_id', 'code'])
    assert.deepEqual(error.errors.map((e: any) => `${e.gateway_txn_id} ${e.code}`).sort(), c.errors)
  })
}

test('an unknown agreement skips the currency check, so any currency passes', async () => {
  const { app, ids } = await seeded()
  const run = await create(app, '/reconciliation/runs', { month: '2026-10', rows: [row(ids, 'T1 ghost 5 01 USD')] })
  assert.equal(run.rows[0].verdict, 'MISSING_FROM_LEDGER')
})

// ---------------------------------------------------------------------------
// VALIDATION
// ---------------------------------------------------------------------------

test('malformed runs are 422 VALIDATION', async (t) => {
  const { app, ids } = await seeded()
  const good = row(ids, 'T1 sa 34385 01')
  const body = (change: object) => ({ month: '2026-10', rows: [{ ...good, ...change }] })

  const cases: [rule: string, body: unknown][] = [
    ['month missing', { rows: [good] }],
    ['month is a number', { month: 202610, rows: [good] }],
    ['month empty', { month: '', rows: [good] }],
    ['month 13', { month: '2026-13', rows: [good] }],
    ['month 00', { month: '2026-00', rows: [good] }],
    ['month without zero padding', { month: '2026-1', rows: [] }],
    ['month is a full date', { month: '2026-10-01', rows: [good] }],
    ['month is a name', { month: 'October 2026', rows: [good] }],
    ['rows missing', { month: '2026-10' }],
    ['rows is null', { month: '2026-10', rows: null }],
    ['rows is an object', { month: '2026-10', rows: { T1: good } }],
    ['rows is a string', { month: '2026-10', rows: 'T1' }],
    ['a row is null', { month: '2026-10', rows: [null] }],
    ['a row is a string', { month: '2026-10', rows: ['T1'] }],
    ['a row is an array', { month: '2026-10', rows: [[good]] }],
    ['gateway_txn_id missing', body({ gateway_txn_id: undefined })],
    ['gateway_txn_id is a number', body({ gateway_txn_id: 88121 })],
    ['gateway_txn_id empty', body({ gateway_txn_id: '' })],
    ['agreement_id missing', body({ agreement_id: undefined })],
    ['agreement_id is a number', body({ agreement_id: 5 })],
    ['agreement_id is null', body({ agreement_id: null })],
    ['amount missing', body({ amount: undefined })],
    ['amount 0', body({ amount: 0 })],
    ['amount negative', body({ amount: -34385 })],
    ['amount has a fraction', body({ amount: 343.85 })],
    ['amount is a string', body({ amount: '34385' })],
    ['currency missing', body({ currency: undefined })],
    ['currency is a number', body({ currency: 682 })],
    ['status missing', body({ status: undefined })],
    ['status lowercase', body({ status: 'settled' })],
    ['status not one of the two', body({ status: 'REFUNDED' })],
    ['attempted_on missing', body({ attempted_on: undefined })],
    ['attempted_on without zero padding', body({ attempted_on: '2026-10-1' })],
    ['attempted_on is not a real day', body({ attempted_on: '2026-10-32' })],
    ['attempted_on with a time', body({ attempted_on: '2026-10-01T09:00:00Z' })],
    ['attempted_on is a number', body({ attempted_on: 20261001 })],
    ['a malformed row next to a duplicate: validation comes before INVALID_ROWS', { month: '2026-10', rows: [good, good, { ...good, amount: 0 }] }],
    ['a declined row is validated like any other', body({ status: 'DECLINED', amount: 0 })],
  ]
  for (const [rule, requestBody] of cases) {
    await t.test(rule, async () => {
      await expectError(await post(app, '/reconciliation/runs', requestBody), 422, 'VALIDATION')
    })
  }
})
