# Private OTEL latency monitoring for Ronin

Date: 2026-08-24

## Recommendation

Run a small, private metrics stack on Ronin:

```text
Hex/Ronin service --OTLP/HTTP--> OpenTelemetry Collector
                                      |
                                      +-- Prometheus exporter (/metrics, internal only)
                                                |
                                                v
                                      Prometheus local TSDB (14 days, size capped)
                                                |
                                                v
                                      recording rules + alerting rules
                                                |
                                                v
                                      Alertmanager (optional, owner-only)
```

Use the Collector as the only telemetry ingress. Prometheus should scrape the
Collector's Prometheus exporter over the private Compose network; it should not
be exposed to the iPhone or the public Internet. This keeps the existing
credential-free service-to-Collector boundary and gives Prometheus durable,
queryable local retention without adding a hosted telemetry provider.

This is preferable to having the service write directly to Prometheus. The
OpenTelemetry project recommends a Collector alongside a service because it can
batch, retry, encrypt, and filter telemetry before it reaches a backend:
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/). The
OpenTelemetry Prometheus exporter is a pull exporter and must expose Prometheus
metrics for scraping:
[Prometheus exporter specification](https://opentelemetry.io/docs/specs/otel/metrics/sdk_exporters/prometheus/).

For this one-owner deployment, do not add a distributed metrics backend,
Grafana, a log database, or a trace database yet. Prometheus's local TSDB is
adequate for a single Ronin node and is explicitly not clustered or replicated,
so its data directory must be treated as a local database and backed up if the
history matters:
[Prometheus storage](https://prometheus.io/docs/prometheus/latest/storage/).

## What to measure

The service already has the right privacy-preserving measurements:

- `hex_http_server_duration_ms`: server request duration, including durable
  completion for the request path.
- `hex_dictation_stage_duration_ms`: bounded stages such as recognition,
  decode, completion, and release.
- request count and bounded audio-shape histograms for denominator and workload
  context.

Keep the existing bounded labels (`route`, `method`, `outcome`,
`status_class`, `replayed`, and bounded `stage`). Never add request IDs, device
IDs, transcript text, audio digests, paths, URLs, or arbitrary user input as
metric labels. A unique label creates a new time series per value and can
exhaust a small Prometheus instance.

Server latency is not the complete iPhone stop-to-insert latency. It excludes
some client capture, upload, mailbox, app-switch, and insertion time. Keep the
two measurements separate:

1. Ronin service latency is the always-on operational SLO and is queryable from
   Prometheus immediately.
2. Physical-phone stop-to-insert latency is the product metric and should be
   added as a second bounded histogram when the iOS client has a privacy-safe
   OTLP path. Do not infer it from server duration.

## Prometheus retention and resource bounds

Start with these conservative Ronin settings:

```text
--storage.tsdb.path=/var/lib/prometheus
--storage.tsdb.retention.time=14d
--storage.tsdb.retention.size=2GB
--storage.tsdb.wal-compression
--web.listen-address=127.0.0.1:9090
```

The time and size limits are an operational starting point, not a benchmark
claim. Prometheus removes data when either limit is reached. Its documentation
recommends reserving 15–20% of the allocated disk for compaction and keeping
the retention size at no more than roughly 80–85% of the allocated storage:
[Prometheus retention sizing](https://prometheus.io/docs/prometheus/latest/storage/#right-sizing-retention-size).
Allocate the volume accordingly (for example, at least 3 GB for a 2 GB
retention ceiling) and monitor free space. Use a local POSIX filesystem, not
NFS; Prometheus documents NFS as unsupported for reliable local storage.

Scrape the Collector every 15 seconds. With the current low-cardinality metric
set and one Ronin target this is intentionally simple; increase the interval
before increasing retention if the series count grows. Set a hard container
memory limit and keep Prometheus and the Collector on separate bounded volumes.

For the Collector, use only the components needed by the selected distribution:
OTLP/HTTP receiver, Prometheus exporter, memory limiter, and batch processor.
Place `memory_limiter` first, then privacy filtering, then `batch`; the
Collector's processor guidance gives this ordering because memory must be shed
before downstream processors accumulate data:
[Collector processor guidance](https://go.opentelemetry.io/collector/processor).
The Collector security guidance also recommends least privilege, minimizing
components, authenticated/encrypted connections where applicable, and
safeguarding resource utilization:
[Collector configuration security](https://opentelemetry.io/docs/security/config-best-practices/).

Use a pinned Collector image digest and run it as a non-root user. Bind the
OTLP receiver and Prometheus exporter only to the internal Compose network.
If the Collector is ever moved across a host boundary, use HTTPS and
authentication rather than extending the current plaintext internal-only
exception.

## Quantiles and recording rules

The existing millisecond histogram boundaries are suitable for p50/p95/p99
trend monitoring as long as they are not changed between revisions without
noting a baseline break. Prometheus computes quantiles from histogram buckets
with `histogram_quantile`; classic histograms require `le` in the aggregation:
[Prometheus histogram quantiles](https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile).

Create recording rules so dashboards and alerts query stable, cheap series:

```yaml
groups:
  - name: hex-latency
    interval: 15s
    rules:
      - record: hex:http_server_duration_ms:p50
        expr: histogram_quantile(0.50, sum by (le) (rate(hex_http_server_duration_ms_bucket[10m])))
      - record: hex:http_server_duration_ms:p95
        expr: histogram_quantile(0.95, sum by (le) (rate(hex_http_server_duration_ms_bucket[10m])))
      - record: hex:http_server_duration_ms:p99
        expr: histogram_quantile(0.99, sum by (le) (rate(hex_http_server_duration_ms_bucket[10m])))
      - record: hex:dictation_stage_duration_ms:p95
        expr: histogram_quantile(0.95, sum by (stage, le) (rate(hex_dictation_stage_duration_ms_bucket[10m])))
```

The final thresholds must come from the first successful physical-phone
baseline. Do not invent a target from CI timings. Once a baseline exists,
make the alert compare the p95 against a revision-owned budget and require
recent traffic so an idle service does not page:

```yaml
      - alert: HexServerLatencyRegression
        expr: |
          hex:http_server_duration_ms:p95 > <approved_budget_ms>
          and sum(rate(hex_http_server_requests_total{route="/v1/transcribe"}[10m])) > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: Hex Ronin transcription latency is above its approved budget
```

Use `promtool check rules` in CI before deployment. Recording rules are useful
here because Prometheus documents that precomputed expressions make repeated
dashboard queries faster and more predictable:
[Prometheus recording rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/).

Alerting should remain optional for the first deployment. Prometheus sends
alerts to Alertmanager, which handles grouping, silencing, inhibition, and
notification routing:
[Prometheus alerting overview](https://prometheus.io/docs/alerting/latest/overview/).
If enabled, run Alertmanager on the internal network with a bounded local data
directory and an owner-only receiver. Do not send transcript-bearing labels or
annotations. A local Prometheus dashboard and a Ronin health check are enough
until a private notification destination is chosen.

## Operational cautions

- Exporting telemetry must remain asynchronous and fail-open for dictation;
  Collector or Prometheus downtime must never make transcription fail.
- Monitor Collector export failures and queue pressure. The Collector exposes
  internal metrics by default at `http://127.0.0.1:8888/metrics`; sustained
  `otelcol_exporter_send_failed_metric_points` indicates export trouble:
  [Collector internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/).
- Alert on `up{job="otel-collector"} == 0`, Collector send failures, and low
  Prometheus free space in addition to latency. A missing telemetry pipeline
  can otherwise look like a healthy zero-latency service.
- Keep a canary/validation request free of transcript content and use it only
  for reachability and metric-pipeline checks. Do not synthetic-test inference
  frequently enough to distort user latency quantiles.
- Back up Prometheus snapshots only if trend history matters. Prometheus
  recommends snapshots and warns that ordinary filesystem copies can omit data
  still in the WAL:
  [Prometheus storage backups](https://prometheus.io/docs/prometheus/latest/storage/#snapshots).
- Pin Prometheus, Collector, and Alertmanager versions or image digests and
  upgrade them as a tested set. Validate the merged Compose configuration,
  rules, scrape target, and retention flags before restarting Ronin.

## Decision

Implement the metrics-only path first: Collector Prometheus exporter, one
Prometheus instance, 14-day/2-GB bounded retention, recording rules for p50,
p95, and p99, and no outbound alert receiver. Add Alertmanager after the first
physical baseline if owner-only notifications are useful. Add client-side
stop-to-insert telemetry as a separate bounded metric only after deciding how
the iOS app reaches the private Collector without making the server credential
or transcript part of telemetry.

The initial implementation uses a two-minute Collector metric expiration so a
stale application export cannot remain apparently healthy, while Prometheus
retains the historical samples for 14 days. It records 24-hour revision-aware
HTTP, recognition, and stage quantiles and rejects deployment promotion unless
Prometheus observes the exact new service revision. Numerical regression rules
remain blocked on the physical-phone baseline required by issue #8.
