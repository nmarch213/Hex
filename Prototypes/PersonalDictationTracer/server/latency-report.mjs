const PrometheusOrigin = "http://127.0.0.1:9090"

const reports = [
  ["requests_24h", "hex:http_server_requests:count_24h"],
  ["http_p50_ms_24h", "hex:http_server_duration_ms:p50_24h"],
  ["http_p95_ms_24h", "hex:http_server_duration_ms:p95_24h"],
  ["http_p99_ms_24h", "hex:http_server_duration_ms:p99_24h"],
  ["service_p95_ms_by_audio_duration_24h", "hex:dictation_service_duration_ms:p95_24h"],
  ["recognition_p50_realtime_factor_by_audio_duration_24h", "hex:recognition_realtime_factor:p50_24h"],
  ["recognition_p95_realtime_factor_by_audio_duration_24h", "hex:recognition_realtime_factor:p95_24h"],
  ["recognition_p99_realtime_factor_by_audio_duration_24h", "hex:recognition_realtime_factor:p99_24h"],
  ["stage_p50_ms_24h", "hex:dictation_stage_duration_ms:p50_24h"],
  ["stage_p95_ms_24h", "hex:dictation_stage_duration_ms:p95_24h"],
  ["stage_p99_ms_24h", "hex:dictation_stage_duration_ms:p99_24h"]
]

const query = async (expression) => {
  const url = new URL("/api/v1/query", PrometheusOrigin)
  url.searchParams.set("query", expression)
  const response = await fetch(url, { signal: AbortSignal.timeout(5_000) })
  if (!response.ok) {
    throw new Error(`Prometheus returned HTTP ${response.status}`)
  }
  const payload = await response.json()
  if (payload.status !== "success" || payload.data?.resultType !== "vector") {
    throw new Error("Prometheus returned an unexpected query response")
  }
  return payload.data.result.flatMap(({ metric, value }) => {
    const numericValue = Number(value[1])
    return Number.isFinite(numericValue)
      ? [{
          labels: Object.fromEntries(
            Object.entries(metric)
              .filter(([key]) => key !== "__name__")
              .sort(([left], [right]) => left.localeCompare(right))
          ),
          value: numericValue
        }]
      : []
  })
}

try {
  const result = {}
  for (const [name, expression] of reports) {
    result[name] = await query(expression)
  }
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
} catch (error) {
  const message = error instanceof Error ? error.message : String(error)
  process.stderr.write(`Could not read the Ronin latency baseline: ${message}\n`)
  process.exitCode = 1
}
