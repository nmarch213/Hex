import { Schema } from "effect"

/** A caller-generated identifier used to make transcription retries idempotent. */
export const RequestIdSchema = Schema.UUID.pipe(Schema.brand("RequestId"))

/** A normalized UUID identifying one transcription request. */
export type RequestId = Schema.Schema.Type<typeof RequestIdSchema>

/** Parses and normalizes an untrusted request ID. */
export const parseRequestId = (input: string) =>
  Schema.decodeUnknown(RequestIdSchema)(input.toLowerCase())
