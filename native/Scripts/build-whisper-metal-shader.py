#!/usr/bin/env python3
"""Merges the vendored ggml-metal shader source into one self-contained
Metal source file and re-generates WhisperMetalShaderSource.swift.

Why this exists (fm/grandline-dictation-whisper-metal-accel): whisper.cpp's
ggml-metal.metal has `#include "ggml-common.h"` and `#include
"ggml-metal-impl.h"` lines that only resolve when the Metal compiler has a
real header search path - which a plain NSString handed to
`MTLDevice.makeLibrary(source:options:)` at runtime never has (no include
path can be attached to a source string). Upstream's own CMake build solves
this with a sed-based text merge for its "embedded library" build mode (see
`ggml/src/ggml-metal/CMakeLists.txt`'s `GGML_METAL_EMBED_LIBRARY` branch) -
this script does the same merge, once, at vendor time, then base64-encodes
the result into a generated Swift source file so it ships inside the
compiled binary itself (same convention as `CaptainIcon.swift`'s embedded
PNG - no dependency on SwiftPM resource-bundle packaging, which this app's
`build_native_app.sh` does not copy into the assembled .app at all).

Run this again only when re-syncing whisper.cpp's vendored Metal sources
from upstream (see Vendor/whisper.cpp/README.md's "Re-syncing" section) -
the three input files below are already vendored in this repo, this script
does not fetch anything from the network.
"""

import base64
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
METAL_DIR = ROOT / "Vendor/whisper.cpp/Sources/CWhisper/ggml-src/ggml-metal"
COMMON_H = ROOT / "Vendor/whisper.cpp/Sources/CWhisper/ggml-src/ggml-common.h"
OUT_SWIFT = ROOT / "Sources/FirstmateCockpit/WhisperMetalShaderSource.swift"

PREAMBLE_PATTERN = re.compile(
    r'#if defined\(GGML_METAL_EMBED_LIBRARY\)\n'
    r'__embed_ggml-common\.h__\n'
    r'#else\n'
    r'#include "ggml-common\.h"\n'
    r'#endif\n'
    r'#include "ggml-metal-impl\.h"\n'
)


def merge() -> str:
    metal_src = (METAL_DIR / "ggml-metal.metal").read_text()
    common_h = COMMON_H.read_text()
    impl_h = (METAL_DIR / "ggml-metal-impl.h").read_text()

    m = PREAMBLE_PATTERN.search(metal_src)
    if not m:
        sys.exit(
            "build-whisper-metal-shader.py: preamble pattern not found in "
            "ggml-metal.metal - upstream's include/embed preamble layout may "
            "have changed; re-check against the new source before editing "
            "this pattern."
        )

    return (
        metal_src[: m.start()]
        + "// ---- inlined ggml-common.h (merged by build-whisper-metal-shader.py) ----\n"
        + common_h
        + "\n// ---- inlined ggml-metal-impl.h (merged by build-whisper-metal-shader.py) ----\n"
        + impl_h
        + "\n// ---- end inlined headers ----\n"
        + metal_src[m.end() :]
    )


def write_swift(merged_source: str) -> None:
    encoded = base64.b64encode(merged_source.encode("utf-8")).decode("ascii")
    # Wrap at a fixed width so the generated file isn't one gigantic line -
    # purely for readability/diffability, has no effect on the decoded value.
    lines = [encoded[i : i + 120] for i in range(0, len(encoded), 120)]
    chunks = ",\n".join(f'    "{line}"' for line in lines)

    swift_source = f'''import Foundation

// Manjesh Grand Line - native macOS app.
//
// GENERATED FILE - do not hand-edit. Produced by
// `native/Scripts/build-whisper-metal-shader.py` from the vendored
// `Vendor/whisper.cpp/Sources/CWhisper/ggml-src/ggml-metal/ggml-metal.metal`
// (+ `ggml-common.h` + `ggml-metal-impl.h`, merged the same way upstream's
// own CMake `GGML_METAL_EMBED_LIBRARY` build mode does - see that script's
// own header comment and `Vendor/whisper.cpp/README.md`'s "Metal
// acceleration" section for the full reasoning).
//
// Embedded as base64 (not a plain Swift string literal) purely to avoid
// escaping the shader source's own quotes/backslashes - same convention
// `CaptainIcon.swift` used for its embedded PNG. `WhisperMetalRuntime.swift`
// decodes this once per launch and writes it to a real file on disk, since
// whisper.cpp's Metal backend needs an actual `ggml-metal.metal` file path
// (via the `GGML_METAL_PATH_RESOURCES` env var) to compile at runtime - a
// SwiftPM resource bundle was deliberately not used instead, since
// `build_native_app.sh` never copies any `*.bundle` directory into the
// assembled .app (confirmed by reading that script).
enum WhisperMetalShaderSource {{
    /// The merged, self-contained Metal shader source text (ggml-common.h +
    /// ggml-metal-impl.h inlined into ggml-metal.metal, matching upstream's
    /// own embedded-library merge) - decoded once, lazily, from the base64
    /// payload below.
    static let text: String = {{
        let base64 = base64Chunks.joined()
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {{
            fatalError("WhisperMetalShaderSource: embedded shader payload failed to base64-decode - this indicates the generated file itself is corrupt, not a runtime condition; re-run build-whisper-metal-shader.py")
        }}
        return decoded
    }}()

    private static let base64Chunks: [String] = [
{chunks}
    ]
}}
'''
    OUT_SWIFT.write_text(swift_source)


def main() -> None:
    merged = merge()
    write_swift(merged)
    print(f"Merged shader source: {len(merged)} bytes")
    print(f"Wrote {OUT_SWIFT}")


if __name__ == "__main__":
    main()
