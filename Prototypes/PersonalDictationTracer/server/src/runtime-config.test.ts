import assert from "node:assert/strict"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { ConfigProvider, Effect, Either, Option } from "effect"

import { productionConfiguration } from "./runtime-config.js"

const generatedEpochFixture = "ab".repeat(32)
const generatedBuildRevisionFixture = "a".repeat(40)
const epochFixtureDirectory = mkdtempSync(join(tmpdir(), "hex-epoch-"))
const epochFixturePath = join(epochFixtureDirectory, "upstream-epoch")
writeFileSync(epochFixturePath, `${generatedEpochFixture}\n`, { mode: 0o600 })
test.after(() => rmSync(epochFixtureDirectory, { recursive: true, force: true }))

const loadProductionConfiguration = (values: ReadonlyMap<string, string>) => {
  const configuredValues = new Map([
    ["HEX_UPSTREAM_EPOCH_FILE", epochFixturePath],
    ["HEX_BUILD_REVISION", generatedBuildRevisionFixture]
  ])
  for (const [key, value] of values) {
    configuredValues.set(key, value)
  }
  return productionConfiguration.pipe(
    Effect.withConfigProvider(ConfigProvider.fromMap(configuredValues))
  )
}

test("defaults the production listener to loopback", async () => {
  const config = await Effect.runPromise(
    loadProductionConfiguration(new Map())
  )

  assert.equal(config.host, "127.0.0.1")
  assert.equal(config.port, 8787)
  assert.equal(config.idempotencyDatabasePath, "data/idempotency.sqlite")
  assert.equal(config.deviceRegistryDatabasePath, "data/devices.sqlite")
  assert.equal(
    config.upstreamURL.toString(),
    "http://127.0.0.1:8080/v1/audio/transcriptions"
  )
  assert.equal(config.upstreamProcessEpoch, generatedEpochFixture)
  assert.equal(config.serviceBuildRevision, generatedBuildRevisionFixture)
  assert.equal(Option.isNone(config.observability.otlpBaseURL), true)
  assert.equal(config.observability.environment, "production")
})

test("accepts only credential-free OTLP collector origins", async () => {
  const disabled = await Effect.runPromise(
    loadProductionConfiguration(
      new Map([["HEX_OTLP_BASE_URL", ""]])
    )
  )
  assert.equal(Option.isNone(disabled.observability.otlpBaseURL), true)

  for (const endpoint of [
    "http://otel-collector:4318",
    "http://localhost:4318",
    "http://127.0.0.1:4318",
    "http://[::1]:4318",
    "https://telemetry.example"
  ]) {
    const config = await Effect.runPromise(
      loadProductionConfiguration(
        new Map([["HEX_OTLP_BASE_URL", endpoint]])
      )
    )
    assert.equal(
      Option.getOrThrow(config.observability.otlpBaseURL).toString(),
      endpoint.endsWith("/") ? endpoint : `${endpoint}/`
    )
  }

  for (const endpoint of [
    "http://telemetry.example:4318",
    "https://user:password@telemetry.example",
    "https://telemetry.example/prefix",
    "https://telemetry.example?token=secret",
    "ftp://localhost:4318"
  ]) {
    const result = await Effect.runPromise(
      Effect.either(
        loadProductionConfiguration(
          new Map([["HEX_OTLP_BASE_URL", endpoint]])
        )
      )
    )
    assert.equal(Either.isLeft(result), true)
  }
})

test("requires an exact production build revision", async () => {
  const missing = await Effect.runPromise(
    Effect.either(
      productionConfiguration.pipe(
        Effect.withConfigProvider(
          ConfigProvider.fromMap(
            new Map([
              ["HEX_UPSTREAM_EPOCH_FILE", epochFixturePath]
            ])
          )
        )
      )
    )
  )
  assert.equal(Either.isLeft(missing), true)

  for (const invalidRevision of [
    "development",
    "a".repeat(39),
    "A".repeat(40),
    "z".repeat(40)
  ]) {
    const malformed = await Effect.runPromise(
      Effect.either(
        loadProductionConfiguration(
          new Map([["HEX_BUILD_REVISION", invalidRevision]])
        )
      )
    )
    assert.equal(Either.isLeft(malformed), true)
  }
})

test("rejects a missing or malformed upstream process epoch", async () => {
  const missing = await Effect.runPromise(
    Effect.either(
      productionConfiguration.pipe(
        Effect.withConfigProvider(
          ConfigProvider.fromMap(
            new Map()
          )
        )
      )
    )
  )
  assert.equal(Either.isLeft(missing), true)

  const directory = mkdtempSync(join(tmpdir(), "hex-invalid-epoch-"))
  const epochPath = join(directory, "upstream-epoch")
  try {
    writeFileSync(epochPath, "not-an-epoch\n", { mode: 0o600 })
    const malformed = await Effect.runPromise(
      Effect.either(
        loadProductionConfiguration(
          new Map([["HEX_UPSTREAM_EPOCH_FILE", epochPath]])
        )
      )
    )
    assert.equal(Either.isLeft(malformed), true)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test("accepts local plaintext and remote HTTPS upstreams", async () => {
  for (const upstreamURL of [
    "http://parakeet:8080/v1/audio/transcriptions",
    "http://localhost:8080/v1/audio/transcriptions",
    "http://127.0.0.1:8080/v1/audio/transcriptions",
    "http://[::1]:8080/v1/audio/transcriptions",
    "https://parakeet.example/v1/audio/transcriptions"
  ]) {
    const config = await Effect.runPromise(
      loadProductionConfiguration(
        new Map([
          ["HEX_UPSTREAM_URL", upstreamURL]
        ])
      )
    )
    assert.equal(config.upstreamURL.toString(), upstreamURL)
  }
})

test("rejects unsafe upstream URLs and volatile databases", async () => {
  for (const unsafeUpstream of [
    "ftp://parakeet.example/model",
    "http://parakeet.example/v1/audio/transcriptions",
    "http://parakeet.evil/v1/audio/transcriptions",
    "https://user:password@parakeet.example/v1/audio/transcriptions",
    "http://user:password@127.0.0.1:8080/v1/audio/transcriptions"
  ]) {
    const invalidUpstream = await Effect.runPromise(
      Effect.either(
        loadProductionConfiguration(
          new Map([
            ["HEX_UPSTREAM_URL", unsafeUpstream]
          ])
        )
      )
    )
    assert.equal(Either.isLeft(invalidUpstream), true)
  }

  const volatileIdempotency = await Effect.runPromise(
    Effect.either(
      loadProductionConfiguration(
        new Map([
          ["HEX_IDEMPOTENCY_DB_PATH", ":memory:"]
        ])
      )
    )
  )
  assert.equal(Either.isLeft(volatileIdempotency), true)

  const volatileDeviceRegistry = await Effect.runPromise(
    Effect.either(
      loadProductionConfiguration(
        new Map([["HEX_DEVICE_REGISTRY_DB_PATH", ":memory:"]])
      )
    )
  )
  assert.equal(Either.isLeft(volatileDeviceRegistry), true)
})
