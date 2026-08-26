import { setTimeout as delay } from "node:timers/promises"

const [serviceRevision, serviceInstanceID] = process.argv.slice(2)
if (
  !/^[0-9a-f]{40}$/.test(serviceRevision ?? "") ||
  !/^[0-9a-f]{64}$/.test(serviceInstanceID ?? "")
) {
  process.stderr.write("Usage: telemetry-health-check.mjs <40-character-lowercase-revision> <64-character-lowercase-instance-id>\n")
  process.exit(2)
}

const expression =
  `hex_http_server_requests_total{route="/health",outcome="success",service_revision="${serviceRevision}",service_instance_id="${serviceInstanceID}"}`
const deadline = Date.now() + 60_000

while (Date.now() < deadline) {
  try {
    const url = new URL("http://127.0.0.1:9090/api/v1/query")
    url.searchParams.set("query", expression)
    const response = await fetch(url, { signal: AbortSignal.timeout(5_000) })
    if (response.ok) {
      const payload = await response.json()
      const observed = payload.status === "success" &&
        payload.data?.resultType === "vector" &&
        payload.data.result.some(({ value }) => Number(value[1]) > 0)
      if (observed) {
        process.stdout.write("Prometheus observed the deployed service revision.\n")
        process.exit(0)
      }
    }
  } catch {
    // Export and scrape are asynchronous; retry within the bounded gate.
  }
  await delay(1_000)
}

process.stderr.write("Prometheus did not observe the deployed service revision within 60 seconds.\n")
process.exit(1)
