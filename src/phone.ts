import { COUNTRIES, COUNTRY_CODES, type Country } from './countries.ts'

// A phone that passed cleaning and fits one of the three spellings.
// International numbers already know their country. National ones do not.
export type Phone =
  | { kind: 'international'; country: Country; e164: string }
  | { kind: 'national'; digits: string }

// Rules 1 and 2. Returns null when the phone is INVALID_PHONE.
export function parsePhone(raw: string): Phone | null {
  const cleaned = raw.replace(/[ \-()]/g, '')
  if (!/^\+?\d+$/.test(cleaned)) return null

  const hasPlus = cleaned.startsWith('+')
  const digits = hasPlus ? cleaned.slice(1) : cleaned

  for (const country of COUNTRY_CODES) {
    const { dial, mobile } = COUNTRIES[country]
    if (digits.startsWith(dial) && mobile.test(digits.slice(dial.length))) {
      return { kind: 'international', country, e164: '+' + digits }
    }
  }

  if (hasPlus) return null
  const fitsSomeCountry = COUNTRY_CODES.some((c) => nationalToE164(digits, c) !== null)
  return fitsSomeCountry ? { kind: 'national', digits } : null
}

// Reads national digits in one country. Returns null when they do not fit its shape.
export function nationalToE164(digits: string, country: Country): string | null {
  const { dial, trunk, mobile } = COUNTRIES[country]
  if (!digits.startsWith(trunk)) return null
  const rest = digits.slice(trunk.length)
  return mobile.test(rest) ? '+' + dial + rest : null
}
