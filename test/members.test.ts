import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createApp } from '../src/app.ts'

type App = ReturnType<typeof createApp>

function post(app: App, body: unknown) {
  const text = typeof body === 'string' ? body : JSON.stringify(body)
  return app.request('/members', { method: 'POST', body: text, headers: { 'content-type': 'application/json' } })
}

function lookup(app: App, phone: string, country?: string) {
  const query = new URLSearchParams(country === undefined ? { phone } : { phone, country })
  return app.request('/members/lookup?' + query)
}

// Asserts the status and the error code, and that the error has the contract's shape.
async function expectError(res: Response, status: number, code: string) {
  const body = await res.json()
  assert.equal(res.status, status)
  assert.equal(body.error.code, code)
  assert.equal(typeof body.error.message, 'string')
  return body.error
}

// ---------------------------------------------------------------------------
// POST /members: phone in → stored phone, or INVALID_PHONE
// ---------------------------------------------------------------------------

const OK_PHONES: [rule: string, country: string, phone: string, stored: string][] = [
  ['spec example', 'SA', '055 123 4567', '+966551234567'],
  ['clean: hyphens', 'SA', '055-123-4567', '+966551234567'],
  ['clean: brackets', 'SA', '(055) 123 4567', '+966551234567'],
  ['clean: all three mixed', 'SA', ' +966 (55) 123-4567 ', '+966551234567'],
  ['clean: brackets around the plus', 'SA', '(+966)551234567', '+966551234567'],
  ['spelling: SA with plus', 'SA', '+966551234567', '+966551234567'],
  ['spelling: SA without plus', 'SA', '966551234567', '+966551234567'],
  ['spelling: SA national', 'SA', '0551234567', '+966551234567'],
  ['spelling: AE with plus', 'AE', '+971501234567', '+971501234567'],
  ['spelling: AE without plus', 'AE', '971501234567', '+971501234567'],
  ['spelling: AE national', 'AE', '0501234567', '+971501234567'],
  ['spelling: BH with plus', 'BH', '+97333123456', '+97333123456'],
  ['spelling: BH without plus', 'BH', '97333123456', '+97333123456'],
  ['spelling: BH national', 'BH', '33123456', '+97333123456'],
  ['national: same digits read as AE', 'AE', '0551234567', '+971551234567'],
  ['foreign SIM: SA member, AE number', 'SA', '+971501234567', '+971501234567'],
  ['foreign SIM: BH member, SA number, no plus', 'BH', '966551234567', '+966551234567'],
  ['foreign SIM: AE member, BH number', 'AE', '+97333123456', '+97333123456'],
]

for (const [rule, country, phone, stored] of OK_PHONES) {
  test(`POST ok | ${rule} | ${country} "${phone}" → ${stored}`, async () => {
    const res = await post(createApp(), { name: 'Noura', country, phone })
    const body = await res.json()
    assert.equal(res.status, 201)
    assert.equal(body.phone, stored)
    assert.equal(body.country, country)
  })
}

const BAD_PHONES: [rule: string, country: string, phone: string][] = [
  ['clean: dots are not removed', 'SA', '055.123.4567'],
  ['clean: letter', 'SA', '05512345a7'],
  ['clean: slash', 'SA', '055/123/4567'],
  ['clean: tab is not a space', 'SA', '055\t1234567'],
  ['clean: Arabic-Indic digits', 'SA', '٠٥٥١٢٣٤٥٦٧'],
  ['clean: two plus signs', 'SA', '++966551234567'],
  ['clean: plus not leading', 'SA', '966+551234567'],
  ['clean: trailing plus', 'SA', '966551234567+'],
  ['clean: empty', 'SA', ''],
  ['clean: only separators', 'SA', ' (-) '],
  ['clean: only a plus', 'SA', '+'],
  ['spelling: 00 prefix', 'SA', '00966551234567'],
  ['spelling: plus then national', 'SA', '+0551234567'],
  ['spelling: trunk zero after dial code', 'SA', '+9660551234567'],
  ['spelling: SA national without trunk zero', 'SA', '551234567'],
  ['spelling: BH national with a trunk zero', 'BH', '033123456'],
  ['landline: SA international', 'SA', '+966112345678'],
  ['landline: SA national', 'SA', '0112345678'],
  ['landline: AE national', 'AE', '041234567'],
  ['landline: BH national', 'BH', '17123456'],
  ['landline: BH international', 'BH', '+97317123456'],
  ['length: SA international one short', 'SA', '+96655123456'],
  ['length: SA international one long', 'SA', '+9665512345678'],
  ['length: AE national one short', 'AE', '050123456'],
  ['length: AE national one long', 'AE', '05012345678'],
  ['length: BH national one short', 'BH', '3312345'],
  ['length: BH national one long', 'BH', '331234567'],
  ['length: BH international one long', 'BH', '+973331234567'],
  ['other: BH dial code with AE-shaped mobile', 'BH', '+973501234567'],
  ['other: AE dial code with BH-shaped mobile', 'AE', '+97133123456'],
  ['other: Kuwait number', 'SA', '+96550123456'],
  ['other: US number', 'SA', '+14155552671'],
  ['national: AE/SA shape for a BH member', 'BH', '0551234567'],
  ['national: BH shape for a SA member', 'SA', '33123456'],
  ['national: BH shape for an AE member', 'AE', '33123456'],
]

for (const [rule, country, phone] of BAD_PHONES) {
  test(`POST INVALID_PHONE | ${rule} | ${country} ${JSON.stringify(phone)}`, async () => {
    await expectError(await post(createApp(), { name: 'Noura', country, phone }), 422, 'INVALID_PHONE')
  })
}

// ---------------------------------------------------------------------------
// POST /members: body validation
// ---------------------------------------------------------------------------

const good = { name: 'Noura Al Harbi', country: 'SA', phone: '055 123 4567' }

test('POST returns exactly id, name, country, phone', async () => {
  const res = await post(createApp(), good)
  const body = await res.json()
  assert.equal(res.status, 201)
  assert.deepEqual(Object.keys(body).sort(), ['country', 'id', 'name', 'phone'])
  assert.equal(typeof body.id, 'string')
  assert.deepEqual({ ...body, id: '' }, { id: '', name: 'Noura Al Harbi', country: 'SA', phone: '+966551234567' })
})

const BAD_BODIES: [rule: string, body: unknown][] = [
  ['name missing', { country: 'SA', phone: '0551234567' }],
  ['name is a number', { ...good, name: 5 }],
  ['name is null', { ...good, name: null }],
  ['name empty', { ...good, name: '' }],
  ['name only spaces', { ...good, name: '   ' }],
  ['name 121 characters', { ...good, name: 'a'.repeat(121) }],
  ['country missing', { name: 'Noura', phone: '0551234567' }],
  ['country lowercase', { ...good, country: 'sa' }],
  ['country not one of the three', { ...good, country: 'KW' }],
  ['country is a number', { ...good, country: 966 }],
  ['country is an inherited key', { ...good, country: 'toString' }],
  ['phone missing', { name: 'Noura', country: 'SA' }],
  ['phone is a number', { ...good, phone: 966551234567 }],
  ['phone is null', { ...good, phone: null }],
  ['body is an array', [good]],
  ['body is a string', '"hello"'],
  ['body is null', 'null'],
  ['body is not JSON', '{ name: '],
  ['body is empty', ''],
  ['bad name and bad phone together', { ...good, name: '', phone: 'abc' }],
]

for (const [rule, body] of BAD_BODIES) {
  test(`POST VALIDATION | ${rule}`, async () => {
    await expectError(await post(createApp(), body), 422, 'VALIDATION')
  })
}

test('POST name: trimmed, and returned trimmed', async () => {
  const body = await (await post(createApp(), { ...good, name: '  Noura Al Harbi \n' })).json()
  assert.equal(body.name, 'Noura Al Harbi')
})

test('POST name: 120 characters is allowed', async () => {
  assert.equal((await post(createApp(), { ...good, name: 'a'.repeat(120) })).status, 201)
})

test('POST name: length is measured after trimming', async () => {
  assert.equal((await post(createApp(), { ...good, name: '  ' + 'a'.repeat(120) + '  ' })).status, 201)
})

test('POST name: 120 Arabic letters or emoji count as 120 characters', async () => {
  assert.equal((await post(createApp(), { ...good, name: 'ن'.repeat(120) })).status, 201)
  assert.equal((await post(createApp(), { ...good, phone: '0551234568', name: '😀'.repeat(120) })).status, 201)
})

// ---------------------------------------------------------------------------
// One member per phone
// ---------------------------------------------------------------------------

test('PHONE_TAKEN: every other spelling of a taken phone is refused, with existing_member_id', async () => {
  const app = createApp()
  const first = await (await post(app, good)).json()
  for (const phone of ['+966551234567', '966551234567', '0551234567', '(055) 123-4567']) {
    const error = await expectError(await post(app, { name: 'Other', country: 'SA', phone }), 409, 'PHONE_TAKEN')
    assert.equal(error.existing_member_id, first.id)
  }
})

test('PHONE_TAKEN: a member of another country cannot reuse the phone', async () => {
  const app = createApp()
  const first = await (await post(app, good)).json()
  const error = await expectError(await post(app, { name: 'Other', country: 'AE', phone: '+966551234567' }), 409, 'PHONE_TAKEN')
  assert.equal(error.existing_member_id, first.id)
})

test('same national digits in two countries are two different phones', async () => {
  const app = createApp()
  assert.equal((await post(app, { name: 'A', country: 'SA', phone: '0551234567' })).status, 201)
  assert.equal((await post(app, { name: 'B', country: 'AE', phone: '0551234567' })).status, 201)
})

test('an invalid or refused write does not take the phone', async () => {
  const app = createApp()
  await post(app, { ...good, name: '' })
  assert.equal((await post(app, good)).status, 201)
})

test('race: 50 simultaneous writes of one phone in mixed spellings give one 201 and 49 PHONE_TAKEN', async () => {
  const app = createApp()
  const spellings = ['+966551234567', '966551234567', '0551234567', '055 123 4567', '(055)123-4567']
  const responses = await Promise.all(
    Array.from({ length: 50 }, (_, i) => post(app, { name: `Racer ${i}`, country: 'SA', phone: spellings[i % 5] })),
  )
  const created = responses.filter((r) => r.status === 201)
  const refused = responses.filter((r) => r.status === 409)
  assert.equal(created.length, 1)
  assert.equal(refused.length, 49)
  const winner = await created[0]!.json()
  for (const res of refused) assert.equal((await res.json()).error.existing_member_id, winner.id)
})

// ---------------------------------------------------------------------------
// GET /members/lookup
// ---------------------------------------------------------------------------

// Three members: a Saudi one, a Bahraini one, and a Saudi one carrying an AE SIM.
async function seeded() {
  const app = createApp()
  const noura = await (await post(app, { name: 'Noura', country: 'SA', phone: '055 123 4567' })).json()
  const ali = await (await post(app, { name: 'Ali', country: 'BH', phone: '3312 3456' })).json()
  const sara = await (await post(app, { name: 'Sara', country: 'SA', phone: '+971501234567' })).json()
  return { app, noura, ali, sara }
}

type Who = 'noura' | 'ali' | 'sara'

const FOUND: [rule: string, phone: string, country: string | undefined, who: Who][] = [
  ['spec example: no plus', '966551234567', undefined, 'noura'],
  ['spec example: plus', '+966551234567', undefined, 'noura'],
  ['spec example: national with country', '055 123 4567', 'SA', 'noura'],
  ['international with the agreeing country', '+966551234567', 'SA', 'noura'],
  ['no plus with the agreeing country', '966551234567', 'SA', 'noura'],
  ['cleaning applies to lookups too', '+966 (55) 123-4567', undefined, 'noura'],
  ['BH national with country', '33123456', 'BH', 'ali'],
  ['BH international', '+97333123456', undefined, 'ali'],
  ['BH no plus with the agreeing country', '97333123456', 'BH', 'ali'],
  ['foreign SIM found by its international spelling', '+971501234567', undefined, 'sara'],
  ['foreign SIM found by national spelling in the SIM country', '0501234567', 'AE', 'sara'],
]

for (const [rule, phone, country, who] of FOUND) {
  test(`lookup 200 | ${rule} | "${phone}" country=${country ?? 'none'} → ${who}`, async () => {
    const s = await seeded()
    const res = await lookup(s.app, phone, country)
    assert.equal(res.status, 200)
    assert.deepEqual(await res.json(), s[who])
  })
}

const LOOKUP_ERRORS: [rule: string, phone: string, country: string | undefined, status: number, code: string][] = [
  ['nobody has this international number', '+966559999999', undefined, 404, 'NOT_FOUND'],
  ['nobody has this national number', '0559999999', 'SA', 404, 'NOT_FOUND'],
  ['same digits read in another country are another phone', '0551234567', 'AE', 404, 'NOT_FOUND'],
  ['foreign SIM read in the member country is another phone', '0501234567', 'SA', 404, 'NOT_FOUND'],
  ['AE/SA national without country', '0551234567', undefined, 422, 'PHONE_NEEDS_COUNTRY'],
  ['BH national without country', '33123456', undefined, 422, 'PHONE_NEEDS_COUNTRY'],
  ['unknown national number without country', '0559999999', undefined, 422, 'PHONE_NEEDS_COUNTRY'],
  ['national that does not fit the given country: BH shape, SA', '33123456', 'SA', 422, 'INVALID_PHONE'],
  ['national that does not fit the given country: SA shape, BH', '0551234567', 'BH', 422, 'INVALID_PHONE'],
  ['SA number with country AE', '+966551234567', 'AE', 422, 'PHONE_COUNTRY_MISMATCH'],
  ['SA number, no plus, with country BH', '966551234567', 'BH', 422, 'PHONE_COUNTRY_MISMATCH'],
  ['BH number with country SA', '+97333123456', 'SA', 422, 'PHONE_COUNTRY_MISMATCH'],
  ['mismatch is judged by dial code, not by the member country', '+971501234567', 'SA', 422, 'PHONE_COUNTRY_MISMATCH'],
  ['mismatch even when nobody has the number', '+966559999999', 'AE', 422, 'PHONE_COUNTRY_MISMATCH'],
  ['garbage without country is invalid, not needs-country', 'abc', undefined, 422, 'INVALID_PHONE'],
  ['00 prefix', '00966551234567', undefined, 422, 'INVALID_PHONE'],
  ['00 prefix with country', '00966551234567', 'SA', 422, 'INVALID_PHONE'],
  ['landline', '+966112345678', undefined, 422, 'INVALID_PHONE'],
  ['landline national with country', '0112345678', 'SA', 422, 'INVALID_PHONE'],
  ['wrong length', '055123456', 'SA', 422, 'INVALID_PHONE'],
  ['empty phone', '', undefined, 422, 'INVALID_PHONE'],
  ['country not one of the three', '+966551234567', 'KW', 422, 'VALIDATION'],
  ['country lowercase', '0551234567', 'sa', 422, 'VALIDATION'],
  ['country empty', '0551234567', '', 422, 'VALIDATION'],
  ['bad country and bad phone together', 'abc', 'XX', 422, 'VALIDATION'],
]

for (const [rule, phone, country, status, code] of LOOKUP_ERRORS) {
  test(`lookup ${status} ${code} | ${rule} | "${phone}" country=${country ?? 'none'}`, async () => {
    const { app } = await seeded()
    await expectError(await lookup(app, phone, country), status, code)
  })
}

test('lookup VALIDATION | phone parameter missing', async () => {
  const { app } = await seeded()
  await expectError(await app.request('/members/lookup'), 422, 'VALIDATION')
  await expectError(await app.request('/members/lookup?country=SA'), 422, 'VALIDATION')
})

test('lookup accepts the three raw URLs from the spec', async () => {
  const { app, noura } = await seeded()
  for (const url of [
    '/members/lookup?phone=966551234567',
    '/members/lookup?phone=%2B966551234567',
    '/members/lookup?phone=055%20123%204567&country=SA',
  ]) {
    const res = await app.request(url)
    assert.equal(res.status, 200)
    assert.deepEqual(await res.json(), noura)
  }
})
