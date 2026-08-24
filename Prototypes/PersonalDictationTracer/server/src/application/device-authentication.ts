import { Effect, Option, Redacted, Schema } from "effect"

import { DeviceRegistry } from "./device-registry.js"
import {
  DeviceCredentialSchema,
  type DeviceCapability
} from "../domain/device-principal.js"

/** Reports a missing, malformed, unknown, revoked, or insufficient credential. */
export class UnauthorizedError extends Schema.TaggedError<UnauthorizedError>()(
  "UnauthorizedError",
  { reason: Schema.Literal("unauthorized") }
) {}

/** Reports that the durable authentication authority could not be consulted. */
export class DeviceAuthenticationUnavailableError extends Schema.TaggedError<DeviceAuthenticationUnavailableError>()(
  "DeviceAuthenticationUnavailableError",
  { operation: Schema.Literal("resolve") }
) {}

const parseBearerCredential = (authorizationHeader: string) => {
  const trimmed = authorizationHeader.trim()
  const separatorIndex = trimmed.search(/[ \t]/)
  if (separatorIndex <= 0) {
    return Option.none()
  }

  const scheme = trimmed.slice(0, separatorIndex)
  const credential = trimmed.slice(separatorIndex).trim()
  if (
    scheme.toLowerCase() !== "bearer" ||
    credential.length === 0 ||
    /\s/.test(credential)
  ) {
    return Option.none()
  }

  return Schema.decodeUnknownOption(DeviceCredentialSchema)(credential)
}

/** Resolves untrusted bearer headers into active, capability-scoped devices. */
export class DeviceAuthentication extends Effect.Service<DeviceAuthentication>()(
  "@hex/personal-dictation/DeviceAuthentication",
  {
    effect: Effect.gen(function* () {
      const registry = yield* DeviceRegistry

      const authenticate = Effect.fnUntraced(
        function* (
          authorizationHeader: string,
          requiredCapability: DeviceCapability
        ) {
          const credential = parseBearerCredential(authorizationHeader)
          if (Option.isNone(credential)) {
            return yield* new UnauthorizedError({ reason: "unauthorized" })
          }

          const resolved = yield* registry
            .resolve({
              credential: Redacted.make(credential.value),
              requiredCapability
            })
            .pipe(
              Effect.mapError(
                () =>
                  new DeviceAuthenticationUnavailableError({
                    operation: "resolve"
                  })
              )
            )
          if (Option.isNone(resolved)) {
            return yield* new UnauthorizedError({ reason: "unauthorized" })
          }
          return resolved.value
        }
      )

      return { authenticate }
    })
  }
) {}
