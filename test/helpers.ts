import assert from 'node:assert/strict'
import { createApp } from '../src/app.ts'

export type App = ReturnType<typeof createApp>

export function post(app: App, path: string, body: unknown) {
  return app.request(path, {
    method: 'POST',
    body: JSON.stringify(body),
    headers: { 'content-type': 'application/json' },
  })
}

// POSTs and insists on a 201. Returns the created object.
export async function create(app: App, path: string, body: unknown) {
  const res = await post(app, path, body)
  const json = await res.json()
  assert.equal(res.status, 201, JSON.stringify(json))
  return json
}

// Asserts the status and the error code, and that the error has the contract's shape.
export async function expectError(res: Response, status: number, code: string) {
  const body = await res.json()
  assert.equal(res.status, status, JSON.stringify(body))
  assert.equal(body.error.code, code)
  assert.equal(typeof body.error.message, 'string')
  return body.error
}

// One valid mobile per country, for tests that only need "some member".
export const PHONES = { AE: '0501234567', SA: '0551234567', BH: '33123456' }
