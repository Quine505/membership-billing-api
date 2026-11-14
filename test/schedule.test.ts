import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createApp } from '../src/app.ts'
import { create, expectError, PHONES, type App } from './helpers.ts'

type Country = 'AE' | 'SA' | 'BH'

// Builds an app holding one member, one plan and one agreement.
async function agreementOn(country: Country, monthly: number, fee: number, start: string, dueDay: number) {
  const app = createApp()
  const member = await create(app, '/members', { name: 'M', country, phone: PHONES[country] })
  await create(app, '/plans', { id: 'p', country, monthly, joining_fee: fee })
  const agreement = await create(app, '/agreements', { member_id: member.id, plan_id: 'p', start_date: start, due_day: dueDay })
  return { app, id: agreement.id as string }
}

function getInvoices(app: App, id: string, from?: string, to?: string) {
  const query = new URLSearchParams()
  if (from !== undefined) query.set('from', from)
  if (to !== undefined) query.set('to', to)
  return app.request(`/agreements/${id}/invoices?${query}`)
}

// One invoice as one line: "no due_date kind days/cycle net vat total currency".
function line(i: any): string {
  const proration = i.proration ? `${i.proration.days}/${i.proration.cycle_days}` : 'null'
  return `${i.invoice_no} ${i.due_date} ${i.kind} ${proration} ${i.net} ${i.vat} ${i.total} ${i.currency}`
}

// Every expected number below was worked out by hand from the spec, not copied from the code's output.
type Case = {
  rule: string
  plan: [country: Country, monthly: number, fee: number]
  start: string
  dueDay: number
  range: [from: string, to: string]
  expect: string[]
}

const CASES: Case[] = [
  // --- The two worked examples from the spec ---
  {
    rule: 'spec example 1: 11/30, net 10963, VAT 1644',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2026-09-01', '2026-12-31'],
    expect: [
      '1 2026-09-20 FIRST 11/30 10963 1644 12607 SAR',
      '2 2026-10-01 MONTHLY null 29900 4485 34385 SAR',
      '3 2026-11-01 MONTHLY null 29900 4485 34385 SAR',
      '4 2026-12-01 MONTHLY null 29900 4485 34385 SAR',
    ],
  },
  {
    rule: 'spec example 2: 15/31 plus joining fee, and September has two invoices',
    plan: ['AE', 24900, 9900], start: '2026-09-05', dueDay: 20, range: ['2026-09-01', '2026-09-30'],
    expect: ['1 2026-09-05 FIRST 15/31 21948 1097 23045 AED', '2 2026-09-20 MONTHLY null 24900 1245 26145 AED'],
  },

  // --- Rule 1: due dates clamp, the anchor stays ---
  {
    rule: 'due 31 clamps to 28 Feb, 30 Apr, 30 Jun and returns to 31',
    plan: ['AE', 10000, 0], start: '2026-01-31', dueDay: 31, range: ['2026-01-01', '2026-07-31'],
    expect: [
      '1 2026-01-31 FIRST 28/28 10000 500 10500 AED',
      '2 2026-02-28 MONTHLY null 10000 500 10500 AED',
      '3 2026-03-31 MONTHLY null 10000 500 10500 AED',
      '4 2026-04-30 MONTHLY null 10000 500 10500 AED',
      '5 2026-05-31 MONTHLY null 10000 500 10500 AED',
      '6 2026-06-30 MONTHLY null 10000 500 10500 AED',
      '7 2026-07-31 MONTHLY null 10000 500 10500 AED',
    ],
  },
  {
    rule: 'due 31 in a leap year clamps to 29 Feb',
    plan: ['AE', 10000, 0], start: '2028-01-31', dueDay: 31, range: ['2028-01-01', '2028-03-31'],
    expect: [
      '1 2028-01-31 FIRST 29/29 10000 500 10500 AED',
      '2 2028-02-29 MONTHLY null 10000 500 10500 AED',
      '3 2028-03-31 MONTHLY null 10000 500 10500 AED',
    ],
  },
  {
    rule: '2100 is not a leap year: due 31 clamps to 28 Feb',
    plan: ['AE', 10000, 0], start: '2100-01-31', dueDay: 31, range: ['2100-02-01', '2100-03-01'],
    expect: ['2 2100-02-28 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: '2000 was a leap year: due 30 clamps to 29 Feb',
    plan: ['AE', 10000, 0], start: '2000-01-30', dueDay: 30, range: ['2000-02-01', '2000-03-31'],
    expect: ['2 2000-02-29 MONTHLY null 10000 500 10500 AED', '3 2000-03-30 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: 'due 29 clamps only in a non-leap February',
    plan: ['AE', 10000, 0], start: '2026-02-01', dueDay: 29, range: ['2026-02-01', '2026-03-31'],
    expect: [
      '1 2026-02-01 FIRST 27/30 9000 450 9450 AED',
      '2 2026-02-28 MONTHLY null 10000 500 10500 AED',
      '3 2026-03-29 MONTHLY null 10000 500 10500 AED',
    ],
  },

  // --- Rule 2: N, P and the proration ---
  {
    rule: 'start is itself a due date: days = cycle_days, full price plus fee',
    plan: ['SA', 29900, 5000], start: '2026-10-01', dueDay: 1, range: ['2026-10-01', '2026-11-30'],
    expect: ['1 2026-10-01 FIRST 31/31 34900 5235 40135 SAR', '2 2026-11-01 MONTHLY null 29900 4485 34385 SAR'],
  },
  {
    rule: 'start on a clamped due date (28 Feb, due 31) is a due date: 31/31',
    plan: ['AE', 10000, 0], start: '2026-02-28', dueDay: 31, range: ['2026-02-01', '2026-03-31'],
    expect: ['1 2026-02-28 FIRST 31/31 10000 500 10500 AED', '2 2026-03-31 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: 'start on 30 Apr with due 31 is a due date: 31/31',
    plan: ['AE', 10000, 0], start: '2026-04-30', dueDay: 31, range: ['2026-04-30', '2026-04-30'],
    expect: ['1 2026-04-30 FIRST 31/31 10000 500 10500 AED'],
  },
  {
    rule: 'start the day before a clamped due date: 1/28, P is 31 Jan',
    plan: ['AE', 10000, 0], start: '2026-02-27', dueDay: 31, range: ['2026-02-01', '2026-02-28'],
    expect: ['1 2026-02-27 FIRST 1/28 357 18 375 AED', '2 2026-02-28 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: 'start the day after a clamped due date: 30/31, P is 28 Feb',
    plan: ['AE', 10000, 0], start: '2026-03-01', dueDay: 31, range: ['2026-03-01', '2026-03-31'],
    expect: ['1 2026-03-01 FIRST 30/31 9677 484 10161 AED', '2 2026-03-31 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: 'start one day before the due date: 1/31, two invoices one day apart',
    plan: ['AE', 10000, 0], start: '2026-03-30', dueDay: 31, range: ['2026-03-30', '2026-03-31'],
    expect: ['1 2026-03-30 FIRST 1/31 323 16 339 AED', '2 2026-03-31 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: 'start one day after the due date: 29/30',
    plan: ['AE', 10000, 0], start: '2026-09-02', dueDay: 1, range: ['2026-09-01', '2026-10-01'],
    expect: ['1 2026-09-02 FIRST 29/30 9667 483 10150 AED', '2 2026-10-01 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: 'N falls in the next year: 26/31',
    plan: ['AE', 10000, 0], start: '2026-12-15', dueDay: 10, range: ['2026-12-01', '2027-01-31'],
    expect: ['1 2026-12-15 FIRST 26/31 8387 419 8806 AED', '2 2027-01-10 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: 'P falls in the previous year: 5/31',
    plan: ['AE', 10000, 0], start: '2026-01-05', dueDay: 10, range: ['2026-01-01', '2026-01-31'],
    expect: ['1 2026-01-05 FIRST 5/31 1613 81 1694 AED', '2 2026-01-10 MONTHLY null 10000 500 10500 AED'],
  },
  {
    rule: 'a cycle across February is 28 days',
    plan: ['AE', 10000, 0], start: '2026-03-05', dueDay: 10, range: ['2026-03-05', '2026-03-05'],
    expect: ['1 2026-03-05 FIRST 5/28 1786 89 1875 AED'],
  },
  {
    rule: 'a cycle across a leap February is 29 days',
    plan: ['AE', 10000, 0], start: '2028-03-05', dueDay: 10, range: ['2028-03-05', '2028-03-05'],
    expect: ['1 2028-03-05 FIRST 5/29 1724 86 1810 AED'],
  },

  // --- Rule 4: rounding ---
  {
    rule: 'proration rounds half up: 101 × 15/30 = 50.5 → 51',
    plan: ['AE', 101, 0], start: '2026-09-16', dueDay: 1, range: ['2026-09-16', '2026-09-16'],
    expect: ['1 2026-09-16 FIRST 15/30 51 3 54 AED'],
  },
  {
    rule: 'proration is exact where floats are not: 45 × 21/30 = 31.5 → 32 (floats say 31)',
    plan: ['AE', 45, 0], start: '2026-09-10', dueDay: 1, range: ['2026-09-10', '2026-09-10'],
    expect: ['1 2026-09-10 FIRST 21/30 32 2 34 AED'],
  },
  {
    rule: 'no rounding in between: 12 × 24/30 = 9.6 → net 10, then VAT on 10 = 0.5 → 1 (VAT on 9.6 would give 0)',
    plan: ['AE', 12, 0], start: '2026-09-07', dueDay: 1, range: ['2026-09-07', '2026-09-07'],
    expect: ['1 2026-09-07 FIRST 24/30 10 1 11 AED'],
  },
  {
    rule: 'the joining fee is added after the proration rounding and sits inside the VAT base',
    plan: ['AE', 101, 1000], start: '2026-09-16', dueDay: 1, range: ['2026-09-16', '2026-10-01'],
    expect: ['1 2026-09-16 FIRST 15/30 1051 53 1104 AED', '2 2026-10-01 MONTHLY null 101 5 106 AED'],
  },
  {
    rule: 'VAT rounds half up at 5%: 50 → 2.5 → 3',
    plan: ['AE', 50, 0], start: '2026-09-01', dueDay: 1, range: ['2026-10-01', '2026-10-01'],
    expect: ['2 2026-10-01 MONTHLY null 50 3 53 AED'],
  },
  {
    rule: 'VAT rounds half up at 15%: 30 → 4.5 → 5',
    plan: ['SA', 30, 0], start: '2026-09-01', dueDay: 1, range: ['2026-10-01', '2026-10-01'],
    expect: ['2 2026-10-01 MONTHLY null 30 5 35 SAR'],
  },
  {
    rule: 'VAT rounds half up at 10%: 25 → 2.5 → 3',
    plan: ['BH', 25, 0], start: '2026-09-01', dueDay: 1, range: ['2026-10-01', '2026-10-01'],
    expect: ['2 2026-10-01 MONTHLY null 25 3 28 BHD'],
  },
  {
    rule: 'VAT below a half rounds down, to 0 if need be: 9 → 0.45 → 0',
    plan: ['AE', 9, 0], start: '2026-09-01', dueDay: 1, range: ['2026-10-01', '2026-10-01'],
    expect: ['2 2026-10-01 MONTHLY null 9 0 9 AED'],
  },
  {
    rule: 'the smallest plan: monthly 1 prorated 1/30 rounds to net 0',
    plan: ['AE', 1, 0], start: '2026-09-30', dueDay: 1, range: ['2026-09-30', '2026-10-01'],
    expect: ['1 2026-09-30 FIRST 1/30 0 0 0 AED', '2 2026-10-01 MONTHLY null 1 0 1 AED'],
  },

  // --- Rule 5: minor units only ---
  {
    rule: 'BHD keeps three decimals: VAT on 5790 fils is 579, not 580',
    plan: ['BH', 5790, 0], start: '2026-09-01', dueDay: 1, range: ['2026-10-01', '2026-10-01'],
    expect: ['2 2026-10-01 MONTHLY null 5790 579 6369 BHD'],
  },
  {
    rule: 'BHD plan from the Part 3 example: total 26950',
    plan: ['BH', 24500, 0], start: '2026-09-15', dueDay: 1, range: ['2026-10-01', '2026-10-01'],
    expect: ['2 2026-10-01 MONTHLY null 24500 2450 26950 BHD'],
  },
  {
    rule: 'very large amounts stay exact',
    plan: ['SA', 9_000_000_000_000, 0], start: '2026-09-20', dueDay: 1, range: ['2026-09-20', '2026-10-01'],
    expect: [
      '1 2026-09-20 FIRST 11/30 3300000000000 495000000000 3795000000000 SAR',
      '2 2026-10-01 MONTHLY null 9000000000000 1350000000000 10350000000000 SAR',
    ],
  },

  // --- The range filter and invoice_no ---
  {
    rule: 'invoice_no does not restart inside the range',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2026-11-01', '2026-12-31'],
    expect: ['3 2026-11-01 MONTHLY null 29900 4485 34385 SAR', '4 2026-12-01 MONTHLY null 29900 4485 34385 SAR'],
  },
  {
    rule: 'from and to are inclusive: a one-day range on a due date',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2026-10-01', '2026-10-01'],
    expect: ['2 2026-10-01 MONTHLY null 29900 4485 34385 SAR'],
  },
  {
    rule: 'to is inclusive on the start date',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2026-09-01', '2026-09-20'],
    expect: ['1 2026-09-20 FIRST 11/30 10963 1644 12607 SAR'],
  },
  {
    rule: 'from the day after the start skips invoice 1',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2026-09-21', '2026-10-01'],
    expect: ['2 2026-10-01 MONTHLY null 29900 4485 34385 SAR'],
  },
  {
    rule: 'a range between two due dates is empty',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2026-10-02', '2026-10-31'],
    expect: [],
  },
  {
    rule: 'a range that ends the day before the start is empty',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2026-01-01', '2026-09-19'],
    expect: [],
  },
  {
    rule: 'a range years before the start is empty',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2020-01-01', '2020-12-31'],
    expect: [],
  },
  {
    rule: 'agreements never end: January 2030 is invoice 41',
    plan: ['SA', 29900, 0], start: '2026-09-20', dueDay: 1, range: ['2030-01-01', '2030-01-31'],
    expect: ['41 2030-01-01 MONTHLY null 29900 4485 34385 SAR'],
  },
]

for (const c of CASES) {
  test(`schedule | ${c.rule} | start ${c.start} due ${c.dueDay} | ${c.range.join('..')}`, async () => {
    const { app, id } = await agreementOn(...c.plan, c.start, c.dueDay)
    const res = await getInvoices(app, id, ...c.range)
    assert.equal(res.status, 200)
    assert.deepEqual((await res.json()).map(line), c.expect)
  })
}

test('schedule | the spec example byte for byte: keys, order, proration object and null', async () => {
  const { app, id } = await agreementOn('SA', 29900, 0, '2026-09-20', 1)
  const res = await getInvoices(app, id, '2026-09-01', '2026-10-31')
  assert.equal(
    await res.text(),
    '[{"invoice_no":1,"due_date":"2026-09-20","kind":"FIRST","proration":{"days":11,"cycle_days":30},"net":10963,"vat":1644,"total":12607,"currency":"SAR"},' +
      '{"invoice_no":2,"due_date":"2026-10-01","kind":"MONTHLY","proration":null,"net":29900,"vat":4485,"total":34385,"currency":"SAR"}]',
  )
})

test('schedule | the widest range, 366 days, lists 13 invoices numbered 1 to 13', async () => {
  const { app, id } = await agreementOn('SA', 29900, 0, '2026-09-20', 1)
  const invoices = await (await getInvoices(app, id, '2026-09-20', '2027-09-21')).json()
  assert.deepEqual(invoices.map((i: any) => i.invoice_no), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13])
  assert.equal(invoices[12].due_date, '2027-09-01')
})

test('schedule | two agreements of one member have independent schedules', async () => {
  const { app, id } = await agreementOn('SA', 29900, 0, '2026-09-20', 1)
  const first = await (await getInvoices(app, id, '2026-09-01', '2026-10-31')).json()
  const other = await create(app, '/agreements', { member_id: (await (await app.request('/members/lookup?phone=%2B966551234567')).json()).id, plan_id: 'p', start_date: '2026-10-15', due_day: 15 })
  assert.deepEqual((await (await getInvoices(app, other.id, '2026-10-01', '2026-10-31')).json()).map(line), [
    '1 2026-10-15 FIRST 31/31 29900 4485 34385 SAR',
  ])
  assert.deepEqual(await (await getInvoices(app, id, '2026-09-01', '2026-10-31')).json(), first)
})

// ---------------------------------------------------------------------------
// Range and id errors
// ---------------------------------------------------------------------------

const RANGE_OK: [rule: string, from: string, to: string][] = [
  ['to equals from', '2026-01-01', '2026-01-01'],
  ['to is exactly 366 days after from', '2026-01-01', '2027-01-02'],
  ['366 days across a leap year', '2028-01-01', '2029-01-01'],
]

for (const [rule, from, to] of RANGE_OK) {
  test(`range 200 | ${rule} | ${from}..${to}`, async () => {
    const { app, id } = await agreementOn('SA', 29900, 0, '2026-09-20', 1)
    assert.equal((await getInvoices(app, id, from, to)).status, 200)
  })
}

const RANGE_ERRORS: [rule: string, from: string | undefined, to: string | undefined, code: string][] = [
  ['to is one day before from', '2026-01-02', '2026-01-01', 'INVALID_RANGE'],
  ['to is a year before from', '2026-09-01', '2025-09-01', 'INVALID_RANGE'],
  ['to is 367 days after from', '2026-01-01', '2027-01-03', 'INVALID_RANGE'],
  ['367 days across a leap year', '2028-01-01', '2029-01-02', 'INVALID_RANGE'],
  ['to is years after from', '2026-01-01', '2036-01-01', 'INVALID_RANGE'],
  ['from missing', undefined, '2026-12-31', 'VALIDATION'],
  ['to missing', '2026-09-01', undefined, 'VALIDATION'],
  ['both missing', undefined, undefined, 'VALIDATION'],
  ['from empty', '', '2026-12-31', 'VALIDATION'],
  ['from without zero padding', '2026-9-1', '2026-12-31', 'VALIDATION'],
  ['from without hyphens', '20260901', '2026-12-31', 'VALIDATION'],
  ['from with a time', '2026-09-01T00:00:00Z', '2026-12-31', 'VALIDATION'],
  ['from is not a real day', '2026-02-30', '2026-12-31', 'VALIDATION'],
  ['to is not a real day', '2026-09-01', '2026-09-31', 'VALIDATION'],
  ['to month 13', '2026-09-01', '2026-13-01', 'VALIDATION'],
  ['to day first', '2026-09-01', '31-12-2026', 'VALIDATION'],
  ['to is a word', '2026-09-01', 'tomorrow', 'VALIDATION'],
  ['a bad date and a reversed range: validation comes first', '2026-12-31', '2026-1-1', 'VALIDATION'],
]

for (const [rule, from, to, code] of RANGE_ERRORS) {
  test(`range 422 ${code} | ${rule} | ${from}..${to}`, async () => {
    const { app, id } = await agreementOn('SA', 29900, 0, '2026-09-20', 1)
    await expectError(await getInvoices(app, id, from, to), 422, code)
  })
}

test('invoices 404 NOT_FOUND | unknown agreement id, also when the query is bad', async () => {
  const { app } = await agreementOn('SA', 29900, 0, '2026-09-20', 1)
  await expectError(await getInvoices(app, 'nope', '2026-09-01', '2026-12-31'), 404, 'NOT_FOUND')
  await expectError(await getInvoices(app, 'nope'), 404, 'NOT_FOUND')
})

test('invoices are computed on request: asking twice gives the same answer', async () => {
  const { app, id } = await agreementOn('AE', 24900, 9900, '2026-09-05', 20)
  const a = await (await getInvoices(app, id, '2026-09-01', '2026-12-31')).text()
  const b = await (await getInvoices(app, id, '2026-09-01', '2026-12-31')).text()
  assert.equal(a, b)
})
