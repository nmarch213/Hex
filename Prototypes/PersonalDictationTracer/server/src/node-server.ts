import { HttpMiddleware, HttpServer } from "@effect/platform"
import { NodeHttpServer } from "@effect/platform-node"
import { Layer } from "effect"
import { createServer } from "node:http"

import { DeviceAuthentication } from "./application/device-authentication.js"
import { Transcription } from "./application/transcription.js"
import type { SpeechRecognition } from "./application/speech-recognition.js"
import type { UpstreamProcessEpoch } from "./application/transcription-idempotency.js"
import type { ServiceRevision } from "./service-metadata.js"
import { httpApi } from "./adapters/http-api.js"
import { InboundAudioAdmission } from "./adapters/inbound-audio-admission.js"
import { sqliteDeviceRegistryLayer } from "./adapters/sqlite-device-registry.js"
import { sqliteTranscriptionIdempotencyLayer } from "./adapters/sqlite-transcription-idempotency.js"

const RequestTimeoutMilliseconds = 35_000
const HeadersTimeoutMilliseconds = 10_000
const ConnectionsCheckingIntervalMilliseconds = 1_000
const KeepAliveTimeoutMilliseconds = 5_000
const KeepAliveTimeoutBufferMilliseconds = 1_000

/** Network and durable-storage configuration shared by the server entrypoints. */
export interface NodeServerConfiguration {
  readonly host: string
  readonly port: number
  readonly idempotencyDatabasePath: string
  readonly deviceRegistryDatabasePath: string
  readonly upstreamProcessEpoch: UpstreamProcessEpoch
  readonly serviceBuildRevision: ServiceRevision
}

/** Launches the HTTP service with an already-selected recognition runtime. */
export const launchNodeServer = (
  config: NodeServerConfiguration,
  recognitionLayer: Layer.Layer<SpeechRecognition>,
  runtimeLayer: Layer.Layer<never>
) => {
  const transcriptionDependencies = Layer.merge(
    recognitionLayer,
    sqliteTranscriptionIdempotencyLayer(
      config.idempotencyDatabasePath,
      config.upstreamProcessEpoch
    )
  )
  const transcriptionLayer = Transcription.Default.pipe(
    Layer.provide(transcriptionDependencies)
  )
  const deviceAuthenticationLayer = DeviceAuthentication.Default.pipe(
    Layer.provide(
      sqliteDeviceRegistryLayer(config.deviceRegistryDatabasePath)
    )
  )
  const applicationServices = Layer.mergeAll(
    transcriptionLayer,
    deviceAuthenticationLayer,
    InboundAudioAdmission.Default
  )
  const serverLayer = NodeHttpServer.layer(
    () =>
      createServer({
        requestTimeout: RequestTimeoutMilliseconds,
        headersTimeout: HeadersTimeoutMilliseconds,
        connectionsCheckingInterval: ConnectionsCheckingIntervalMilliseconds,
        keepAliveTimeout: KeepAliveTimeoutMilliseconds,
        keepAliveTimeoutBuffer: KeepAliveTimeoutBufferMilliseconds
      }),
    {
      host: config.host,
      port: config.port
    }
  )
  const application = httpApi(config.serviceBuildRevision).pipe(
    HttpServer.serve(),
    // Effect Platform's default HTTP span includes the full URL, headers,
    // user-agent, and client address. The app emits its own bounded root span.
    HttpMiddleware.withTracerDisabledWhen(() => true),
    HttpServer.withLogAddress,
    Layer.provide(applicationServices),
    Layer.provide(serverLayer)
  )

  // Logger/tracer/metric layers modify fiber-local runtime state rather than
  // supplying Context services. Build the application inside that runtime so
  // the runtime captured by NodeHttpServer's request handler inherits them.
  return Layer.launch(application.pipe(Layer.provide(runtimeLayer)))
}
