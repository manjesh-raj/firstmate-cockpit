

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation
import Yaml

// fm/cockpit-tools-yaml-order-perf-fix: permanent, pure-logic self-test for
// YamlBeautify's key-order fidelity - same `FM_RUN_..._TESTS=1` convention as
// DiffEngineSelfTest.swift/CronExplainerSelfTest.swift. Reproduces the exact
// shape the captain reported: a top-level `version` key before a `deployments`
// sequence, each deployment mapping with 10 keys in a specific, deliberately
// non-alphabetical order.
//
// fm/cockpit-tools-yaml-quotes-diff-perf extended this file (rather than
// adding a parallel test) with quoting-fidelity cases: the captain reported
// Beautify silently stripping quotes from a scalar like
// `selfservice: "tenant-setup-solution-modelling-api-self-service"` - safe
// for that specific unambiguous string, but not in general, since a quoted
// `"true"`/`"123"`/`"no"` is a *string* in YAML while the same text
// unquoted parses as a bool/number instead. See YAMLQuoteStyle.swift's
// header (Vendor/YamlSwift) for the parser-side fix this exercises.
enum YamlBeautifySelfTest {
    private static let sourceKeyOrder = [
        "name", "image", "migration", "sidekiq", "pre", "post",
        "awsbatch", "cronjob", "selfservice", "serviceaccountname",
    ]

    /// One field's value is quoted, matching the captain's exact report -
    /// see `test_quotingRoundTripsThroughBeautifyUnchanged` below.
    private static let quotedKey = "selfservice"

    private static func makeManifest(deploymentCount: Int, quoteSelfservice: Bool = false) -> String {
        var lines = ["version: 3", "deployments:"]
        for n in 0..<deploymentCount {
            for (i, key) in sourceKeyOrder.enumerated() {
                let rawValue = "\(key)-\(n)"
                let value = (quoteSelfservice && key == quotedKey) ? "\"\(rawValue)\"" : rawValue
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

        // A quoted scalar that would change YAML type if unquoted must stay
        // quoted through Beautify - the captain's core complaint (a quoted
        // string silently losing its quotes) generalized to the unsafe
        // cases: `"true"`/`"123"`/`"no"` are strings, not a bool/number/
        // string-that-looks-like-a-keyword, and Beautify must not decide
        // otherwise on its own.
        do {
            let source = """
            flags:
              boolAsString: "true"
              boolLiteral: true
              numAsString: "123"
              numLiteral: 123
              noAsString: "no"
              singleQuoted: 'plain-ish-value'
            """
            let doc = try Yaml.load(source)
            let output = YamlBeautify.dump([doc])
            let expectedLines = [
                "boolAsString: \"true\"",
                "boolLiteral: true",
                "numAsString: \"123\"",
                "numLiteral: 123",
                "noAsString: \"no\"",
                "singleQuoted: 'plain-ish-value'",
            ]
            let missing = expectedLines.filter { !output.contains($0) }
            if !missing.isEmpty {
                print("FAIL: quoted scalars did not round-trip unchanged. output:\n\(output)\nmissing lines: \(missing)")
                ok = false
            } else {
                print("PASS: quoted true/123/no scalars stayed quoted (type-changing quotes preserved)")
            }
        } catch {
            print("FAIL: could not parse/beautify quoted-scalar-type test: \(error)")
            ok = false
        }

        // The captain's exact reported shape: a representative sample of a
        // real file's quoting - some fields quoted, some not - must
        // round-trip through Beautify with quoting unchanged, using the
        // same manifest shape the key-order tests above already cover
        // (extended here rather than as a parallel test).
        do {
            let manifest = makeManifest(deploymentCount: 2, quoteSelfservice: true)
            let docs = try Yaml.loadMultiple(manifest)
            let output = YamlBeautify.dump(docs)
            var failures: [String] = []
            for n in 0..<2 {
                let quoted = "selfservice: \"selfservice-\(n)\""
                if !output.contains(quoted) {
                    failures.append("expected quoted line missing: \(quoted)")
                }
                for key in sourceKeyOrder where key != quotedKey {
                    let unquoted = "\(key): \(key)-\(n)"
                    if !output.contains(unquoted) {
                        failures.append("expected unquoted line missing: \(unquoted)")
                    }
                    if output.contains("\(key): \"\(key)-\(n)\"") {
                        failures.append("field that was unquoted in source got quoted: \(key)")
                    }
                }
            }
            if !failures.isEmpty {
                print("FAIL: mixed quoting did not round-trip.\n  \(failures.joined(separator: "\n  "))\noutput:\n\(output)")
                ok = false
            } else {
                print("PASS: mixed quoted/unquoted fields round-tripped with quoting unchanged")
            }
        } catch {
            print("FAIL: could not parse/beautify mixed-quoting manifest: \(error)")
            ok = false
        }

        return ok
    }
}

#endif
