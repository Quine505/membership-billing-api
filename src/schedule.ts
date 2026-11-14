import { COUNTRIES } from './countries.ts'
import { dayNumber, daysInMonth, formatDate, parseDate, type Day } from './dates.ts'
import { mulDivRound } from './money.ts'
import type { Agreement, Plan } from './store.ts'

export type Invoice = {
  invoice_no: number
  due_date: string
  kind: 'FIRST' | 'MONTHLY'
  proration: { days: number; cycle_days: number } | null
  net: number
  vat: number
  total: number
  currency: string
}

// Months are counted as one number, year × 12 + month, so "next month" is + 1.
const monthIndex = (day: Day) => day.y * 12 + day.m - 1

// Rule 1: the due date in a month is min(due_day, days in that month).
function dueDate(month: number, dueDay: number): Day {
  const y = Math.floor(month / 12)
  const m = (((month % 12) + 12) % 12) + 1
  return { y, m, d: Math.min(dueDay, daysInMonth(y, m)) }
}

// The agreement's invoices whose due_date is between `from` and `to`, both inclusive.
export function invoicesBetween(agreement: Agreement, plan: Plan, from: Day, to: Day): Invoice[] {
  const { vatPercent } = COUNTRIES[plan.country]
  const start = parseDate(agreement.start_date)!
  const inRange = (day: Day) => dayNumber(from) <= dayNumber(day) && dayNumber(day) <= dayNumber(to)

  // Rule 4: VAT is the second and last rounding. The joining fee is already inside `net`.
  const invoice = (invoice_no: number, due: Day, kind: Invoice['kind'], proration: Invoice['proration'], net: number) => {
    const vat = mulDivRound(net, vatPercent, 100)
    return { invoice_no, due_date: formatDate(due), kind, proration, net, vat, total: net + vat, currency: plan.currency }
  }

  // N is the first due date strictly after the start: this month's if it is still ahead, else next month's.
  const startMonth = monthIndex(start)
  const dueThisMonth = dueDate(startMonth, agreement.due_day)
  const nMonth = dayNumber(dueThisMonth) > dayNumber(start) ? startMonth : startMonth + 1
  const n = dueDate(nMonth, agreement.due_day)
  const p = dueDate(nMonth - 1, agreement.due_day)

  const invoices: Invoice[] = []

  // Rule 2: invoice 1 is due on the start date and is prorated.
  if (inRange(start)) {
    const days = dayNumber(n) - dayNumber(start)
    const cycle_days = dayNumber(n) - dayNumber(p)
    const net = mulDivRound(plan.monthly, days, cycle_days) + plan.joining_fee
    invoices.push(invoice(1, start, 'FIRST', { days, cycle_days }, net))
  }

  // Rule 3: invoice 2 is due on N, invoice 3 a month later, and so on forever.
  // Only the months the range touches are visited.
  for (let month = Math.max(nMonth, monthIndex(from)); month <= monthIndex(to); month++) {
    const due = dueDate(month, agreement.due_day)
    if (inRange(due)) invoices.push(invoice(month - nMonth + 2, due, 'MONTHLY', null, plan.monthly))
  }

  return invoices
}
