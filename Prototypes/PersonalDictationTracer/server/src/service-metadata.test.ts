import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

import {
  NodeRuntimeImageDigest,
  ParakeetModelFilename,
  ParakeetModelRevision,
  ParakeetModelSHA256,
  ParakeetRuntimeImageDigest,
  ServiceVersion
} from "./service-metadata.js"

test("keeps completion-event version aligned with package metadata", async () => {
  const packageText = await readFile(
    new URL("../package.json", import.meta.url),
    "utf8"
  )
  const version = /"version"\s*:\s*"([^"]+)"/.exec(packageText)?.[1]

  assert.equal(version, ServiceVersion)
})

test("keeps emitted artifact IDs aligned with deployment pins", async () => {
  const [compose, dockerfile, preparation] = await Promise.all([
    readFile(new URL("../compose.yaml", import.meta.url), "utf8"),
    readFile(new URL("../Dockerfile", import.meta.url), "utf8"),
    readFile(new URL("../prepare-model.sh", import.meta.url), "utf8")
  ])

  assert.equal(compose.includes(ParakeetRuntimeImageDigest), true)
  assert.equal(compose.includes(ParakeetModelFilename), true)
  assert.equal(compose.includes(ParakeetModelSHA256), true)
  assert.equal(dockerfile.includes(NodeRuntimeImageDigest), true)
  assert.equal(preparation.includes(ParakeetModelRevision), true)
  assert.equal(preparation.includes(ParakeetModelFilename), true)
  assert.equal(preparation.includes(ParakeetModelSHA256), true)
})
