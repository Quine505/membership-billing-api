import type { Country } from './countries.ts'

export type Member = { id: string; name: string; country: Country; phone: string }
export type Plan = { id: string; country: Country; currency: string; monthly: number; joining_fee: number }
export type Agreement = { id: string; member_id: string; plan_id: string; start_date: string; due_day: number }

// All state lives here, in memory. Each run starts empty.
export type Store = {
  members: Map<string, Member>
  membersByPhone: Map<string, Member>
  plans: Map<string, Plan>
  agreements: Map<string, Agreement>
}

export function createStore(): Store {
  return { members: new Map(), membersByPhone: new Map(), plans: new Map(), agreements: new Map() }
}
