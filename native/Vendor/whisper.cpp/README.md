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
KleidiAI, dynamic multi-variant backend loading). Only Metal (fm/grandline-dictation-whisper-
metal-accel, see "Metal acceleration" below) and the baseline ARM NEON CPU path are relevant to a
single-machine Apple Silicon build - vendoring the rest would mean reverse-engineering a much
larger slice of upstream's CMake logic than this app's own build needs. `Sources/CWhisper/`
contains only:

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

**Backend registration is CPU+Metal-only by construction, not by convention**: `ggml-backend-reg.cpp`
`#include`s each optional backend's header (`ggml-metal.h`, `ggml-cuda.h`, etc.) behind its own
`#ifdef GGML_USE_<BACKEND>` guard - since only `GGML_USE_CPU`/`GGML_USE_METAL` are ever defined
(`Package.swift`'s `cSettings`/`cxxSettings`), none of the other backends' headers are ever
included, and none of those backends need to exist in this vendor tree at all for the file to
compile.

- `ggml-src/ggml-metal/`: the Metal backend (fm/grandline-dictation-whisper-metal-accel) - exactly
  the file list upstream's own `ggml/src/ggml-metal/CMakeLists.txt` compiles into the `ggml-metal`
  library (`ggml-metal.cpp`, `ggml-metal-device.{cpp,m}`, `ggml-metal-common.cpp`,
  `ggml-metal-context.m`, `ggml-metal-ops.cpp`, plus the private `ggml-metal-impl.h`/
  `ggml-metal-common.h`/`ggml-metal-device.h`/`ggml-metal-context.h`/`ggml-metal-ops.h` headers) and
  the public `include/ggml-metal.h`. The raw `ggml-metal.metal` shader source is also vendored here
  (for provenance/re-sync - see "Metal acceleration" below for how it's actually built into the app,
  which is not a plain compile of this file). No CUDA/Vulkan/SYCL/etc backend, and no
  `GGML_METAL_EMBED_LIBRARY`/CMake asm-embedding machinery - that mechanism needs a build-time
  assembler step this plain SPM target doesn't have; see "Metal acceleration" for the alternative
  actually used here.

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

## Metal acceleration (fm/grandline-dictation-whisper-metal-accel)

The original CPU-only vendor pass measured real-world transcription latency on Apple Silicon at
**several minutes for an 11-second clip** (whisper.cpp's own `samples/jfk.wav`, on the
`large-v3-turbo` q5_0 model) - correct, but far too slow for interactive dictation. Metal
acceleration fixes this: **the same clip on the same model now transcribes in well under a
second with Metal enabled, live-measured at ~0.48s in isolation (~180-490x faster than the prior
CPU-only baseline, and ~23x faster than real-time for an 11-second clip)** - see "Live
measurements" below for the full before/after numbers and how they were taken. Transcript text is
unchanged either way (confirmed byte-for-byte identical on the same fixture) - Metal is strictly a
speed change, not an accuracy trade-off.

### No CMake, no Xcode - how the shader gets built

Upstream's Metal backend needs a compiled `.metallib` (or, for a from-source build, a real
`ggml-metal.metal` file plus a header search path so its `#include "ggml-common.h"`/
`#include "ggml-metal-impl.h"` lines resolve) - neither of which a plain `swift build` naturally
produces, since there's no CMake step and no Xcode asset-catalog/metal-shader build phase here.
Two things make it work anyway, both handled entirely by this app rather than upstream's own
build:

1. **The shader source is pre-merged at vendor time, not left with unresolved `#include`s.**
   `native/Scripts/build-whisper-metal-shader.py` inlines `ggml-common.h` and `ggml-metal-impl.h`
   directly into `ggml-metal.metal`'s text - the exact same text substitution upstream's own CMake
   `GGML_METAL_EMBED_LIBRARY` build mode does via `sed` (see that CMake target's own custom
   command) - producing one self-contained shader source with no include-path dependency at all.
   Re-run this script (no network access needed - it only reads the three vendored files already
   in this directory) any time `ggml-metal.metal`/`ggml-common.h`/`ggml-metal-impl.h` are
   re-synced from upstream.
2. **That merged source is embedded in the compiled Swift binary itself, not shipped as an SPM
   resource.** The script base64-encodes it into a generated file,
   `Sources/FirstmateCockpit/WhisperMetalShaderSource.swift` (same convention `CaptainIcon.swift`
   established for its embedded PNG - see that bullet in the top-level `CLAUDE.md` for the full
   "why not an SPM resource bundle" reasoning, which applies identically here: `build_native_app.sh`
   never copies any SwiftPM-generated `*.bundle` directory into the assembled `.app`, so a resource
   bundle would work in `swift run` and silently break in the packaged app). At runtime,
   `WhisperMetalRuntime.swift` decodes this text, writes it to a real file under
   `~/Library/Application Support/FirstmateCockpit/whisper/` (the same directory
   `WhisperModelManager` already resolves), and points whisper.cpp's own
   `GGML_METAL_PATH_RESOURCES` environment variable there - a real, documented upstream mechanism
   for exactly this "no bundle" situation, checked by `ggml_metal_library_init`
   (`ggml-src/ggml-metal/ggml-metal-device.m`) before it would otherwise give up.

`Package.swift`'s `CWhisper` target adds `GGML_USE_METAL`, the vendored `ggml-metal/*.{cpp,m}`
sources (auto-discovered by SwiftPM's normal recursive globbing - no explicit `sources:` list
needed), and links `Metal`/`MetalKit`/`Foundation`. Two non-obvious build fixes were needed to get
there, both scoped to this one target via `cSettings`, not applied project-wide:

- **ARC has to be turned back off for the vendored Objective-C files** (`.unsafeFlags(["-fno-objc-arc"])`).
  `ggml-metal-device.m`/`ggml-metal-context.m` are written for manual reference counting (explicit
  `release` calls, raw `void *` <-> `id<MTLDevice>` casts with no `__bridge`) - upstream's own CMake
  build never enables ARC for these files, but SwiftPM's default clang invocation does for any
  Objective-C source, so it has to be explicitly disabled here to match what the vendored code
  actually expects.
- **`SWIFTPM_MODULE_BUNDLE` needs a fallback definition.** SwiftPM defines `SWIFT_PACKAGE` for every
  target, which steers `ggml_metal_library_init` into a branch expecting a `SWIFTPM_MODULE_BUNDLE`
  macro - one SwiftPM only auto-generates for targets that declare `resources:`, which this target
  deliberately does not (see point 2 above). `Package.swift` defines it directly as the same
  class-based bundle lookup upstream's own non-`SWIFT_PACKAGE` branch already uses
  (`[NSBundle bundleForClass:[GGMLMetalClass class]]`) - it only ever matters as a first,
  expected-to-miss probe before the `GGML_METAL_PATH_RESOURCES` env var (point 2 above) is checked.

### A real crash found and fixed: never call `whisper_init` with `use_gpu = true` before confirming Metal actually works

The first working version of this task assumed whisper.cpp's own graceful degradation (a missing
GPU device is handled cleanly, falling back to CPU) would also cover "the Metal shader fails to
compile." Live-forcing that exact failure (see "Live measurements" below) instead found a real
crash one layer deeper: `whisper_init`'s `make_buft_list` (`whisper-src/whisper.cpp`) adds the GPU
device's buffer type to the model's buffer-type list whenever `params.use_gpu` is `true`,
**unconditionally** - it does not check whether `whisper_backend_init_gpu` actually produced a
working backend for that device. When the Metal library fails to load,
`whisper_backend_init_gpu` correctly returns `nil` and no Metal backend gets registered, but the
model's tensors are still pre-allocated into the (now backend-less) `MTL0` buffer type, and
`ggml_backend_sched_split_graph` hits an unrecoverable `ggml_abort` the moment it tries to schedule
an op against a buffer no live backend claims. This can't be caught from Swift (a ggml abort calls
the C `abort()`, not a throwable Swift error) - the fix had to happen before whisper.cpp is ever
told `use_gpu = true`, not by relying on it to degrade gracefully on its own.

The fix, entirely on the Swift side (`whisper-src/whisper.cpp` itself is unmodified):
`WhisperMetalRuntime.metalCanCompileShader()` performs the exact same compile
`ggml_metal_library_init` would attempt - same device (`MTLCreateSystemDefaultDevice()`), same
resolution order (an `FM_WHISPER_METAL_RESOURCES_OVERRIDE` test-only override first, else the real
embedded shader text) - directly from Swift, before `WhisperCppEngine.init?` ever calls into
whisper.cpp. `cparams.use_gpu` is only ever set from this check's result, never unconditionally.
If it succeeds, whisper.cpp's own internal compile of the identical source is guaranteed to
succeed too (same device, same text), so the crash path above can no longer be reached; if it
fails (no GPU, denied access, a corrupted/missing shader file), `use_gpu` stays `false` and
whisper.cpp only ever sees its own already-safe, unmodified CPU-only path. The result is cached
for the process's lifetime.

### Live measurements

All of the following were run against a real downloaded `ggml-large-v3-turbo-q5_0.bin` and
whisper.cpp's own real `samples/jfk.wav` fixture, via
`FM_RUN_WHISPER_ENGINE_TESTS=1 FM_WHISPER_TEST_MODEL_PATH=... FM_WHISPER_TEST_AUDIO_PATH=...
.build/debug/FirstmateCockpit` (`WhisperEngineSelfTest.swift`'s real-model self-test), on real
Apple Silicon hardware (Apple M5 Pro):

- **Metal enabled, isolated run**: `transcribe()` itself took **0.48s** for the ~11s clip (a cold
  first-ever shader compile on this machine took an extra ~9.1s one-time JIT cost, dropping to
  ~0.013s on every subsequent process launch - macOS caches compiled Metal libraries system-wide,
  keyed by source+device, so this cost is paid at most once per machine, not once per recording).
- **CPU-only (Metal deliberately forced to fail via `FM_WHISPER_METAL_RESOURCES_OVERRIDE` pointed
  at an empty directory)**: `transcribe()` took **235.9s** (~3.9 minutes) for the identical clip and
  model - consistent with the original CPU-only vendor pass's "several minutes" finding, confirming
  this is a fair apples-to-apples baseline, not a different bottleneck.
- **Both runs produced the exact same transcript**: `"And so, my fellow Americans, ask not what
  your country can do for you, ask what you can do for your country."` - Metal changed speed, not
  output.
- **The forced-CPU-fallback run above also exited cleanly with no crash** (`whisper_backend_init_gpu:
  no GPU found`, then a normal CPU-backend transcription) - direct, live proof of the crash-fix
  described above, not just a code-review claim. `WhisperEngineSelfTest.testMetalFallbackDoesNotCrash()`
  automates this exact scenario permanently: it spawns a genuinely separate child process (a crash
  can't be caught in-process, only observed as a child's exit status) with
  `FM_WHISPER_METAL_RESOURCES_OVERRIDE` pointed at an empty directory, and asserts the child exits
  with status 0 and still produces the correct transcript.

## Re-syncing

If whisper.cpp is ever updated, re-diff upstream's `ggml/src/CMakeLists.txt`,
`ggml/src/ggml-cpu/CMakeLists.txt`, and `ggml/src/ggml-metal/CMakeLists.txt` for the exact file
list (source layout does shift between releases), re-fetch matching files into the structure
above, re-verify the `GGML_VERSION`/`GGML_COMMIT`/`WHISPER_VERSION` string literals in
`Package.swift` against the new pinned tag, and **re-run
`python3 native/Scripts/build-whisper-metal-shader.py`** to regenerate
`WhisperMetalShaderSource.swift` from the newly-synced `ggml-metal.metal`/`ggml-common.h`/
`ggml-metal-impl.h` - the embedded shader source does not update itself just because the vendored
`.metal`/`.h` files changed on disk. If upstream's own include/embed preamble in `ggml-metal.metal`
has changed shape, that script will fail loudly (a regex match assertion) rather than silently
emit a wrong merge - update the pattern there to match the new layout first.
