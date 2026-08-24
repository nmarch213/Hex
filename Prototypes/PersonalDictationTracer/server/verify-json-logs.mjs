#!/usr/bin/env node

import { readFile } from "node:fs/promises"

const [logPath, expectedRequestID] = process.argv.slice(2)

if (
  logPath === undefined ||
  expectedRequestID === undefined ||
  !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
    expectedRequestID
  )
) {
  process.stderr.write("Usage: verify-json-logs.mjs LOG_FILE REQUEST_ID\n")
  process.exit(2)
}

const lines = (await readFile(logPath, "utf8"))
  .split("\n")
  .filter((line) => line.length > 0)

if (lines.length === 0) {
  throw new Error("service log is empty")
}

const records = lines.map((line) => JSON.parse(line))
const matchingCompletions = records.filter(
  (record) => {
    const event = record.annotations
    return (
      event !== null &&
      typeof event === "object" &&
      event.event === "http_request_completed" &&
      event.method === "POST" &&
      event.route === "/v1/transcribe" &&
      event.status === 200 &&
      event.outcome === "success" &&
      event.replayed === false
    )
  }
)

if (matchingCompletions.length !== 1) {
  throw new Error("request did not emit exactly one JSON completion event")
}

if (JSON.stringify(records).includes(expectedRequestID)) {
  throw new Error("request identifier leaked into service logs")
}
