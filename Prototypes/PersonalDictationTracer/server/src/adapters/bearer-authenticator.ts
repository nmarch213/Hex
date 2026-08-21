import { createHash, timingSafeEqual } from "node:crypto"

import { Context, Effect, Layer, Redacted, Schema } from "effect"

/** Reports that a request did not present the configured bearer credential. */
export class UnauthorizedError extends Schema.TaggedError<UnauthorizedError>()(
  "UnauthorizedError",
  { reason: Schema.String }
) {}

/** Authenticates private HTTP requests without exposing the configured token. */
export class BearerAuthenticator extends Context.Tag(
  "@hex/personal-dictation/BearerAuthenticator"
)<
  BearerAuthenticator,
  {
    readonly authorize: (
      authorizationHeader: string
    ) => Effect.Effect<void, UnauthorizedError>
  }
>() {}

const digest = (value: string): Uint8Array =>
  createHash("sha256").update(value, "utf8").digest()

/** Builds the bearer-authentication adapter from a redacted token. */
export const bearerAuthenticatorLayer = (
  token: Redacted.Redacted<string>
): Layer.Layer<BearerAuthenticator> => {
  const expectedDigest = digest(`Bearer ${Redacted.value(token)}`)

  return Layer.succeed(BearerAuthenticator, {
    authorize: (authorizationHeader: string) =>
      timingSafeEqual(expectedDigest, digest(authorizationHeader))
        ? Effect.void
        : Effect.fail(new UnauthorizedError({ reason: "unauthorized" }))
  })
}
