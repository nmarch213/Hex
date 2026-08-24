---
status: accepted
---

# Export content-free Effect telemetry over OTLP

The Ronin dictation service instruments its existing Effect call stack directly. The composition root may add the Effect-native OTLP/HTTP protobuf layer; no application service depends on a collector, and collector availability never controls authentication, admission, inference, persistence, or the HTTP response. Export is batched off the request path. When the collector is unavailable, the exporter temporarily disables delivery and request handling continues.

The service keeps one structured JSON completion event per HTTP request and exports the same Effect log event when OTLP is configured. It also exports bounded root and child spans for authentication, body reading, WAV parsing, digesting, idempotency, inference admission, recognition preparation/upstream/decode, completion, cleanup, and lease release. Effect Platform's automatic inbound and outbound HTTP spans are disabled because they include full URLs, headers, user agents, and network addresses. The replacement spans contain only code-known routes, methods, outcomes, runtime/model/build identity, replay state, and numeric timing or audio-shape measurements.

Credentials, authorization headers, request and device identifiers, transcript text, audio bytes, audio digests, raw URLs, query strings, file paths, client addresses, user agents, and error bodies are never telemetry fields. Traced application boundaries convert their typed `Exit` to a bounded success/failure attribute while the child span is open, then restore the exact failure after the span closes; this prevents Effect from automatically exporting tagged-error fields or JavaScript stack paths without changing application error semantics. Metric labels are restricted to bounded code-known dimensions; high-cardinality identifiers are not hashed and retained under another name. Histograms preserve millisecond distributions for request and processing-stage latency so p50, p95, and p99 can be compared over time without recording dictated content.

`HEX_OTLP_BASE_URL` selects a credential-free collector origin. It is optional and empty means disabled. Plaintext is limited to loopback or the internal Compose service name `otel-collector`; other collectors require HTTPS. Authentication and long-term storage belong behind the private collector, not in proxy environment variables. The repository proves OTLP logs, metrics, and traces reach all three protobuf endpoints, but the Owner chooses and operates the long-term backend separately.
