// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for `VaultData.swift`'s pure logic - run via
// `FM_RUN_VAULT_DATA_TESTS=1 .build/debug/FirstmateCockpit`, same convention
// as `HostStoreSelfTest.swift`/`YamlBeautifySelfTest.swift`. Covers only the
// parts of `VaultSource` that don't need a real `av` binary: token safety
// (what's allowed to be spliced into a shell command unquoted), the two
// command-string builders, and `av doctor --json` parsing against the exact
// shape `av` returned on this machine during development (see
// `VaultController.swift`'s header for the live probes that established the
// rest of this file's behavior - `av list` returning bare names, `av save`
// requiring a real `/dev/tty`, `av inject` working fine as a background
// process).

import Foundation

enum VaultDataSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: isSafeToken

        check("plain name is safe", VaultSource.isSafeToken("MANJESH_GITHUB_TOKEN"))
        check("dash/underscore mix is safe", VaultSource.isSafeToken("my-secret_1"))
        check("empty is unsafe", !VaultSource.isSafeToken(""))
        check("space is unsafe", !VaultSource.isSafeToken("has space"))
        check("shell metachar is unsafe", !VaultSource.isSafeToken("a;rm -rf /"))
        check("quote is unsafe", !VaultSource.isSafeToken("a'b"))
        check("dollar is unsafe", !VaultSource.isSafeToken("$HOME"))

        // MARK: saveSecretCommand

        check("save command for a safe name", VaultSource.saveSecretCommand(name: "MY_TOKEN") == "av save MY_TOKEN")
        check("save command rejects an unsafe name", VaultSource.saveSecretCommand(name: "a; rm -rf /") == nil)

        // MARK: injectCommand

        check(
            "inject command for a safe name + command",
            VaultSource.injectCommand(secretName: "MY_TOKEN", command: "gh auth status") == "av inject +MY_TOKEN -- gh auth status"
        )
        check("inject command rejects an unsafe secret name", VaultSource.injectCommand(secretName: "a b", command: "echo hi") == nil)
        check("inject command rejects an empty command", VaultSource.injectCommand(secretName: "MY_TOKEN", command: "   ") == nil)

        // MARK: parseDoctorTools

        let hardenedOnly = VaultSource.parseDoctorTools(#"{"results":[{"commands":["claude"],"issues":[],"name":"claude"}]}"#)
        check("one hardened tool parsed", hardenedOnly.count == 1)
        check("hardened tool name/commands", hardenedOnly.first?.name == "claude" && hardenedOnly.first?.commands == ["claude"])
        check("hardened tool status", hardenedOnly.first?.status == .hardened)

        let withIssues = VaultSource.parseDoctorTools(
            #"{"results":[{"commands":["gh"],"issues":[{"explanation":"x"},{"explanation":"y"}],"name":"gh"}]}"#
        )
        check("tool with issues parsed", withIssues.count == 1)
        check("tool with issues status", withIssues.first?.status == .needsAttention(issueCount: 2))

        let malformed = VaultSource.parseDoctorTools("not json")
        check("malformed JSON yields no tools, not a crash", malformed.isEmpty)

        let empty = VaultSource.parseDoctorTools(#"{"results":[]}"#)
        check("empty results yields no tools", empty.isEmpty)

        if failures.isEmpty {
            print("VaultDataSelfTest: all checks passed")
            return true
        } else {
            print("VaultDataSelfTest: FAILED - \(failures.joined(separator: "; "))")
            return false
        }
    }
}
