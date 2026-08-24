import { Schema } from "effect"

/** Service version attached to every request-completion event. */
export const ServiceVersion = "0.0.1"

/** Schema for the exact committed Hex revision used to build production. */
export const ServiceBuildRevisionSchema = Schema.String.pipe(
  Schema.pattern(/^[0-9a-f]{40}$/),
  Schema.brand("ServiceBuildRevision")
)

/** Exact committed Hex revision used to build the running proxy image. */
export type ServiceBuildRevision = Schema.Schema.Type<
  typeof ServiceBuildRevisionSchema
>

/** Build identity accepted by shared HTTP adapters and explicit fake servers. */
export type ServiceRevision = ServiceBuildRevision | "development"

/** Immutable digest of the production Node runtime image. */
export const NodeRuntimeImageDigest =
  "sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43"
/** Immutable digest of the production speech-recognition runtime image. */
export const ParakeetRuntimeImageDigest =
  "sha256:4a5d92e41356cb5d691e3644d31cf4cc2c0be1536f165fff9f2c5ec852c29348"
/** Immutable source revision of the production recognition model. */
export const ParakeetModelRevision =
  "bf0af9f425fa01809cadec671b3cb672709d13e9"
/** Exact filename mounted into the production recognition runtime. */
export const ParakeetModelFilename = "tdt-0.6b-v2-f16.gguf"
/** Verified digest of the production recognition model file. */
export const ParakeetModelSHA256 =
  "f8df7f5dc7b9ceb5cd0637a81194aab5d93022ace555ce81c8969c7a694b8f3d"

/** Artifact identity carried consistently by recognition and telemetry. */
export interface RecognitionArtifactIdentity {
  readonly runtime: string
  readonly model: string
  readonly runtimeRevision: string
  readonly modelRevision: string
  readonly modelSHA256: string
}

/** Exact production recognition artifacts. */
export const ProductionRecognitionArtifactIdentity = {
  runtime: "parakeet.cpp",
  model: "nvidia/parakeet-tdt-0.6b-v2",
  runtimeRevision: ParakeetRuntimeImageDigest,
  modelRevision: ParakeetModelRevision,
  modelSHA256: ParakeetModelSHA256
} as const satisfies RecognitionArtifactIdentity

/** Deterministic development recognition artifacts. */
export const FakeRecognitionArtifactIdentity = {
  runtime: "fake",
  model: ProductionRecognitionArtifactIdentity.model,
  runtimeRevision: "deterministic-fake-v1",
  modelRevision: "deterministic-fixture-v1",
  modelSHA256: "0".repeat(64)
} as const satisfies RecognitionArtifactIdentity
