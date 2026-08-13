// Manjesh Grand Line - native macOS app.
//
// A small YAML pretty-printer for the Tools page's YAML Beautify action
// (cockpit-tools-page-core). This is deliberately NOT a parser - it only
// serializes a `Yaml` tree that the vendored `Yaml.loadMultiple` (Vendor/
// YamlSwift) has already parsed, so it doesn't reintroduce the "hand-rolled
// YAML parsing" problem the vendoring was meant to avoid.
//
// `Yaml.dictionary` used to wrap a plain Swift `[Yaml: Yaml]`, which has no
// defined iteration order, so this beautifier alphabetized map keys rather
// than preserving the source document's original order - captain-reported
// as a real data-fidelity bug (fm/cockpit-tools-yaml-order-perf-fix), not a
// stylistic trade-off worth keeping: YAML mapping key order is meaningful.
// `Yaml.dictionary` now wraps `YamlOrderedMap` (Vendor/YamlSwift's local
// patch, see its README's "Local patch" section), which preserves insertion
// order end to end from parse to here - this file now walks `dict.pairs` in
// that order instead of sorting, at every nesting level.

import Foundation
import Yaml

enum YamlBeautify {
    /// Renders one or more parsed documents back to YAML text, documents
    /// separated by `---` the same way `Yaml.loadMultiple` expects them on
    /// input.
    static func dump(_ documents: [Yaml]) -> String {
        documents.map { dumpLines($0, indent: 0).joined(separator: "\n") }.joined(separator: "\n---\n")
    }

    private static func dumpLines(_ value: Yaml, indent: Int) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .dictionary(let dict):
            guard !dict.isEmpty else { return [pad + "{}"] }
            var lines: [String] = []
            for (key, v) in dict.pairs {
                let keyText = scalarText(key)
                switch v {
                case .dictionary(let d) where !d.isEmpty:
                    lines.append(pad + keyText + ":")
                    lines.append(contentsOf: dumpLines(v, indent: indent + 1))
                case .array(let a) where !a.isEmpty:
                    lines.append(pad + keyText + ":")
                    lines.append(contentsOf: dumpLines(v, indent: indent + 1))
                default:
                    lines.append(pad + keyText + ": " + scalarText(v))
                }
            }
            return lines
        case .array(let arr):
            guard !arr.isEmpty else { return [pad + "[]"] }
            var lines: [String] = []
            for item in arr {
                switch item {
                case .dictionary(let d) where !d.isEmpty:
                    let childLines = dumpLines(item, indent: indent + 1)
                    let childPad = String(repeating: "  ", count: indent + 1)
                    let first = childLines.first ?? ""
                    let firstTrimmed = first.hasPrefix(childPad) ? String(first.dropFirst(childPad.count)) : first
                    lines.append(pad + "- " + firstTrimmed)
                    lines.append(contentsOf: childLines.dropFirst())
                case .array(let a) where !a.isEmpty:
                    lines.append(pad + "-")
                    lines.append(contentsOf: dumpLines(item, indent: indent + 1))
                default:
                    lines.append(pad + "- " + scalarText(item))
                }
            }
            return lines
        default:
            return [pad + scalarText(value)]
        }
    }

    private static func scalarText(_ value: Yaml) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s, let quoted):
            // A scalar that was quoted in the source is re-emitted quoted,
            // in the same style, unconditionally - never re-decided by the
            // "does this need quoting" heuristic below. That heuristic is
            // only for a genuinely unquoted (`.plain`) source scalar, where
            // there is no original quoting to preserve and something still
            // has to decide whether it's safe to leave bare after this
            // beautifier re-indents/re-flows the document
            // (fm/cockpit-tools-yaml-quotes-diff-perf - see
            // YAMLQuoteStyle.swift's header for the full rationale: a
            // quoted `"true"`/`"123"`/`"no"` is a *string*, and silently
            // dropping its quotes would change what a downstream consumer
            // parses it as, not just its formatting).
            switch quoted {
            case .plain: return quotedIfNeeded(s)
            case .double: return doubleQuoted(s)
            case .single: return singleQuoted(s)
            }
        case .dictionary: return "{}"
        case .array: return "[]"
        }
    }

    private static let reservedScalars: Set<String> = [
        "null", "Null", "NULL", "~",
        "true", "True", "TRUE", "false", "False", "FALSE",
        "yes", "Yes", "YES", "no", "No", "NO",
    ]

    /// A conservative "does this string need quoting to round-trip as YAML"
    /// check - errs toward quoting rather than risking an ambiguous scalar
    /// (a version string like "1.20" that would otherwise parse back as a
    /// double, a value that looks like a YAML reserved word, etc.). Only
    /// used for a scalar that was genuinely unquoted (`.plain`) in the
    /// source - see `scalarText` above.
    private static func quotedIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let needsQuote =
            reservedScalars.contains(s)
            || Double(s) != nil
            || trimmed != s
            || s.contains("\n")
            || s.contains(": ")
            || s.hasSuffix(":")
            || s.contains(" #")
            || (s.first.map { "-?:,[]{}#&*!|>'\"%@`".contains($0) } ?? false)
        guard needsQuote else { return s }
        return doubleQuoted(s)
    }

    private static func doubleQuoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func singleQuoted(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "''"))'"
    }
}
