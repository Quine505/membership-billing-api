// A calendar date with no time and no timezone. `m` is 1 to 12.
export type Day = { y: number; m: number; d: number }

export function daysInMonth(y: number, m: number): number {
  const leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0)
  return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]!
}

// Accepts only YYYY-MM-DD that names a real day. Anything else is null.
export function parseDate(value: unknown): Day | null {
  if (typeof value !== 'string') return null
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value)
  if (!match) return null
  const y = Number(match[1])
  const m = Number(match[2])
  const d = Number(match[3])
  if (m < 1 || m > 12 || d < 1 || d > daysInMonth(y, m)) return null
  return { y, m, d }
}

// Accepts only YYYY-MM. Returns the first and last day of that month.
export function parseMonth(value: unknown): { from: Day; to: Day } | null {
  if (typeof value !== 'string') return null
  const match = /^(\d{4})-(\d{2})$/.exec(value)
  if (!match) return null
  const y = Number(match[1])
  const m = Number(match[2])
  if (m < 1 || m > 12) return null
  return { from: { y, m, d: 1 }, to: { y, m, d: daysInMonth(y, m) } }
}

export function formatDate({ y, m, d }: Day): string {
  const pad = (n: number, width: number) => String(n).padStart(width, '0')
  return `${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}`
}

// Days since 1970-01-01. Subtract two of these to count the days between two dates.
export function dayNumber({ y, m, d }: Day): number {
  const date = new Date(0)
  date.setUTCFullYear(y, m - 1, d)
  return date.getTime() / 86_400_000
}
