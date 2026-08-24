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

/** Immutable runtime/model artifact identifiers for production telemetry. */
export const NodeRuntimeImageDigest =
  "sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43"
export const ParakeetRuntimeImageDigest =
  "sha256:4a5d92e41356cb5d691e3644d31cf4cc2c0be1536f165fff9f2c5ec852c29348"
export const ParakeetModelRevision =
  "bf0af9f425fa01809cadec671b3cb672709d13e9"
export const ParakeetModelFilename = "tdt-0.6b-v2-f16.gguf"
export const ParakeetModelSHA256 =
  "f8df7f5dc7b9ceb5cd0637a81194aab5d93022ace555ce81c8969c7a694b8f3d"
