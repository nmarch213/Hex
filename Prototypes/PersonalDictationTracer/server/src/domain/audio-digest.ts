import { Schema } from "effect"

const AudioDigestSchema = Schema.String.pipe(
  Schema.pattern(/^[0-9a-f]{64}$/),
  Schema.brand("AudioDigest")
)

/** A lowercase SHA-256 digest identifying one complete Captured Audio body. */
export type AudioDigest = Schema.Schema.Type<typeof AudioDigestSchema>

/** Parses an untrusted hexadecimal value into a SHA-256 audio digest. */
export const parseAudioDigest = (input: string) =>
  Schema.decodeUnknown(AudioDigestSchema)(input)
