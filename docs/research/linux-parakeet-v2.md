# Linux speech stack for Parakeet TDT 0.6B v2

Research date: 2026-08-20

Resolves: [#4](https://github.com/nmarch213/Hex/issues/4)

Wayfinder map: [#1](https://github.com/nmarch213/Hex/issues/1)

## Decision

Hex's exact FluidAudio implementation cannot run on Linux. It is a Swift package whose declared platforms are macOS 14 and iOS 17, and it loads four compiled Core ML bundles plus a vocabulary. Those `.mlmodelc` artifacts and FluidAudio's Apple framework integration are not a portable Linux runtime. Copying Hex's model cache to Ronin would not change that.

Linux can, however, run the same English model lineage without substituting a different speech engine. The canonical model must be identified as `nvidia/parakeet-tdt-0.6b-v2`: NVIDIA's 600-million-parameter English FastConformer-TDT checkpoint with punctuation and capitalization, 16 kHz mono input, and a CC-BY-4.0 model license.

The recommended Ronin stack is:

1. Use NVIDIA NeMo Speech with the original `nvidia/parakeet-tdt-0.6b-v2` `.nemo` checkpoint as the correctness oracle and fallback runtime.
2. Evaluate `parakeet.cpp` with an F32 GGUF converted from that exact NVIDIA checkpoint as the deployment candidate. It has current Linux CPU, CUDA, and Vulkan builds, a small HTTP server, and no Python inference dependency. Its included server is deliberately one-request-at-a-time, which matches the initial single-user deployment but must not be mistaken for a production concurrency layer.
3. Promote `parakeet.cpp` only after a Ronin benchmark demonstrates acceptable transcript parity and latency. Start with F32; compare F16 or Q8 only after the F32 baseline passes.
4. If the C++ port fails parity, stability, or latency gates, serve the same checkpoint through NeMo rather than silently changing to Whisper, Parakeet v3, CTC, or another model.

NVIDIA Speech NIM is an official alternative only if Ronin has a supported NVIDIA GPU and an NVIDIA AI Enterprise self-hosting license. `sherpa-onnx` is a secondary open-source candidate, not the first choice, because its v2 artifacts are converted ONNX models and its own tracker has a currently open report of empty output for some files that NeMo transcribes.

This decision does **not** claim that `parakeet.cpp` is already proven on Ronin. Ronin's CPU, RAM, GPU, VRAM, driver, and competing workload are not documented in this repository. The benchmark below is the remaining hardware-dependent gate, not an invitation to choose a different model.

## Confirmed facts

### What Hex runs today

- Hex names its English model `parakeet-tdt-0.6b-v2-coreml` and classifies it as English-only ([`ParakeetModel.swift`](../../HexCore/Sources/HexCore/Models/ParakeetModel.swift)).
- The live client maps that identifier to FluidAudio's `.v2`, downloads and retains an `AsrManager`, then returns only `result.text` ([`ParakeetClient.swift`](../../Hex/Clients/ParakeetClient.swift)).
- Before inference, Hex zero-pads clips shorter than 1.5 seconds. The helper accepts mono Float32 PCM for the padding path ([`ParakeetClipPreparer.swift`](../../Hex/Clients/ParakeetClipPreparer.swift)). This behavior belongs in the parity corpus; it is not proven to be a universal requirement of the NVIDIA checkpoint.
- The current `TranscriptionClient` is not a provider-neutral speech boundary. Its operation takes a local URL, a model name, WhisperKit `DecodingOptions`, and a `Progress` callback, and it also owns model download/lifecycle ([`TranscriptionClient.swift`](../../Hex/Clients/TranscriptionClient.swift)).

### Why FluidAudio/Core ML does not move to Linux

- FluidAudio's package manifest declares only macOS 14 and iOS 17. Its v2 loading guide requires `Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecision.mlmodelc`, and `parakeet_vocab.json`; the default compute configuration uses CPU plus Apple Neural Engine. ([FluidAudio `Package.swift`](https://github.com/FluidInference/FluidAudio/blob/main/Package.swift), [manual model-loading guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ManualModelLoading.md))
- FluidInference describes its artifact as a Core ML conversion of NVIDIA's v2 model for Apple platforms, with macOS 14+ and iOS 17+ support. Its model tree names `nvidia/parakeet-tdt-0.6b-v2` as the base model. ([FluidInference model card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml))
- FluidAudio documents v2 as **batch** English speech-to-text. Its sliding-window mode chunks, overlaps, and stitches an offline model; FluidAudio separately identifies cache-aware models as true streaming. ([FluidAudio model guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md))

Therefore “the same implementation on Linux” is impossible in the useful sense: the model lineage can be preserved, but the Core ML artifact, Apple compute backend, and FluidAudio runtime cannot.

### Canonical upstream model

NVIDIA's model card establishes the portable identity and semantics:

- Model: `nvidia/parakeet-tdt-0.6b-v2`
- Architecture: 600M-parameter FastConformer-TDT
- Language: English
- Input: mono 16 kHz audio; the documented file path accepts WAV and FLAC
- Output: text with punctuation and capitalization; timestamps are available
- License: CC-BY-4.0
- Intended runtime: NeMo; NVIDIA documents Linux and recommends GPU acceleration, while stating that at least 2 GB of RAM is required to load the model. Actual process memory and useful latency still need measurement on Ronin.

Source: [NVIDIA model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2).

## Linux runtime comparison

| Path | Model artifact and fidelity | CPU/GPU | Batch / streaming | Concurrency and deployment | License | Resolution |
| --- | --- | --- | --- | --- | --- | --- |
| **NVIDIA NeMo Speech** | Loads the original NVIDIA checkpoint from Hugging Face or a local `.nemo`; this is the reference implementation, not a format conversion. | PyTorch CPU is supported; NVIDIA GPU/CUDA is recommended for inference. Exact CPU latency and memory are unknown on Ronin. | `transcribe` supports batches and incremental consumption of batch results. v2 remains an offline, full-attention model. NeMo can apply buffered overlapping chunks to offline models, but that is not cache-aware native streaming. | Python process/container; Hex must supply the HTTP boundary, request queue, model lifetime, health checks, and worker policy. A single loaded model should be the starting point. | NeMo Speech Apache-2.0; model CC-BY-4.0. | **Correctness oracle and fallback.** Most faithful, heaviest deployment. |
| **`parakeet.cpp`** | Converts the same NVIDIA checkpoint to GGUF. F32 is the closest candidate to source values; F16/Q8/K-quants trade representation precision for size. The project reports byte-identical F32 v2 output versus NeMo, but the published v2 parity test is one approximately 7.4-second LibriSpeech clip, not a domain corpus. | Prebuilt Linux x64 CPU/CUDA/Vulkan and arm64 CPU artifacts; source uses ggml backends. Which backend wins is Ronin-specific. | Offline v2; its true cache-aware `--stream` path is for other streaming checkpoints. Library batch APIs exist for multiple 16 kHz mono float clips. | CLI, shared library, Docker images, and a small OpenAI-compatible HTTP server. The bundled server documents one request at a time; a queue is adequate initially, while concurrent serving would need LocalAI or a custom worker layer and measurement. | Runtime MIT; model CC-BY-4.0. | **Recommended serving candidate, gated by Ronin parity/benchmark.** Current releases exist, but it is a young community runtime. |
| **`sherpa-onnx`** | Publishes v2 encoder/decoder/joiner ONNX conversions made from the NVIDIA checkpoint, with INT8, FP16, and non-quantized variants plus conversion scripts. “Same source checkpoint” does not guarantee identical output after export/runtime changes. | Linux x64/arm64 CPU and CUDA builds are documented through ONNX Runtime. | The v2 recognizer is offline. Its “simulated streaming” example combines VAD/windowing with the offline recognizer; it is not native streaming. No cross-request batch contract is documented for this v2 path. | Library/CLI and server building blocks. Service queueing, worker count, and model sharing are deployment work. | Runtime Apache-2.0; model CC-BY-4.0. | **Secondary experiment only.** Run a broad parity corpus before trusting it; see open correctness report [#2258](https://github.com/k2-fsa/sherpa-onnx/issues/2258). |
| **NVIDIA Speech NIM** | NVIDIA container supports `parakeet-tdt-0.6b-v2` as `type=default`; optimized artifacts are managed inside the NIM stack. | Requires x86_64, NVIDIA compute capability 8.0+, and at least 16 GB VRAM. The documented v2 profile uses about 5.329 GB CPU memory and 13.75 GB GPU memory. | v2 is offline only; documented profile batch size is 1024. | GPU container exposing HTTP and gRPC; Docker or Helm. This is the most complete supported service shape. | Self-hosting requires NVIDIA AI Enterprise; model remains governed by its model terms. | **Use only if hardware and commercial license are already available.** Excessive for the initial personal service otherwise. |

Primary runtime sources:

- [NeMo Speech repository and requirements](https://github.com/NVIDIA-NeMo/Speech), [NeMo ASR inference guide](https://docs.nvidia.com/nemo/speech/nightly/asr/inference.html), and [official transcription/RTFx script](https://github.com/NVIDIA-NeMo/Speech/blob/main/examples/asr/transcribe_speech.py)
- [`parakeet.cpp` repository](https://github.com/mudler/parakeet.cpp), [v2 parity details](https://github.com/mudler/parakeet.cpp/blob/master/docs/parity.md), and [release artifacts](https://github.com/mudler/parakeet.cpp/releases)
- [`sherpa-onnx` repository](https://github.com/k2-fsa/sherpa-onnx), [v2 model/export documentation](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html), and [Linux installation](https://k2-fsa.github.io/sherpa/onnx/install/linux.html)
- [NVIDIA NIM v2 deployment](https://docs.nvidia.com/nim/speech/latest/asr/deploy-asr-models/parakeet-tdt.html), [ASR support matrix](https://docs.nvidia.com/nim/speech/latest/reference/support-matrix/asr.html), [prerequisites](https://docs.nvidia.com/nim/speech/latest/get-started/prerequisites.html), and [deployment shape](https://docs.nvidia.com/nim/speech/latest/deployment/index.html)

## Audio and decoding invariants

These are compatibility requirements for the first Ronin implementation:

1. The deployed identity is the NVIDIA English **v2 TDT** checkpoint. Do not treat “Parakeet” as sufficient identity; v3, CTC, RNNT, Unified, and streaming Parakeet checkpoints have different capabilities and outputs.
2. Normalize inference input to mono, 16 kHz linear Float32 PCM before the engine adapter. A network transport may accept an encoded recording, but decoding/resampling must happen before this engine boundary so every provider sees the same samples.
3. Use the TDT head and deterministic greedy decoding for the reference comparison. Keep NVIDIA's punctuation and capitalization. Do not normalize case or punctuation before testing exact-output parity.
4. Preserve Hex's short-clip behavior in the test matrix: compare unpadded audio and Hex-compatible zero-padding to 1.5 seconds. Choose one policy from evidence; do not accidentally inherit a Core ML workaround as an unexplained server rule.
5. V2 is offline. The first user flow should upload/submit a completed capture and receive one final transcript. Buffered reprocessing or VAD-driven “simulated streaming” is a separate UX/performance choice, not a property of the model.
6. Keep model loading out of the request path. Load one pinned model artifact on service start, expose readiness only after load/warmup, and initially serialize inference for the personal single-user workload.

## Minimum provider-neutral speech boundary

There are two boundaries, and they should not be conflated:

- The **transport boundary** may accept a complete encoded mobile recording because WAV/CAF/other upload choices concern the client and network.
- The **speech-engine boundary** receives normalized audio and returns the raw model transcript. This is the boundary that must remain provider-neutral.

The minimum engine contract is conceptually:

```text
SpeechRecognitionRequest
  requestID: RequestID
  audio: MonoPCM16kFloat32

SpeechRecognitionResult
  requestID: RequestID
  transcript: RawTranscript

SpeechRecognitionError
  cancelled | invalidAudio | unavailable | inferenceFailed
```

`requestID` supports correlation and cancellation. `audio` has a validated format by type/constructor rather than carrying provider options. `transcript` is the unmodified cased and punctuated string returned by v2.

The deployed model identity, artifact hash, runtime version, inference duration, and queue duration should be recorded as diagnostic metadata/events, not supplied as arbitrary per-request knobs. English v2, greedy TDT decoding, and the model artifact are deployment configuration for this first service. History creation, transcript transforms, clipboard/paste behavior, retries/idempotency, and UI progress remain outside the speech-engine boundary.

Do **not** include FluidAudio/WhisperKit types, a filesystem URL, Core ML compute units, GGUF quantization, ONNX providers, CUDA device numbers, beam settings, model downloading, or a generic `options` dictionary in this contract. Those belong to adapters and deployment configuration.

This narrow result preserves today's Hex semantic requirement—one raw transcript string—without selecting an unrelated fallback engine. It also leaves room for a later, separate streaming protocol without pretending that v2 supplies partial transcripts.

## Ronin benchmark gate

Published speed numbers are not selection evidence for Ronin. FluidAudio reports v2 LibriSpeech test-clean results on an M4 Pro (2.1% mean per-file WER, 145.8 overall RTFx), NVIDIA publishes a very high GPU/batch RTFx with an explicit batch-size caveat, `sherpa-onnx` publishes CPU results from other machines, and `parakeet.cpp` publishes comparisons from its own CPU/GPU hosts. Hardware, batch size, audio lengths, warmup, precision, and timed stages differ. ([FluidAudio benchmark](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md), [NVIDIA model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2))

Before promoting a Linux adapter:

1. **Inventory Ronin:** record CPU architecture/model, physical cores, RAM, NVIDIA/other GPU model, VRAM, compute capability, driver/runtime versions, and normal competing load.
2. **Pin artifacts:** record runtime commit/release, container digest if used, model source revision and checksum, format, precision/quantization, thread count, and decoder settings.
3. **Create one normalized corpus:** decode/resample once to mono 16 kHz Float32 and feed the same samples to Mac FluidAudio v2, NeMo v2, and the Linux candidate. Include silence; clips below 1.5 seconds; 2–5, 5–15, and 15–60 second dictations; noise; accents; punctuation; commands; proper names; technical terms; and spoken numbers. Keep a separately labeled LibriSpeech test-clean run for external comparability.
4. **Measure fidelity:** exact transcript equality against NeMo and FluidAudio; case/punctuation-sensitive character edit distance; conventional normalized WER/CER; empty-output rate; hallucinations on silence; and domain-term accuracy. Report F32 first, then each lower-precision artifact independently.
5. **Separate cold and warm timing:** process start, model download (if any), model load, first inference, warm inference, and shutdown. NeMo's own benchmark script warns that RTFx should include at least one warmup step.
6. **Measure the product latency:** from final audio byte available on Ronin to raw transcript available. Break out queue wait, decode/resample, inference, and response serialization. Report p50/p95/p99 by duration bucket and RTFx; do not hide short-clip fixed costs inside aggregate throughput.
7. **Exercise realistic concurrency:** steady concurrency 1, then bursts of 2 and 4. Record tail latency, throughput, failures, CPU/RAM, GPU/VRAM/utilization, thermal/throttling behavior, and whether multiple workers duplicate model memory. Start with a single loaded recognizer and bounded queue.
8. **Test operations:** cancellation, malformed/oversized audio, engine crash/restart, readiness during model load, and repeated requests. The same request must not corrupt later decoder state.

No numerical pass/fail target was specified in issue #4, so this research does not invent one. The implementation issue should set a latency budget for short dictation and an acceptable parity delta before running the gate. A candidate that is fast but changes transcript behavior materially has not replaced Hex's v2 path.

## Inferences and open implementation choices

The following are reasoned conclusions, not facts established by upstream documentation:

- `parakeet.cpp` is likely the simplest personal-service deployment because the release includes Linux binaries/containers and the bundled serial server matches an initial single-user queue. Its young age and narrow published v2 parity sample make the Ronin corpus mandatory.
- NeMo will likely consume more disk and memory than the C++/GGUF path, but only a pinned Ronin measurement can quantify the difference.
- F32 GGUF is the right first comparison artifact because it avoids intentional weight quantization. It still uses a different format, frontend implementation, and decoder runtime than NeMo/FluidAudio, so “F32” does not itself prove equivalent behavior.
- A full encoded-audio HTTP upload is sufficient for the initial stop-then-transcribe UX. Native streaming would add protocol state and choose a capability that v2 does not possess; it should not be designed into this issue.
- One-request-at-a-time inference is probably sufficient for one user, but mobile retries or overlapping devices can still create bursts. A bounded queue and explicit overload response are safer than allowing accidental unbounded concurrency.

## Final resolution

The Linux service should preserve **NVIDIA Parakeet TDT 0.6B v2**, not FluidAudio's Core ML packaging. Use NeMo plus the original checkpoint as the oracle/fallback and benchmark an F32 `parakeet.cpp` adapter as the preferred lightweight Ronin deployment. Keep the speech contract limited to normalized mono 16 kHz audio in and raw transcript out. Decide CPU versus GPU backend, precision, and worker count only from the pinned Ronin benchmark.
