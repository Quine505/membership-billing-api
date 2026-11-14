import { serve } from '@hono/node-server'
import { createApp } from './app.ts'

serve({ fetch: createApp().fetch, hostname: '0.0.0.0', port: 8080 }, () => {
  console.log('listening on 0.0.0.0:8080')
})

// Node ignores these signals when it is process 1 in a container. Exit so Ctrl+C and `docker stop` are instant.
process.on('SIGINT', () => process.exit(0))
process.on('SIGTERM', () => process.exit(0))
