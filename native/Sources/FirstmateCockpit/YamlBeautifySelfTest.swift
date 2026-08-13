import Foundation
import Yaml

// fm/cockpit-tools-yaml-order-perf-fix: permanent, pure-logic self-test for
// YamlBeautify's key-order fidelity - same `FM_RUN_..._TESTS=1` convention as
// DiffEngineSelfTest.swift/CronExplainerSelfTest.swift. Reproduces the exact
// shape the captain reported: a top-level `version` key before a `deployments`
// sequence, each deployment mapping with 10 keys in a specific, deliberately
// non-alphabetical order.
enum YamlBeautifySelfTest {
    private static let sourceKeyOrder = [
        "name", "image", "migration", "sidekiq", "pre", "post",
        "awsbatch", "cronjob", "selfservice", "serviceaccountname",
    ]

    private static func makeManifest(deploymentCount: Int) -> String {
        var lines = ["version: 3", "deployments:"]
        for n in 0..<deploymentCount {
            for (i, key) in sourceKeyOrder.enumerated() {
                let value = "\(key)-\(n)"
                lines.append(i == 0 ? "  - \(key): \(value)" : "    \(key): \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Walks a beautified document's raw text and extracts, in the order they
    /// appear, the key names at a given fixed indent - a lightweight
    /// order-check that doesn't need a second parser. A `"  - key: val"` list
    /// item line is normalized to look like `"    key: val"` first (the dash
    /// and its following space occupy the same two columns a nesting level
    /// would), so the first key of a list item and every key after it are
    /// findable at one consistent indent.
    private static func keysAtIndent(_ text: String, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var keys: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var body = String(rawLine)
            let leadingSpaces = body.prefix(while: { $0 == " " }).count
            let afterSpaces = body.dropFirst(leadingSpaces)
            if afterSpaces.hasPrefix("- ") {
                body = String(repeating: " ", count: leadingSpaces + 2) + afterSpaces.dropFirst(2)
            }
            guard body.hasPrefix(pad), !body.hasPrefix(pad + " ") else { continue }
            let trimmed = body.dropFirst(pad.count)
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            keys.append(String(trimmed[trimmed.startIndex..<colonIndex]))
        }
        return keys
    }

    static func run() -> Bool {
        var ok = true

        // Top-level key order: `version` before `deployments`, matching input.
        let manifest = makeManifest(deploymentCount: 3)
        do {
            let docs = try Yaml.loadMultiple(manifest)
            let output = YamlBeautify.dump(docs)
            let topLevelKeys = keysAtIndent(output, indent: 0)
            if topLevelKeys != ["version", "deployments"] {
                print("FAIL: top-level key order = \(topLevelKeys), expected [version, deployments]")
                ok = false
            } else {
                print("PASS: top-level key order preserved (\(topLevelKeys))")
            }

            // Every deployment mapping's own 10 keys, in source order.
            let deploymentKeys = keysAtIndent(output, indent: 4)
            let expected = Array(repeating: sourceKeyOrder, count: 3).flatMap { $0 }
            if deploymentKeys != expected {
                print("FAIL: deployment key order mismatch.\n  got:      \(deploymentKeys)\n  expected: \(expected)")
                ok = false
            } else {
                print("PASS: all \(3) deployments' 10-key order preserved end to end")
            }
        } catch {
            print("FAIL: could not parse/beautify test manifest: \(error)")
            ok = false
        }

        // Nested-map order at a deeper level (map-of-maps, not just a
        // sequence of maps) - guards against a fix that only special-cased
        // the sequence-of-mappings shape.
        do {
            let nested = "outer:\n  zeta: 1\n  alpha: 2\n  mu: 3\n"
            let doc = try Yaml.load(nested)
            let output = YamlBeautify.dump([doc])
            let keys = keysAtIndent(output, indent: 2)
            if keys != ["zeta", "alpha", "mu"] {
                print("FAIL: nested map key order = \(keys), expected [zeta, alpha, mu]")
                ok = false
            } else {
                print("PASS: nested map key order preserved (\(keys))")
            }
        } catch {
            print("FAIL: could not parse/beautify nested-map test: \(error)")
            ok = false
        }

        return ok
    }
}
