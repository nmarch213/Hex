import { open } from "node:fs/promises"

import {
  Config,
  ConfigError,
  Effect,
  Either,
  Option,
  Schema
} from "effect"

import { UpstreamProcessEpochSchema } from "./application/transcription-idempotency.js"
import {
  FakeRecognitionArtifactIdentity,
  ProductionRecognitionArtifactIdentity,
  ServiceBuildRevisionSchema
} from "./service-metadata.js"

const PlaintextTelemetryHosts = new Set([
  "localhost",
  "127.0.0.1",
  "[::1]",
  "otel-collector"
])

const TelemetryConfigurationMessage =
  "HEX_OTLP_BASE_URL must be a credential-free origin using HTTPS, or HTTP on localhost, 127.0.0.1, [::1], or otel-collector"

const parseTelemetryBaseURL = (
  raw: string
): Either.Either<URL, ConfigError.ConfigError> => {
  try {
    const url = new URL(raw)
    const valid =
      url.username === "" &&
      url.password === "" &&
      (url.pathname === "" || url.pathname === "/") &&
      url.search === "" &&
      url.hash === "" &&
      (url.protocol === "https:" ||
        (url.protocol === "http:" &&
          PlaintextTelemetryHosts.has(url.hostname.toLowerCase())))
    return valid
      ? Either.right(url)
      : Either.left(
          ConfigError.InvalidData([], TelemetryConfigurationMessage)
        )
  } catch {
    return Either.left(
      ConfigError.InvalidData([], TelemetryConfigurationMessage)
    )
  }
}

const otlpBaseURL = Config.string("HEX_OTLP_BASE_URL").pipe(
  Config.option,
  Config.mapOrFail(
    Option.match({
      onNone: () => Either.right(Option.none<URL>()),
      onSome: (raw) =>
        raw === ""
          ? Either.right(Option.none<URL>())
          : parseTelemetryBaseURL(raw).pipe(Either.map(Option.some))
    })
  )
)

/** Reports an unreadable or invalid Parakeet process-epoch configuration. */
export class UpstreamEpochConfigurationError extends Schema.TaggedError<UpstreamEpochConfigurationError>()(
  "UpstreamEpochConfigurationError",
  { reason: Schema.Literal("unreadable", "invalid") }
) {}

const loadUpstreamProcessEpoch = Effect.gen(function* () {
  const path = yield* Config.nonEmptyString("HEX_UPSTREAM_EPOCH_FILE")
  const raw = yield* Effect.tryPromise({
    try: async () => {
      const handle = await open(path, "r")
      try {
        const buffer = Buffer.alloc(66)
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0)
        if (bytesRead > 65) {
          throw new Error("upstream epoch file is too large")
        }
        const value = buffer.subarray(0, bytesRead).toString("utf8")
        return value.endsWith("\n") ? value.slice(0, -1) : value
      } finally {
        await handle.close()
      }
    },
    catch: () => new UpstreamEpochConfigurationError({ reason: "unreadable" })
  })
  return yield* Schema.decodeUnknown(UpstreamProcessEpochSchema)(raw).pipe(
    Effect.mapError(
      () => new UpstreamEpochConfigurationError({ reason: "invalid" })
    )
  )
})

const serverConfiguration = {
  host: Config.nonEmptyString("HEX_LISTEN_HOST").pipe(
    Config.withDefault("127.0.0.1")
  ),
  port: Config.port("HEX_LISTEN_PORT").pipe(Config.withDefault(8787)),
  idempotencyDatabasePath: Config.nonEmptyString("HEX_IDEMPOTENCY_DB_PATH").pipe(
    Config.withDefault("data/idempotency.sqlite"),
    Config.validate({
      message: "HEX_IDEMPOTENCY_DB_PATH must use durable filesystem storage",
      validation: (databasePath) => databasePath !== ":memory:"
    })
  ),
  deviceRegistryDatabasePath: Config.nonEmptyString(
    "HEX_DEVICE_REGISTRY_DB_PATH"
  ).pipe(
    Config.withDefault("data/devices.sqlite"),
    Config.validate({
      message:
        "HEX_DEVICE_REGISTRY_DB_PATH must use durable filesystem storage",
      validation: (databasePath) => databasePath !== ":memory:"
    })
  ),
  otlpBaseURL
}

const PlaintextUpstreamHosts = new Set([
  "localhost",
  "127.0.0.1",
  "[::1]",
  "parakeet"
])

const upstreamURL = Config.url("HEX_UPSTREAM_URL").pipe(
  Config.withDefault(
    new URL("http://127.0.0.1:8080/v1/audio/transcriptions")
  ),
  Config.validate({
    message:
      "HEX_UPSTREAM_URL must use credential-free HTTPS, or HTTP on localhost, 127.0.0.1, [::1], or parakeet",
    validation: (url) => {
      if (url.username !== "" || url.password !== "") {
        return false
      }
      if (url.protocol === "https:") {
        return true
      }
      return (
        url.protocol === "http:" &&
        PlaintextUpstreamHosts.has(url.hostname.toLowerCase())
      )
    }
  })
)

const serviceBuildRevision = Config.nonEmptyString(
  "HEX_BUILD_REVISION"
).pipe(
  Config.mapOrFail((value) =>
    Schema.decodeUnknownEither(ServiceBuildRevisionSchema)(value).pipe(
      Either.mapLeft(() =>
        ConfigError.InvalidData(
          [],
          "HEX_BUILD_REVISION must be a lowercase 40-character Git revision"
        )
      )
    )
  )
)

/** Production configuration for the parakeet-backed service entrypoint. */
export const productionConfiguration = Effect.gen(function* () {
  const configuration = yield* Config.all({
    ...serverConfiguration,
    upstreamURL,
    serviceBuildRevision
  })
  const upstreamProcessEpoch = yield* loadUpstreamProcessEpoch
  return {
    ...configuration,
    upstreamProcessEpoch,
    observability: {
      otlpBaseURL: configuration.otlpBaseURL,
      environment: "production" as const,
      serviceInstanceID: upstreamProcessEpoch,
      recognition: ProductionRecognitionArtifactIdentity
    }
  }
})

/** Configuration for the explicit deterministic fake-runtime entrypoint. */
export const fakeConfiguration = Effect.gen(function* () {
  const configuration = yield* Config.all({
    ...serverConfiguration,
    fakeTranscript: Config.nonEmptyString("HEX_FAKE_TRANSCRIPT").pipe(
      Config.withDefault("Hello from the Ronin tracer.")
    )
  })
  const upstreamProcessEpoch = yield* Schema.decodeUnknown(
    UpstreamProcessEpochSchema
  )("0".repeat(64)).pipe(Effect.orDie)
  return {
    ...configuration,
    upstreamProcessEpoch,
    serviceBuildRevision: "development" as const,
    observability: {
      otlpBaseURL: configuration.otlpBaseURL,
      environment: "development" as const,
      serviceInstanceID: "development",
      recognition: FakeRecognitionArtifactIdentity
    }
  }
})

/** Durable configuration used by the Ronin-local device administration CLI. */
export const deviceAdministrationConfiguration = Config.all({
  deviceRegistryDatabasePath: serverConfiguration.deviceRegistryDatabasePath
})
