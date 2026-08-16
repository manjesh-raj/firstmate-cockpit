# Vendored whisper.cpp

Source: [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp), pinned to upstream tag
`v1.9.2` / commit `306c88f4d1286aec1bf96e544632897886af5501`. MIT licensed - see `LICENSE`.

## Why vendored, not the official `whisper.spm` remote package or CMake

This app deliberately has zero remote SPM dependencies (see `Vendor/SwiftTerm/README.md` for the
original reasoning) - `Package.resolved` doesn't exist. Dictation's local Whisper engine
(fm/grandline-dictation-whisper-engine) needs a real on-device transcription engine, and the
captain-approved plan explicitly rejected both the official `whisper.spm` remote Swift package and
building via CMake (this repo is CLT-only, `swift build`-only, no Xcode - see `native/README.md`).
So the plain C/C++ source is vendored here and compiled by a hand-written SPM target
(`CWhisper` in `Package.swift`) instead of upstream's own CMake build.

## What's vendored, and what was deliberately left out

Upstream's build (ggml + whisper.cpp) supports a large matrix of optional backends (Metal, CUDA,
Vulkan, SYCL, CANN, Hexagon, OpenVINO, ...) and CPU acceleration paths (AMX, llamafile SGEMM,
KleidiAI, dynamic multi-variant backend loading). None of that is needed for a single-machine,
CPU-only, Apple Silicon build, and vendoring it all would mean reverse-engineering a much larger
slice of upstream's CMake logic than this app's own build needs. `Sources/CWhisper/` contains only:

- `include/` (public, exposed to Swift): `whisper.h` (the API `WhisperEngine.swift` calls) plus the
  ggml headers it directly `#include`s (`ggml.h`, `ggml-alloc.h`, `ggml-backend.h`, `ggml-cpu.h`).
  Swift's ClangImporter only resolves a target's `publicHeadersPath` when importing a C target as a
  module - it does not honor `cSettings`/`cxxSettings` header search paths the way compiling the
  target's own `.c`/`.cpp` files does, so every header `whisper.h` itself includes has to live here
  too, not just in a private search-path directory.
- `ggml-src/`: `ggml.c`/`ggml.cpp`/`ggml-alloc.c`/`ggml-backend.cpp`/`ggml-backend-meta.cpp`/
  `ggml-opt.cpp`/`ggml-threading.cpp`/`ggml-quants.c`/`gguf.cpp` (upstream's `ggml-base` library)
  plus `ggml-backend-dl.cpp`/`ggml-backend-reg.cpp` (upstream's `ggml` library) - exactly the file
  list upstream's own `ggml/src/CMakeLists.txt` compiles into those two targets.
- `ggml-src/ggml-cpu/`: the CPU backend's generic sources (`ggml-cpu.c`/`.cpp`, `quants.c`,
  `repack.cpp`, `traits.cpp`, `binary-ops.cpp`, `unary-ops.cpp`, `vec.cpp`, `ops.cpp`, `hbm.cpp`)
  plus `arch/arm/quants.c`, `arch/arm/repack.cpp`, `arch/arm/cpu-feats.cpp` - the real ARM NEON
  kernels upstream's own `ggml-cpu/CMakeLists.txt` adds when `GGML_SYSTEM_ARCH STREQUAL "ARM"`.
  **Not** vendored: `amx/` (x86 AMX matmul kernels - harmless dead code on arm64 per upstream's own
  CMake, which lists them unconditionally, but skipped here as genuinely unneeded), `llamafile/`
  (opt-in `GGML_LLAMAFILE`, off), `kleidiai/`/`spacemit`/`hbm` beyond the base file (all opt-in,
  off). No arch-dispatch/multi-variant machinery (`GGML_CPU_ALL_VARIANTS`) - this is a single,
  static, baseline-ARM-NEON build, not upstream's runtime-feature-detecting fat binary.
- `whisper-src/`: `whisper.cpp` + `whisper-arch.h` only - upstream's own `src/CMakeLists.txt` shows
  the `whisper` library is exactly these two files (plus the already-public `whisper.h`); CoreML/
  OpenVINO acceleration and the separate `parakeet` model family are both opt-in/unrelated and not
  vendored.

**Backend registration is CPU-only by construction, not by convention**: `ggml-backend-reg.cpp`
`#include`s each optional backend's header (`ggml-metal.h`, `ggml-cuda.h`, etc.) behind its own
`#ifdef GGML_USE_<BACKEND>` guard - since only `GGML_USE_CPU` is ever defined (`Package.swift`'s
`cSettings`/`cxxSettings`), none of those other headers are ever included, and none of those
backends need to exist in this vendor tree at all for the file to compile.

## Version/commit macros

Upstream generates `GGML_VERSION`/`GGML_COMMIT`/`WHISPER_VERSION` via CMake's `project(VERSION ...)`
+ `target_compile_definitions`, which doesn't exist in this hand-written SPM target - `Package.swift`
defines them directly as string literals matching the pinned tag/commit above instead.

## Model file: not vendored, downloaded on demand

The `large-v3-turbo` ggml model (quantized `q5_0`, ~547MB) is never bundled into the app or this
vendor directory - `WhisperModel.swift` downloads it on demand into
`~/Library/Application Support/FirstmateCockpit/whisper/`, from the same host/path convention
upstream's own `models/download-ggml-model.sh` uses
(`https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin` - live-
verified to resolve to a real ~547MB file before wiring this up, not guessed). Upstream publishes
no checksum manifest for these files; `WhisperModel.swift`'s validation is a file-size floor plus a
check that the file starts with `GGML_FILE_MAGIC` (`0x67676d6c`, the same magic
`whisper_model_load` itself checks) - a file that passes both but is still truncated mid-tensor-data
is caught one layer further up, by `WhisperCppEngine.init?` failing to load it (`DictationEngine`
then falls back to Apple Speech, per its own contract).

## Performance note

This is a plain baseline-ARM-NEON CPU build with no dynamic multi-variant dispatch, no AMX, no
Metal - real-world transcription latency on Apple Silicon is meaningfully slower than upstream's
own prebuilt binaries or a from-source CMake build with `GGML_CPU_ALL_VARIANTS`/Metal enabled,
since those pick up additional SIMD paths (dotprod/i8mm) and, optionally, GPU acceleration this
vendor tree deliberately doesn't include. If real-world latency turns out to be a problem, the
first thing to reach for is `GGML_USE_ACCELERATE` (Apple's Accelerate framework, already linkable
with no extra vendoring) before considering a Metal backend (which would need vendoring
`ggml-metal.m`/its shader source and wiring an SPM `.process` resource step, similar to how
`Vendor/SwiftTerm`'s own Metal shader is already handled).

## Re-syncing

If whisper.cpp is ever updated, re-diff upstream's `ggml/src/CMakeLists.txt` and
`ggml/src/ggml-cpu/CMakeLists.txt` for the exact file list (source layout does shift between
releases), re-fetch matching files into the structure above, and re-verify the `GGML_VERSION`/
`GGML_COMMIT`/`WHISPER_VERSION` string literals in `Package.swift` against the new pinned tag.
