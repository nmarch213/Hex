import assert from "node:assert/strict"
import { mkdtemp, rm } from "node:fs/promises"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import {
  Effect,
  Fiber,
  Layer,
  Logger,
  Option,
  Redacted,
  Schema
} from "effect"

import { fakeSpeechRecognitionLayer } from "./adapters/fake-speech-recognition.js"
import { sqliteDeviceRegistryLayer } from "./adapters/sqlite-device-registry.js"
import { DeviceRegistry } from "./application/device-registry.js"
import { UpstreamProcessEpochSchema } from "./application/transcription-idempotency.js"
import {
  DeviceDisplayNameSchema,
  DevicePlatformSchema
} from "./domain/device-principal.js"
import { launchNodeServer } from "./node-server.js"
import { observabilityLayer } from "./observability.js"
import {
  attributeMap,
  decodeLogExport,
  decodeMetricExport,
  decodeTraceExport,
  type OtlpAttribute,
  type OtlpSpan
} from "./otlp-protobuf.test.js"

const TestRequestID = "8d758ae5-705c-4e1b-a62f-0defe5b830a5"
const TestTranscript = "OTLP_TRANSCRIPT_MUST_NOT_EXPORT"
const PrivacyProbeURL = "https://privacy.example.invalid/collector-path"
const PrivacyProbeFilePath = "/private/hex/otlp-private-audio.wav"

const makeAudio = () => {
  const bytes = new Uint8Array(48)
  const view = new DataView(bytes.buffer)
  bytes.set(new TextEncoder().encode("RIFF"), 0)
  view.setUint32(4, 40, true)
  bytes.set(new TextEncoder().encode("WAVE"), 8)
  bytes.set(new TextEncoder().encode("fmt "), 12)
  view.setUint32(16, 16, true)
  view.setUint16(20, 3, true)
  view.setUint16(22, 1, true)
  view.setUint32(24, 16_000, true)
  view.setUint32(28, 64_000, true)
  view.setUint16(32, 4, true)
  view.setUint16(34, 32, true)
  bytes.set(new TextEncoder().encode("data"), 36)
  view.setUint32(40, 4, true)
  return bytes
}

const listen = (server: ReturnType<typeof createServer>) =>
  new Promise<number>((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => {
      const address = server.address()
      assert.ok(address !== null && typeof address !== "string")
      resolve(address.port)
    })
  })

const close = (server: ReturnType<typeof createServer>) =>
  new Promise<void>((resolve, reject) =>
    server.close((error) => error === undefined ? resolve() : reject(error))
  )

const waitFor = async (
  predicate: () => boolean,
  message: string
): Promise<void> => {
  const deadline = Date.now() + 8_000
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  throw new Error(message)
}

const assertResourceIdentity = (attributes: ReadonlyArray<OtlpAttribute>) => {
  const resource = attributeMap(attributes)
  assert.equal(resource.get("service.name"), "hex-personal-dictation")
  assert.equal(resource.get("service.version"), "0.0.1")
  assert.equal(resource.get("deployment.environment.name"), "development")
  assert.equal(resource.get("service.revision"), "development")
}

const assertDescendsFromRoot = (
  span: OtlpSpan,
  byID: ReadonlyMap<string, OtlpSpan>,
  root: OtlpSpan
) => {
  let current = span
  const seen = new Set<string>()
  while (current.spanID !== root.spanID) {
    assert.equal(current.traceID, root.traceID)
    assert.ok(current.parentSpanID, `${current.name} must have a parent span`)
    assert.equal(seen.has(current.spanID), false, "span parent graph must not cycle")
    seen.add(current.spanID)
    const parent = byID.get(current.parentSpanID)
    assert.ok(parent, `${current.name} parent must be exported`)
    current = parent
  }
}

const assertMetricLabels = (
  name: string,
  attributes: ReadonlyArray<OtlpAttribute>
) => {
  const labels = attributeMap(attributes)
  const expected: Readonly<Record<string, Readonly<Record<string, ReadonlySet<string>>>>> = {
    hex_http_server_requests_total: {
      route: new Set(["/v1/transcribe"]),
      method: new Set(["POST"]),
      outcome: new Set(["success"]),
      status_class: new Set(["2xx"]),
      replayed: new Set(["false"])
    },
    hex_http_server_duration_ms: {
      unit: new Set(["ms"]),
      route: new Set(["/v1/transcribe"]),
      method: new Set(["POST"]),
      outcome: new Set(["success"]),
      status_class: new Set(["2xx"]),
      replayed: new Set(["false"])
    },
    hex_dictation_stage_duration_ms: {
      unit: new Set(["ms"]),
      stage: new Set([
        "authentication",
        "runtime_readiness",
        "audio_body_read",
        "audio_parse",
        "audio_digest",
        "idempotency_begin",
        "inference_admission",
        "recognition_request",
        "idempotency_complete",
        "inference_release"
      ])
    },
    hex_dictation_audio_bytes: { unit: new Set(["By"]) },
    hex_dictation_audio_duration_ms: { unit: new Set(["ms"]) }
  }
  const allowed = expected[name]
  if (allowed === undefined) assert.fail(`unexpected metric ${name}`)
  for (const [key, value] of labels) {
    const values: ReadonlySet<string> | undefined = allowed[key]
    if (values === undefined) {
      assert.fail(`${name} emitted non-bounded label ${key}`)
    }
    if (typeof value !== "string") {
      assert.fail(`${name}.${key} must be a string label`)
    }
    assert.equal(values.has(value), true, `${name}.${key} has unexpected value`)
  }
}

const isBoundedNumericAttribute = (
  value: OtlpAttribute["value"],
  maximum: number
) =>
  (typeof value === "number" || typeof value === "bigint") &&
  Number(value) >= 0 &&
  Number(value) <= maximum

const assertSpanAttributes = (span: OtlpSpan) => {
  const allowed: Readonly<Record<string, (value: OtlpAttribute["value"]) => boolean>> = {
    "http.request.method": (value) => value === "POST",
    "http.route": (value) => value === "/v1/transcribe",
    "http.response.status_code": (value) => value === 200n || value === 200,
    "service.version": (value) => value === "0.0.1",
    "service.revision": (value) => value === "development",
    "hex.outcome": (value) => value === "success",
    "hex.replayed": (value) => value === "false" || value === false,
    "hex.duration_ms": (value) => isBoundedNumericAttribute(value, 90_000),
    "hex.stage": (value) =>
      typeof value === "string" && new Set([
        "authentication",
        "runtime_readiness",
        "audio_body_read",
        "audio_parse",
        "audio_digest",
        "idempotency_begin",
        "inference_admission",
        "recognition_request",
        "idempotency_complete",
        "inference_release"
      ]).has(value),
    "hex.required_capability": (value) => value === "dictation:write",
    "hex.audio.bytes": (value) => isBoundedNumericAttribute(value, 20 * 1_024 * 1_024),
    "hex.audio.duration_ms": (value) => isBoundedNumericAttribute(value, 300_000),
    "hex.idempotency.decision": (value) => value === "claimed",
    "hex.span.outcome": (value) =>
      value === "success" || value === "failure"
  }
  for (const attribute of span.attributes) {
    const accepts = allowed[attribute.key]
    assert.ok(accepts, `${span.name} emitted unallowlisted span attribute ${attribute.key}`)
    assert.equal(
      accepts(attribute.value),
      true,
      `${span.name}.${attribute.key} emitted an unbounded value`
    )
  }
}

test("live Node server exports the bounded OTLP contract and flushes on scope shutdown", async () => {
  const requests: Array<{ readonly path: string; readonly body: Uint8Array }> = []
  const receiver = createServer((request, response) => {
    const chunks: Array<Buffer> = []
    request.on("data", (chunk: Buffer) => chunks.push(chunk))
    request.on("end", () => {
      requests.push({
        path: request.url ?? "",
        body: Buffer.concat(chunks)
      })
      response.writeHead(200)
      response.end()
    })
  })
  const receiverPort = await listen(receiver)

  const reservation = createServer()
  const servicePort = await listen(reservation)
  await close(reservation)

  const directory = await mkdtemp(join(tmpdir(), "hex-node-observability-"))
  const credential = await Effect.runPromise(
    Effect.gen(function* () {
      const registry = yield* DeviceRegistry
      return yield* registry.enroll({
        displayName: Schema.decodeUnknownSync(DeviceDisplayNameSchema)(
          "OTLP contract test"
        ),
        platform: Schema.decodeUnknownSync(DevicePlatformSchema)("ios"),
        capabilities: ["dictation:write"]
      })
    }).pipe(
      Effect.map((enrollment) => enrollment.credential),
      Effect.provide(sqliteDeviceRegistryLayer(join(directory, "devices.sqlite")))
    )
  )
  const credentialValue = Redacted.value(credential)
  const runtimeLayer = observabilityLayer(
    {
      otlpBaseURL: Option.some(
        new URL(`http://127.0.0.1:${receiverPort}`)
      ),
      environment: "development"
    },
    "development"
  ).pipe(Layer.provide(Logger.json))
  const serverFiber = Effect.runFork(
    launchNodeServer(
      {
        host: "127.0.0.1",
        port: servicePort,
        idempotencyDatabasePath: join(directory, "idempotency.sqlite"),
        deviceRegistryDatabasePath: join(directory, "devices.sqlite"),
        upstreamProcessEpoch: Schema.decodeUnknownSync(
          UpstreamProcessEpochSchema
        )("0".repeat(64)),
        serviceBuildRevision: "development"
      },
      fakeSpeechRecognitionLayer(TestTranscript),
      runtimeLayer
    )
  )

  try {
    const postTranscription = () =>
      fetch(
        `http://127.0.0.1:${servicePort}/v1/transcribe?url=${encodeURIComponent(
          PrivacyProbeURL
        )}&path=${encodeURIComponent(PrivacyProbeFilePath)}`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${credentialValue}`,
            "content-type": "audio/wav",
            "x-hex-request-id": TestRequestID
          },
          body: makeAudio()
        }
      )
    let response: Response | undefined
    const deadline = Date.now() + 5_000
    while (response === undefined && Date.now() < deadline) {
      try {
        response = await postTranscription()
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 20))
      }
    }
    assert.ok(response, "HTTP server did not become ready")
    assert.equal(response.status, 200)
    assert.equal(
      (await response.json() as { readonly transcript: string }).transcript,
      TestTranscript
    )

    await waitFor(
      () =>
        ["/v1/logs", "/v1/metrics", "/v1/traces"].every((path) =>
          requests.some((request) => request.path === path)
        ),
      "OTLP exporter did not flush logs, metrics, and traces"
    )

    assert.deepEqual(
      new Set(requests.map((request) => request.path)),
      new Set(["/v1/logs", "/v1/metrics", "/v1/traces"])
    )

    const bodies = (path: string) =>
      requests
        .filter((request) => request.path === path)
        .map((request) => request.body)
    const traceExports = bodies("/v1/traces").flatMap(decodeTraceExport)
    const metricExports = bodies("/v1/metrics").flatMap(decodeMetricExport)
    const logExports = bodies("/v1/logs").flatMap(decodeLogExport)
    for (const exportBatch of [...traceExports, ...metricExports, ...logExports]) {
      assertResourceIdentity(exportBatch.resource.attributes)
    }

    const spans = traceExports.flatMap((batch) => batch.spans)
    for (const span of spans) assertSpanAttributes(span)
    const root = spans.find((span) => span.name === "hex.http.request")
    assert.ok(root)
    const byID = new Map(spans.map((span) => [span.spanID, span]))
    const expectedSpanNames = new Set([
      "hex.http.request",
      "hex.authentication.resolve",
      "hex.dictation.authentication",
      "hex.dictation.audio_body_read",
      "hex.dictation.audio_parse",
      "hex.dictation.audio_digest",
      "hex.dictation.runtime_readiness",
      "hex.dictation.idempotency_begin",
      "hex.dictation.inference_admission",
      "hex.dictation.recognition_request",
      "hex.dictation.idempotency_complete",
      "hex.dictation.inference_release",
      "hex.dictation.process"
    ])
    for (const name of expectedSpanNames) {
      const span = spans.find((candidate) => candidate.name === name)
      assert.ok(span, `missing expected OTLP span ${name}`)
      if (span.spanID !== root.spanID) assertDescendsFromRoot(span, byID, root)
    }

    const metrics = metricExports.flatMap((batch) => batch.metrics)
    const expectedMetricNames = new Set([
      "hex_http_server_requests_total",
      "hex_http_server_duration_ms",
      "hex_dictation_stage_duration_ms",
      "hex_dictation_audio_bytes",
      "hex_dictation_audio_duration_ms"
    ])
    const hexMetrics = metrics.filter((metric) => metric.name.startsWith("hex_"))
    assert.deepEqual(
      new Set(hexMetrics.map((metric) => metric.name)),
      expectedMetricNames
    )
    for (const metric of hexMetrics) {
      for (const point of metric.pointAttributes) {
        assertMetricLabels(metric.name, point)
      }
    }

    const serializedTelemetry = Buffer.concat(
      requests.map((request) => Buffer.from(request.body))
    ).toString("utf8")
    for (const forbidden of [
      credentialValue,
      `Bearer ${credentialValue}`,
      "authorization",
      TestRequestID,
      TestTranscript,
      PrivacyProbeURL,
      PrivacyProbeFilePath,
      "RIFF"
    ]) {
      assert.equal(
        serializedTelemetry.includes(forbidden),
        false,
        `OTLP payload must not contain ${forbidden}`
      )
    }
  } finally {
    await Effect.runPromise(Fiber.interrupt(serverFiber))
    await close(receiver)
    await rm(directory, { recursive: true, force: true })
  }
})
