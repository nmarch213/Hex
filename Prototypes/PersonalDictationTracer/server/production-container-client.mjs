#!/usr/bin/env node

import { readFile } from "node:fs/promises"

const [origin, credentialDirectory, audioPath, expectedServiceRevision] =
  process.argv.slice(2)

if (
  origin === undefined ||
  credentialDirectory === undefined ||
  audioPath === undefined ||
  expectedServiceRevision === undefined ||
  !/^[0-9a-f]{40}$/.test(expectedServiceRevision)
) {
  process.stderr.write(
    "Usage: production-container-client.mjs ORIGIN CREDENTIAL_DIRECTORY AUDIO_PATH SERVICE_REVISION\n"
  )
  process.exit(2)
}

const [deviceToken, healthToken, audio] = await Promise.all([
  readFile(`${credentialDirectory}/device-token`, "utf8").then((value) =>
    value.trimEnd()
  ),
  readFile(`${credentialDirectory}/health-probe-token`, "utf8").then(
    (value) => value.trimEnd()
  ),
  readFile(audioPath)
])

const authenticatedFetch = (path, token, init = {}) =>
  fetch(new URL(path, origin), {
    ...init,
    headers: {
      ...init.headers,
      authorization: `Bearer ${token}`
    },
    signal: AbortSignal.timeout(5_000)
  })

let health
for (let attempt = 0; attempt < 100; attempt += 1) {
  try {
    const response = await authenticatedFetch("/health", healthToken)
    if (response.status === 200) {
      health = await response.json()
      break
    }
  } catch {
    // Startup races are expected; only the bounded terminal failure is reported.
  }
  await new Promise((resolve) => setTimeout(resolve, 100))
}

if (
  health?.status !== "ready" ||
  health.runtime !== "parakeet.cpp" ||
  health.model !== "nvidia/parakeet-tdt-0.6b-v2" ||
  health.serviceRevision !== expectedServiceRevision ||
  health.runtimeRevision !==
    "sha256:4a5d92e41356cb5d691e3644d31cf4cc2c0be1536f165fff9f2c5ec852c29348" ||
  health.modelRevision !== "bf0af9f425fa01809cadec671b3cb672709d13e9" ||
  health.modelSHA256 !==
    "f8df7f5dc7b9ceb5cd0637a81194aab5d93022ace555ce81c8969c7a694b8f3d"
) {
  throw new Error("production proxy did not become ready with pinned metadata")
}

const transcriptionResponse = await authenticatedFetch(
  "/v1/transcribe",
  deviceToken,
  {
    method: "POST",
    headers: {
      "content-type": "audio/wav",
      "content-length": String(audio.byteLength),
      "x-hex-request-id": "8d758ae5-705c-4e1b-a62f-0defe5b830a6"
    },
    body: audio
  }
)
if (transcriptionResponse.status !== 200) {
  throw new Error("production transcription request failed")
}
const transcription = await transcriptionResponse.json()
if (transcription.transcript !== "Production container transcript.") {
  throw new Error("production transcription response was invalid")
}

const forbiddenResponse = await authenticatedFetch(
  "/v1/transcribe",
  healthToken,
  {
    method: "POST",
    headers: {
      "content-type": "audio/wav",
      "content-length": String(audio.byteLength),
      "x-hex-request-id": "8d758ae5-705c-4e1b-a62f-0defe5b830a7"
    },
    body: audio
  }
)
if (forbiddenResponse.status !== 401) {
  throw new Error("health-only principal was allowed to transcribe")
}
