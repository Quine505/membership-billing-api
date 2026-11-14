// One row per country, straight from the spec table.
// `trunk` is the prefix a national number carries before the mobile digits.
export const COUNTRIES = {
  AE: { dial: '971', trunk: '0', mobile: /^5\d{8}$/ },
  SA: { dial: '966', trunk: '0', mobile: /^5\d{8}$/ },
  BH: { dial: '973', trunk: '', mobile: /^3\d{7}$/ },
} as const

export type Country = keyof typeof COUNTRIES

export const COUNTRY_CODES = Object.keys(COUNTRIES) as Country[]

export function isCountry(value: unknown): value is Country {
  return typeof value === 'string' && Object.hasOwn(COUNTRIES, value)
}
