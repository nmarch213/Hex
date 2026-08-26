#!/usr/bin/env node

import { open } from "node:fs/promises"

const [tokenPath, expectedStatusText, origin = "http://127.0.0.1:8787"] =
  process.argv.slice(2)
const expectedStatus = Number(expectedStatusText)

if (
  tokenPath === undefined ||
  !Number.isInteger(expectedStatus) ||
  expectedStatus < 100 ||
  expectedStatus > 599
) {
  process.stderr.write("Usage: authenticated-health-check.mjs TOKEN_FILE STATUS [ORIGIN]\n")
  process.exit(2)
}

let token
if (tokenPath === "-") {
  token = process.env.HEX_DEVICE_CREDENTIAL
} else {
  const handle = await open(tokenPath, "r")
  try {
    const buffer = Buffer.alloc(66)
    // A newly opened regular file and `/dev/stdin` both begin at their current
    // offset. A null position also permits the pipe used by credential rotation;
    // positioned reads fail with ESPIPE on that boundary.
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, null)
    if (bytesRead > 65) {
      throw new Error("credential file is too large")
    }
    const raw = buffer.subarray(0, bytesRead).toString("utf8")
    token = raw.endsWith("\n") ? raw.slice(0, -1) : raw
  } finally {
    await handle.close()
  }
}

if (!/^[0-9a-f]{64}$/.test(token)) {
  throw new Error("credential file is invalid")
}

const response = await fetch(new URL("/health", origin), {
  headers: { authorization: `Bearer ${token}` },
  signal: AbortSignal.timeout(5_000)
})
token = undefined

if (response.status !== expectedStatus) {
  process.stderr.write(
    `Authenticated health check returned HTTP ${response.status}; expected ${expectedStatus}.\n`
  )
  process.exit(1)
}
