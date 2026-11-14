import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createApp } from '../src/app.ts'
import { create, expectError, post, PHONES } from './helpers.ts'

// ---------------------------------------------------------------------------
// POST /plans
// ---------------------------------------------------------------------------

const plan = { id: 'anytime-sa', country: 'SA', monthly: 29900, joining_fee: 0 }

test('plan: the spec example comes back with its currency, keys in order', async () => {
  const res = await post(createApp(), '/plans', plan)
  assert.equal(res.status, 201)
  assert.equal(await res.text(), '{"id":"anytime-sa","country":"SA","currency":"SAR","monthly":29900,"joining_fee":0}')
})

for (const [country, currency] of [['AE', 'AED'], ['SA', 'SAR'], ['BH', 'BHD']]) {
  test(`plan ok | currency comes from the country | ${country} → ${currency}`, async () => {
    assert.equal((await create(createApp(), '/plans', { ...plan, country })).currency, currency)
  })
}

const OK_PLANS: [rule: string, body: unknown][] = [
  ['monthly 1 is the smallest allowed', { ...plan, monthly: 1 }],
  ['joining_fee above 0', { ...plan, joining_fee: 9900 }],
  ['a very large monthly', { ...plan, monthly: 9_000_000_000_000 }],
  ['unknown extra fields are ignored', { ...plan, currency: 'USD', vat: 99 }],
  ['id with spaces and symbols', { ...plan, id: 'Gold Plan / 2026 #1' }],
]

for (const [rule, body] of OK_PLANS) {
  test(`plan ok | ${rule}`, async () => {
    const created = await create(createApp(), '/plans', body)
    assert.equal(created.currency, 'SAR')
  })
}

const BAD_PLANS: [rule: string, body: unknown][] = [
  ['id missing', { country: 'SA', monthly: 29900, joining_fee: 0 }],
  ['id is a number', { ...plan, id: 7 }],
  ['id is null', { ...plan, id: null }],
  ['id is empty', { ...plan, id: '' }],
  ['country missing', { id: 'p', monthly: 29900, joining_fee: 0 }],
  ['country lowercase', { ...plan, country: 'sa' }],
  ['country not one of the three', { ...plan, country: 'KW' }],
  ['monthly missing', { id: 'p', country: 'SA', joining_fee: 0 }],
  ['monthly 0', { ...plan, monthly: 0 }],
  ['monthly negative', { ...plan, monthly: -29900 }],
  ['monthly has a fraction', { ...plan, monthly: 299.5 }],
  ['monthly is a string', { ...plan, monthly: '29900' }],
  ['monthly is null', { ...plan, monthly: null }],
  ['monthly is true', { ...plan, monthly: true }],
  ['monthly too large to be an exact integer', { ...plan, monthly: 1e20 }],
  ['joining_fee missing', { id: 'p', country: 'SA', monthly: 29900 }],
  ['joining_fee negative', { ...plan, joining_fee: -1 }],
  ['joining_fee has a fraction', { ...plan, joining_fee: 0.5 }],
  ['joining_fee is a string', { ...plan, joining_fee: '0' }],
  ['joining_fee is null', { ...plan, joining_fee: null }],
  ['body is an array', [plan]],
]

for (const [rule, body] of BAD_PLANS) {
  test(`plan VALIDATION | ${rule}`, async () => {
    await expectError(await post(createApp(), '/plans', body), 422, 'VALIDATION')
  })
}

test('PLAN_EXISTS: a second plan with the same id is refused, and the first is unchanged', async () => {
  const app = createApp()
  await create(app, '/plans', plan)
  await expectError(await post(app, '/plans', plan), 409, 'PLAN_EXISTS')
  await expectError(await post(app, '/plans', { id: 'anytime-sa', country: 'AE', monthly: 1, joining_fee: 5 }), 409, 'PLAN_EXISTS')

  // The first plan still prices invoices: an AE member cannot use it, a SA member can.
  const member = await create(app, '/members', { name: 'M', country: 'SA', phone: PHONES.SA })
  await create(app, '/agreements', { member_id: member.id, plan_id: 'anytime-sa', start_date: '2026-09-20', due_day: 1 })
})

test('PLAN_EXISTS: ids are case-sensitive, so "A" and "a" are two plans', async () => {
  const app = createApp()
  await create(app, '/plans', { ...plan, id: 'A' })
  await create(app, '/plans', { ...plan, id: 'a' })
})

test('an invalid plan with a taken id is VALIDATION, and an invalid plan does not take the id', async () => {
  const app = createApp()
  await expectError(await post(app, '/plans', { ...plan, monthly: 0 }), 422, 'VALIDATION')
  await create(app, '/plans', plan)
  await expectError(await post(app, '/plans', { ...plan, monthly: 0 }), 422, 'VALIDATION')
})

test('race: 50 simultaneous plans with one id give one 201 and 49 PLAN_EXISTS', async () => {
  const app = createApp()
  const responses = await Promise.all(Array.from({ length: 50 }, (_, i) => post(app, '/plans', { ...plan, monthly: 1000 + i })))
  assert.equal(responses.filter((r) => r.status === 201).length, 1)
  assert.equal(responses.filter((r) => r.status === 409).length, 49)
})

// ---------------------------------------------------------------------------
// POST /agreements
// ---------------------------------------------------------------------------

// A Saudi member, a Bahraini member, a Saudi member on a UAE SIM, and one plan per country.
async function seeded() {
  const app = createApp()
  const sa = await create(app, '/members', { name: 'Noura', country: 'SA', phone: PHONES.SA })
  const bh = await create(app, '/members', { name: 'Ali', country: 'BH', phone: PHONES.BH })
  const saOnAeSim = await create(app, '/members', { name: 'Sara', country: 'SA', phone: '+971501234567' })
  await create(app, '/plans', { id: 'sa', country: 'SA', monthly: 29900, joining_fee: 0 })
  await create(app, '/plans', { id: 'ae', country: 'AE', monthly: 24900, joining_fee: 9900 })
  await create(app, '/plans', { id: 'bh', country: 'BH', monthly: 24500, joining_fee: 0 })
  const good = { member_id: sa.id, plan_id: 'sa', start_date: '2026-09-20', due_day: 1 }
  return { app, sa, bh, saOnAeSim, good }
}

test('agreement: the spec example comes back with a new id', async () => {
  const { app, good } = await seeded()
  const agreement = await create(app, '/agreements', good)
  assert.deepEqual(Object.keys(agreement), ['id', 'member_id', 'plan_id', 'start_date', 'due_day'])
  assert.equal(typeof agreement.id, 'string')
  assert.deepEqual({ ...agreement, id: '' }, { id: '', ...good })
})

test('agreement: a member may hold several, even on the same plan and date, each with its own id', async () => {
  const { app, good } = await seeded()
  const a = await create(app, '/agreements', good)
  const b = await create(app, '/agreements', good)
  assert.notEqual(a.id, b.id)
})

const OK_AGREEMENTS: [rule: string, change: object][] = [
  ['due_day 1', { due_day: 1 }],
  ['due_day 31', { due_day: 31 }],
  ['start on 29 Feb of a leap year', { start_date: '2028-02-29' }],
  ['start on 29 Feb 2000, a leap century', { start_date: '2000-02-29' }],
  ['start in the past', { start_date: '1999-12-31' }],
  ['start far in the future', { start_date: '9999-12-31' }],
]

for (const [rule, change] of OK_AGREEMENTS) {
  test(`agreement ok | ${rule}`, async () => {
    const { app, good } = await seeded()
    await create(app, '/agreements', { ...good, ...change })
  })
}

const BAD_AGREEMENTS: [rule: string, change: object][] = [
  ['member_id missing', { member_id: undefined }],
  ['member_id is a number', { member_id: 12 }],
  ['member_id is null', { member_id: null }],
  ['plan_id missing', { plan_id: undefined }],
  ['plan_id is a number', { plan_id: 12 }],
  ['start_date missing', { start_date: undefined }],
  ['start_date is a number', { start_date: 20260920 }],
  ['start_date is null', { start_date: null }],
  ['start_date empty', { start_date: '' }],
  ['start_date without zero padding', { start_date: '2026-9-20' }],
  ['start_date without hyphens', { start_date: '20260920' }],
  ['start_date with slashes', { start_date: '2026/09/20' }],
  ['start_date day first', { start_date: '20-09-2026' }],
  ['start_date with a time', { start_date: '2026-09-20T00:00:00' }],
  ['start_date with a timezone', { start_date: '2026-09-20Z' }],
  ['start_date with spaces around it', { start_date: ' 2026-09-20 ' }],
  ['start_date month 13', { start_date: '2026-13-01' }],
  ['start_date month 00', { start_date: '2026-00-10' }],
  ['start_date day 00', { start_date: '2026-09-00' }],
  ['start_date 31 Sep', { start_date: '2026-09-31' }],
  ['start_date 30 Feb', { start_date: '2026-02-30' }],
  ['start_date 29 Feb in a non-leap year', { start_date: '2026-02-29' }],
  ['start_date 29 Feb 2100, not a leap century', { start_date: '2100-02-29' }],
  ['start_date with a 5-digit year', { start_date: '12026-09-20' }],
  ['due_day missing', { due_day: undefined }],
  ['due_day 0', { due_day: 0 }],
  ['due_day 32', { due_day: 32 }],
  ['due_day negative', { due_day: -1 }],
  ['due_day has a fraction', { due_day: 1.5 }],
  ['due_day is a string', { due_day: '1' }],
  ['due_day is null', { due_day: null }],
]

for (const [rule, change] of BAD_AGREEMENTS) {
  test(`agreement VALIDATION | ${rule}`, async () => {
    const { app, good } = await seeded()
    await expectError(await post(app, '/agreements', { ...good, ...change }), 422, 'VALIDATION')
  })
}

test('agreement business errors', async (t) => {
  const { app, bh, saOnAeSim, good } = await seeded()
  const cases: [rule: string, change: object, code: string][] = [
    ['unknown member', { member_id: 'nobody' }, 'UNKNOWN_MEMBER'],
    ['unknown plan', { plan_id: 'nothing' }, 'UNKNOWN_PLAN'],
    ['unknown member and unknown plan: the member is reported', { member_id: 'nobody', plan_id: 'nothing' }, 'UNKNOWN_MEMBER'],
    ['plan ids are case-sensitive', { plan_id: 'SA' }, 'UNKNOWN_PLAN'],
    ['SA member on an AE plan', { plan_id: 'ae' }, 'PLAN_COUNTRY_MISMATCH'],
    ['SA member on a BH plan', { plan_id: 'bh' }, 'PLAN_COUNTRY_MISMATCH'],
    ['BH member on a SA plan', { member_id: bh.id }, 'PLAN_COUNTRY_MISMATCH'],
    ['a UAE SIM does not make a Saudi member Emirati', { member_id: saOnAeSim.id, plan_id: 'ae' }, 'PLAN_COUNTRY_MISMATCH'],
    ['unknown member with a bad due_day: validation comes first', { member_id: 'nobody', due_day: 0 }, 'VALIDATION'],
  ]
  for (const [rule, change, code] of cases) {
    await t.test(`${code} | ${rule}`, async () => {
      await expectError(await post(app, '/agreements', { ...good, ...change }), 422, code)
    })
  }
  await t.test('ok | a Saudi member on a UAE SIM takes a SA plan', async () => {
    await create(app, '/agreements', { ...good, member_id: saOnAeSim.id })
  })
  await t.test('ok | the BH member takes the BH plan', async () => {
    await create(app, '/agreements', { ...good, member_id: bh.id, plan_id: 'bh' })
  })
})
