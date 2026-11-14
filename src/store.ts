import type { Country } from './countries.ts'

export type Member = { id: string; name: string; country: Country; phone: string }

// All state lives here, in memory. Each run starts empty.
export type Store = {
  members: Map<string, Member>
  membersByPhone: Map<string, Member>
}

export function createStore(): Store {
  return { members: new Map(), membersByPhone: new Map() }
}
