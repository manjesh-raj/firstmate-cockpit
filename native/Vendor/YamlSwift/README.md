# Vendored YamlSwift

Source: [behrang/YamlSwift](https://github.com/behrang/YamlSwift), pinned to upstream `master`
commit `063286d0a66200b6ae0687c06914b19fe7c8dc83`. MIT licensed - see `LICENSE`.

## Why vendored, not a remote SPM dependency

This app deliberately has zero remote SPM dependencies (see `Vendor/SwiftTerm/README.md` for the
original reasoning) - `Package.resolved` doesn't exist. The Tools page's YAML validate/beautify
tool (cockpit-tools-page-core) needs a real YAML parser, not a hand-rolled one - a hand-rolled
subset was fine for the captain's original HTML mockup, but the whole point of this tool is that
the captain pastes real Kubernetes manifests into it, which use enough of the YAML spec (anchors,
multi-document `---` separators, block/flow scalars, folded strings) that a partial parser would
silently misparse or reject real input. YamlSwift is pure Swift (no C library, unlike Yams'
libyaml-backed alternative), small (~1,500 lines across 6 files), and MIT licensed - vendored here
verbatim, unmodified, the same way `Vendor/SwiftTerm` is vendored.

## What's used, and a real limitation worth knowing

`Yaml.load`/`Yaml.loadMultiple` (`Yaml.swift`) are what `ToolsController`'s YAML tool calls for
Validate and as the parse step of Beautify - `loadMultiple` is what makes multi-resource Kubernetes
manifests (documents separated by `---`) work correctly, not just a single top-level object.

There is no `save`/`dump` API upstream for producing YAML text back out of a parsed `Yaml` value -
`ToolsController.YamlTool` has its own small serializer for that (see its file), which is
serialization of an already-correctly-parsed tree, not YAML parsing, so it doesn't reintroduce the
"hand-rolled parser" problem this vendoring was meant to avoid. One consequence worth knowing:
`Yaml.dictionary` wraps a plain Swift `[Yaml: Yaml]`, which has no defined iteration order, so a
beautified document's map keys come out sorted alphabetically rather than preserving the source
file's original key order. That's a deliberate, documented trade-off (consistent, deterministic
output) rather than a bug - the same trade-off `JSONSerialization.WritingOptions.sortedKeys` makes
for the JSON tool on this same page.

## Re-syncing

If YamlSwift is ever updated, re-fetch `Sources/Yaml/*.swift` and `LICENSE` from the pinned commit
(or a newer one) into this directory, verbatim - there is no local patch here to reapply, unlike
SwiftTerm's vendoring.
