# Ronin prototype service

This is a deliberately small Effect service around the upstream `parakeet.cpp` example server. It adds the pieces the personal iOS tracer needs: bearer authentication, WAV validation, request IDs, serialized inference, short in-memory idempotency, and stable JSON timing fields.

The application service owns serialization and retry semantics. Inbound HTTP/authentication and outbound `parakeet.cpp` calls are adapters selected by the composition root in `src/main.ts`. No audio or transcript is persisted.

## Develop and verify

```bash
npm ci
npm run validate
```

`npm run validate` runs strict TypeScript checking, service tests through public Effect layers, and the production build. From the prototype root, `make smoke-server` additionally exercises the real HTTP wire contract against the deterministic fake recognition adapter.

The upstream process is not exposed from Docker. The proxy is published only on Ronin loopback so Tailscale Serve is the sole network ingress.

## Start

```bash
cp .env.example .env
openssl rand -hex 32
# Put that value in .env, then from the prototype root:
make server
```

The Compose file pins the tested multi-architecture `parakeet.cpp-server` image digest and selects the exact `tdt-0.6b-v2` model alias. The first start downloads that alias's F16 GGUF. Wait for the model to load, then check the service from Ronin:

```bash
curl --fail \
  -H "Authorization: Bearer $HEX_PROXY_TOKEN" \
  http://127.0.0.1:8787/health
```

Expose `http://127.0.0.1:8787` with Tailscale Serve on HTTPS port 8443 at Ronin's MagicDNS name. Never enable Funnel. Port 443 already belongs to another Ronin service. Restrict Ronin TCP 8443 to the personal iPhone in the tailnet policy before considering the service ready.

## API

`POST /v1/transcribe` requires:

- `Authorization: Bearer <token>`
- `Content-Type: audio/wav`
- `X-Hex-Request-ID: <UUID>`
- a complete mono 16 kHz Float32 WAV body

The same request ID and audio body returns the cached result without running inference twice. Reusing an ID for different audio returns `409`. The cache is process-local and intentionally tiny; no audio or transcript history is persisted.

## Fake recognition adapter

Run `make server-fake` from the prototype root. It exercises authentication, WAV validation, response decoding, and idempotency without Docker or a model. The token is `prototype` and the response is deterministic.
