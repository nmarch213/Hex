/**
 * A deliberately small OTLP/protobuf reader for exporter contract tests.
 *
 * It decodes only the fields this service emits. Keeping it here (rather than
 * importing Effect's private encoder) makes the assertions independent of the
 * exporter implementation and keeps this support out of production builds.
 */

type WireType = 0 | 1 | 2 | 5

interface Field {
  readonly number: number
  readonly wireType: WireType
  readonly value: bigint | Uint8Array
}

export interface OtlpAttribute {
  readonly key: string
  readonly value: string | boolean | bigint | number | Uint8Array
}

export interface OtlpResource {
  readonly attributes: ReadonlyArray<OtlpAttribute>
}

export interface OtlpSpan {
  readonly traceID: string
  readonly spanID: string
  readonly parentSpanID: string | undefined
  readonly name: string
  readonly attributes: ReadonlyArray<OtlpAttribute>
}

export interface OtlpMetric {
  readonly name: string
  readonly unit: string | undefined
  readonly pointAttributes: ReadonlyArray<ReadonlyArray<OtlpAttribute>>
}

export interface OtlpLogRecord {
  readonly body: string | boolean | bigint | number | Uint8Array | undefined
  readonly attributes: ReadonlyArray<OtlpAttribute>
}

export interface OtlpTraceExport {
  readonly resource: OtlpResource
  readonly spans: ReadonlyArray<OtlpSpan>
}

export interface OtlpMetricExport {
  readonly resource: OtlpResource
  readonly metrics: ReadonlyArray<OtlpMetric>
}

export interface OtlpLogExport {
  readonly resource: OtlpResource
  readonly records: ReadonlyArray<OtlpLogRecord>
}

const decoder = new TextDecoder()

const fail = (message: string): never => {
  throw new Error(`invalid OTLP protobuf fixture: ${message}`)
}

const readVarint = (
  bytes: Uint8Array,
  offset: number
): readonly [bigint, number] => {
  let value = 0n
  let shift = 0n
  let cursor = offset
  while (cursor < bytes.byteLength && shift <= 63n) {
    const byte = bytes[cursor]
    if (byte === undefined) return fail("missing varint byte")
    value |= BigInt(byte & 0x7f) << shift
    cursor += 1
    if ((byte & 0x80) === 0) return [value, cursor]
    shift += 7n
  }
  return fail("unterminated or oversized varint")
}

const readLengthDelimited = (
  bytes: Uint8Array,
  offset: number
): readonly [Uint8Array, number] => {
  const [length, bodyOffset] = readVarint(bytes, offset)
  if (length > BigInt(Number.MAX_SAFE_INTEGER)) {
    fail("length exceeds JavaScript safe integer range")
  }
  const end = bodyOffset + Number(length)
  if (end > bytes.byteLength) fail("length-delimited field exceeds body")
  return [bytes.slice(bodyOffset, end), end]
}

const parseMessage = (bytes: Uint8Array): ReadonlyArray<Field> => {
  const fields: Array<Field> = []
  let offset = 0
  while (offset < bytes.byteLength) {
    const [tag, tagEnd] = readVarint(bytes, offset)
    const number = Number(tag >> 3n)
    const wireType = Number(tag & 0x7n)
    if (number <= 0 || ![0, 1, 2, 5].includes(wireType)) {
      fail("unsupported field tag")
    }
    offset = tagEnd
    switch (wireType) {
      case 0: {
        const [value, end] = readVarint(bytes, offset)
        fields.push({ number, wireType, value })
        offset = end
        break
      }
      case 1: {
        const end = offset + 8
        if (end > bytes.byteLength) fail("truncated fixed64 field")
        fields.push({ number, wireType, value: bytes.slice(offset, end) })
        offset = end
        break
      }
      case 2: {
        const [value, end] = readLengthDelimited(bytes, offset)
        fields.push({ number, wireType, value })
        offset = end
        break
      }
      case 5: {
        const end = offset + 4
        if (end > bytes.byteLength) fail("truncated fixed32 field")
        fields.push({ number, wireType, value: bytes.slice(offset, end) })
        offset = end
        break
      }
    }
  }
  return fields
}

const fields = (
  message: ReadonlyArray<Field>,
  number: number,
  wireType: WireType
): ReadonlyArray<Field> =>
  message.filter((field) => field.number === number && field.wireType === wireType)

const bytesField = (
  message: ReadonlyArray<Field>,
  number: number
): Uint8Array | undefined => {
  const value = fields(message, number, 2)[0]?.value
  return value instanceof Uint8Array ? value : undefined
}

const stringField = (
  message: ReadonlyArray<Field>,
  number: number
): string | undefined => {
  const value = bytesField(message, number)
  return value === undefined ? undefined : decoder.decode(value)
}

const nested = (
  message: ReadonlyArray<Field>,
  number: number
): ReadonlyArray<ReadonlyArray<Field>> =>
  fields(message, number, 2).map((field) => {
    const value = field.value
    if (!(value instanceof Uint8Array)) return fail("expected embedded message")
    return parseMessage(value)
  })

const hex = (value: Uint8Array | undefined): string | undefined =>
  value === undefined ? undefined : Buffer.from(value).toString("hex")

const double = (value: Uint8Array): number => {
  if (value.byteLength !== 8) fail("invalid double width")
  return new DataView(value.buffer, value.byteOffset, value.byteLength).getFloat64(0, true)
}

const anyValue = (
  message: ReadonlyArray<Field>
): string | boolean | bigint | number | Uint8Array => {
  const string = bytesField(message, 1)
  if (string !== undefined) return decoder.decode(string)
  const boolean = fields(message, 2, 0)[0]?.value
  if (typeof boolean === "bigint") return boolean !== 0n
  const integer = fields(message, 3, 0)[0]?.value
  if (typeof integer === "bigint") return integer
  const floating = fields(message, 4, 1)[0]?.value
  if (floating instanceof Uint8Array) return double(floating)
  const bytes = bytesField(message, 7)
  if (bytes !== undefined) return bytes
  return fail("unsupported AnyValue variant")
}

const attributes = (message: ReadonlyArray<Field>, number: number) =>
  nested(message, number).map((keyValue): OtlpAttribute => {
    const key = stringField(keyValue, 1)
    const value = nested(keyValue, 2)[0]
    if (key === undefined || value === undefined) {
      return fail("malformed KeyValue")
    }
    return { key, value: anyValue(value) }
  })

const resource = (message: ReadonlyArray<Field>): OtlpResource => ({
  attributes: attributes(message, 1)
})

const parseSpan = (message: ReadonlyArray<Field>): OtlpSpan => {
  const traceID = hex(bytesField(message, 1))
  const spanID = hex(bytesField(message, 2))
  const name = stringField(message, 5)
  if (traceID === undefined || spanID === undefined || name === undefined) {
    return fail("malformed Span")
  }
  return {
    traceID,
    spanID,
    parentSpanID: hex(bytesField(message, 4)),
    name,
    attributes: attributes(message, 9)
  }
}

/** Decodes every ResourceSpans batch in one OTLP traces export. */
export const decodeTraceExport = (body: Uint8Array): ReadonlyArray<OtlpTraceExport> =>
  nested(parseMessage(body), 1).map((resourceSpans) => {
    const resourceMessage = nested(resourceSpans, 1)[0]
    if (resourceMessage === undefined) return fail("missing trace resource")
    return {
      resource: resource(resourceMessage),
      spans: nested(resourceSpans, 2).flatMap((scopeSpans) =>
        nested(scopeSpans, 2).map(parseSpan)
      )
    }
  })

const pointAttributesForMetric = (message: ReadonlyArray<Field>) => {
  const gauge = nested(message, 5).flatMap((value) => nested(value, 1))
  const sum = nested(message, 7).flatMap((value) => nested(value, 1))
  const histogram = nested(message, 9).flatMap((value) => nested(value, 1))
  return [...gauge, ...sum].map((point) => attributes(point, 7)).concat(
    histogram.map((point) => attributes(point, 9))
  )
}

const parseMetric = (message: ReadonlyArray<Field>): OtlpMetric => {
  const name = stringField(message, 1)
  if (name === undefined) return fail("metric without name")
  return {
    name,
    unit: stringField(message, 3),
    pointAttributes: pointAttributesForMetric(message)
  }
}

/** Decodes every ResourceMetrics batch in one OTLP metrics export. */
export const decodeMetricExport = (body: Uint8Array): ReadonlyArray<OtlpMetricExport> =>
  nested(parseMessage(body), 1).map((resourceMetrics) => {
    const resourceMessage = nested(resourceMetrics, 1)[0]
    if (resourceMessage === undefined) return fail("missing metric resource")
    return {
      resource: resource(resourceMessage),
      metrics: nested(resourceMetrics, 2).flatMap((scopeMetrics) =>
        nested(scopeMetrics, 2).map(parseMetric)
      )
    }
  })

const parseLogRecord = (message: ReadonlyArray<Field>): OtlpLogRecord => {
  const body = nested(message, 5)[0]
  return {
    body: body === undefined ? undefined : anyValue(body),
    attributes: attributes(message, 6)
  }
}

/** Decodes every ResourceLogs batch in one OTLP logs export. */
export const decodeLogExport = (body: Uint8Array): ReadonlyArray<OtlpLogExport> =>
  nested(parseMessage(body), 1).map((resourceLogs) => {
    const resourceMessage = nested(resourceLogs, 1)[0]
    if (resourceMessage === undefined) return fail("missing log resource")
    return {
      resource: resource(resourceMessage),
      records: nested(resourceLogs, 2).flatMap((scopeLogs) =>
        nested(scopeLogs, 2).map(parseLogRecord)
      )
    }
  })

/** Converts resource attributes to a map for concise contract assertions. */
export const attributeMap = (attributes: ReadonlyArray<OtlpAttribute>) =>
  new Map(attributes.map((attribute) => [attribute.key, attribute.value]))
