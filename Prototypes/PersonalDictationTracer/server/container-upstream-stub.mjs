#!/usr/bin/env node

import { createServer } from "node:http"

const MaximumRequestBytes = 20 * 1024 * 1024

const sendJSON = (response, status, value) => {
  const body = JSON.stringify(value)
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body)
  })
  response.end(body)
}

createServer((request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    sendJSON(response, 200, { status: "ok" })
    return
  }

  if (
    request.method !== "POST" ||
    request.url !== "/v1/audio/transcriptions"
  ) {
    sendJSON(response, 404, { error: "not found" })
    return
  }

  if (!(request.headers["content-type"] ?? "").startsWith("multipart/form-data;")) {
    sendJSON(response, 415, { error: "multipart form required" })
    return
  }

  let receivedBytes = 0
  const chunks = []
  request.on("data", (chunk) => {
    receivedBytes += chunk.length
    if (receivedBytes > MaximumRequestBytes) {
      request.destroy()
      return
    }
    chunks.push(chunk)
  })
  request.on("end", () => {
    const body = Buffer.concat(chunks)
    const formProjection = body.toString("latin1")
    if (
      !formProjection.includes('name="file"; filename="audio.wav"') ||
      !formProjection.includes("Content-Type: audio/wav") ||
      !formProjection.includes("RIFF") ||
      !formProjection.includes('name="response_format"') ||
      !formProjection.includes("\r\n\r\njson\r\n")
    ) {
      sendJSON(response, 400, { error: "invalid transcription form" })
      return
    }
    sendJSON(response, 200, { text: "Production container transcript." })
  })
}).listen(8080, "0.0.0.0")
