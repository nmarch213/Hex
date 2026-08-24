import assert from "node:assert/strict"
import { createServer } from "node:http"
import test from "node:test"

import { Effect, Option } from "effect"

import { TranscriptionClaimLostError } from "./application/transcription-idempotency.js"
import {
  observabilityLayer,
  recordRequestCompletion,
  withContentFreeSpan
} from "./observability.js"
import {
  attributeMap,
  decodeLogExport,
  decodeMetricExport,
  decodeTraceExport
} from "./otlp-protobuf.test.js"

const ClaimLostRequestIDProbe = "00000000-0000-4000-8000-00000000f00d"

test("flushes Effect logs, metrics, and bounded spans over OTLP protobuf on scope shutdown", async () => {
  const requests: Array<{
    readonly path: string
    readonly contentType: string | undefined
    readonly body: Buffer
  }> = []
  const receiver = createServer((request, response) => {
    const chunks: Array<Buffer> = []
    request.on("data", (chunk: Buffer) => chunks.push(chunk))
    request.on("end", () => {
      requests.push({
        path: request.url ?? "",
        contentType: request.headers["content-type"],
        body: Buffer.concat(chunks)
      })
      response.writeHead(200)
      response.end()
    })
  })

  await new Promise<void>((resolve, reject) => {
    receiver.once("error", reject)
    receiver.listen(0, "127.0.0.1", () => resolve())
  })

  try {
    const address = receiver.address()
    assert.ok(address !== null && typeof address !== "string")
    const layer = observabilityLayer(
      {
        otlpBaseURL: Option.some(
          new URL(`http://127.0.0.1:${address.port}`)
        ),
        environment: "development"
      },
      "development"
    )

    await Effect.runPromise(
      Effect.gen(function* () {
        yield* recordRequestCompletion({
          route: "/health",
          method: "GET",
          outcome: "success",
          statusClass: "2xx",
          replayed: undefined,
          durationMilliseconds: 3
        })
        yield* Effect.logInfo("telemetry_smoke")
        yield* Effect.void.pipe(
          Effect.withSpan("hex.telemetry.smoke", {
            attributes: { "hex.outcome": "success" }
          })
        )
        yield* withContentFreeSpan(
          "hex.telemetry.claim_lost",
          Effect.fail(new TranscriptionClaimLostError({}))
        ).pipe(
          Effect.catchAll(() => Effect.void)
        )
      }).pipe(Effect.provide(layer), Effect.scoped)
    )

    assert.deepEqual(
      new Set(requests.map((request) => request.path)),
      new Set(["/v1/logs", "/v1/metrics", "/v1/traces"])
    )
    for (const request of requests) {
      assert.equal(request.contentType, "application/x-protobuf")
      assert.equal(request.body.byteLength > 0, true)
    }

    const exports = [
      ...requests
        .filter((request) => request.path === "/v1/logs")
        .flatMap((request) => decodeLogExport(request.body)),
      ...requests
        .filter((request) => request.path === "/v1/metrics")
        .flatMap((request) => decodeMetricExport(request.body)),
      ...requests
        .filter((request) => request.path === "/v1/traces")
        .flatMap((request) => decodeTraceExport(request.body))
    ]
    for (const exported of exports) {
      const resource = attributeMap(exported.resource.attributes)
      assert.equal(resource.get("service.name"), "hex-personal-dictation")
      assert.equal(resource.get("service.version"), "0.0.1")
      assert.equal(resource.get("deployment.environment.name"), "development")
      assert.equal(resource.get("service.revision"), "development")
    }
    const traceBodies = requests
      .filter((request) => request.path === "/v1/traces")
      .map((request) => request.body)
    const traceSpans = traceBodies.flatMap((body) =>
      decodeTraceExport(body).flatMap((exported) => exported.spans)
    )
    assert.equal(
      traceSpans.some((span) => span.name === "hex.telemetry.claim_lost"),
      true
    )
    const serializedTraces = Buffer.concat(traceBodies).toString("utf8")
    for (const forbidden of [
      ClaimLostRequestIDProbe,
      process.cwd(),
      "observability.test.ts"
    ]) {
      assert.equal(serializedTraces.includes(forbidden), false)
    }
  } finally {
    await new Promise<void>((resolve, reject) =>
      receiver.close((error) => error === undefined ? resolve() : reject(error))
    )
  }
})

test("keeps a lost-claim error free of the caller request ID before telemetry sees it", () => {
  const error = new TranscriptionClaimLostError({})
  assert.equal(error._tag, "TranscriptionClaimLostError")
  assert.equal(Object.hasOwn(error, "requestID"), false)
  assert.deepEqual(Object.keys(error), ["_tag"])
})
