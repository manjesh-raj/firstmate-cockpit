// Manjesh Grand Line - native macOS app.
//
// A small YAML pretty-printer for the Tools page's YAML Beautify action
// (cockpit-tools-page-core). This is deliberately NOT a parser - it only
// serializes a `Yaml` tree that the vendored `Yaml.loadMultiple` (Vendor/
// YamlSwift) has already parsed, so it doesn't reintroduce the "hand-rolled
// YAML parsing" problem the vendoring was meant to avoid.
//
// `Yaml.dictionary` wraps a plain Swift `[Yaml: Yaml]`, which has no defined
// iteration order, so map keys are sorted alphabetically here rather than
// preserving the source document's original order - a deliberate,
// documented trade-off for deterministic output (see Vendor/YamlSwift/
// README.md), the same one `JSONSerialization.WritingOptions.sortedKeys`
// makes for the JSON tool on this same page.

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
            for key in dict.keys.sorted(by: { sortKey($0) < sortKey($1) }) {
                let v = dict[key] ?? .null
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

    /// A stable string to sort map keys by - the raw string for a string key
    /// (the common case), otherwise its rendered scalar text.
    private static func sortKey(_ key: Yaml) -> String {
        if case let .string(s) = key { return s }
        return scalarText(key)
    }

    private static func scalarText(_ value: Yaml) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return quotedIfNeeded(s)
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
    /// double, a value that looks like a YAML reserved word, etc.).
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
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
