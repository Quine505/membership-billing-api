import type { Hono } from 'hono'
import { isCountry } from './countries.ts'
import { ApiError, readBody, validation } from './http.ts'
import { nationalToE164, parsePhone } from './phone.ts'
import type { Member, Store } from './store.ts'

const invalidPhone = () => new ApiError(422, 'INVALID_PHONE', 'phone is not a valid AE, SA or BH mobile')

export function memberRoutes(app: Hono, store: Store) {
  app.post('/members', async (c) => {
    const body = await readBody(c)

    if (typeof body.name !== 'string') throw validation('name must be a string')
    const name = body.name.trim() // Trim whitespace
    const nameLength = [...name].length
    if (nameLength < 1 || nameLength > 120) throw validation('name must be 1 to 120 characters')
    if (!isCountry(body.country)) throw validation('country must be AE, SA or BH')
    if (typeof body.phone !== 'string') throw validation('phone must be a string')

    const parsed = parsePhone(body.phone)
    if (!parsed) throw invalidPhone()
    // A national number is read in the member's own country. An international one may be foreign.
    const phone = parsed.kind === 'international' ? parsed.e164 : nationalToE164(parsed.digits, body.country)
    if (!phone) throw invalidPhone()

    // No await between this check and the insert, so two racing requests cannot both pass.
    const existing = store.membersByPhone.get(phone)
    if (existing) {
      throw new ApiError(409, 'PHONE_TAKEN', 'another member already has this phone', {
        existing_member_id: existing.id,
      })
    }
    const member: Member = { id: crypto.randomUUID(), name, country: body.country, phone }
    store.members.set(member.id, member)
    store.membersByPhone.set(phone, member)
    return c.json(member, 201)
  })

  app.get('/members/lookup', (c) => {
    const rawPhone = c.req.query('phone')
    const country = c.req.query('country')
    if (rawPhone === undefined) throw validation('phone is required')
    if (country !== undefined && !isCountry(country)) throw validation('country must be AE, SA or BH')

    const parsed = parsePhone(rawPhone)
    if (!parsed) throw invalidPhone()

    let phone: string | null
    if (parsed.kind === 'international') {
      if (country && country !== parsed.country) {
        throw new ApiError(422, 'PHONE_COUNTRY_MISMATCH', 'country does not match the dial code')
      }
      phone = parsed.e164
    } else {
      if (!country) throw new ApiError(422, 'PHONE_NEEDS_COUNTRY', 'a national number needs a country')
      phone = nationalToE164(parsed.digits, country)
      if (!phone) throw invalidPhone()
    }

    const member = store.membersByPhone.get(phone)
    if (!member) throw new ApiError(404, 'NOT_FOUND', 'no member has this phone')
    return c.json(member)
  })
}
