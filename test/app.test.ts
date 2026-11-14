import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createApp } from '../src/app.ts'

test('GET /health is 200', async () => {
  assert.equal((await createApp().request('/health')).status, 200)
})

test('an unknown route is 404 NOT_FOUND in the error shape', async () => {
  const res = await createApp().request('/nope')
  const body = await res.json()
  assert.equal(res.status, 404)
  assert.deepEqual(Object.keys(body.error), ['code', 'message'])
  assert.equal(body.error.code, 'NOT_FOUND')
})
