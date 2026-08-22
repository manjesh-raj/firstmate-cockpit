// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `CertInspector` - same
// "env-var-gated, run and read the result" convention as
// `DiffEngineSelfTest.swift`, but unlike that one this test genuinely shells
// out to the real `/usr/bin/openssl` to (a) generate a real self-signed
// certificate with a SAN, and (b) independently parse that same certificate
// with `openssl x509 -noout ...`, then cross-checks `CertInspector`'s output
// against openssl's own - the live verification the task's acceptance
// criteria calls for, kept permanently rather than done once and discarded.
//
// Run with:
//   swift build && FM_RUN_CERT_INSPECTOR_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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

enum CertInspectorSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("realCertificateCrossChecksAgainstOpenSSL", test_realCertificateCrossChecksAgainstOpenSSL),
            ("malformedPEMIsRejected", test_malformedPEMIsRejected),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0 ? "CertInspectorSelfTest: all \(cases.count) cases passed" : "CertInspectorSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], cwd: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "failed to launch: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func test_realCertificateCrossChecksAgainstOpenSSL() -> String? {
        let dir = NSTemporaryDirectory() + "cockpit-cert-inspector-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let keyPath = dir + "/key.pem"
        let certPath = dir + "/cert.pem"

        let (genStatus, genOutput) = run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-keyout", keyPath, "-out", certPath,
            "-days", "365", "-nodes",
            "-subj", "/C=US/O=Manjesh Grand Line/CN=selftest.cockpit.local",
            "-addext", "subjectAltName=DNS:selftest.cockpit.local,DNS:alt.cockpit.local",
        ])
        guard genStatus == 0 else { return "openssl req -x509 failed (\(genStatus)): \(genOutput)" }

        guard let pem = try? String(contentsOfFile: certPath, encoding: .utf8) else { return "could not read generated cert" }
        let info: CertInfo
        do {
            info = try CertInspector.parse(pem: pem)
        } catch {
            return "CertInspector.parse threw on a real openssl-generated cert: \(error)"
        }

        // Cross-check against openssl's own independent parse of the same file.
        let (subjStatus, subjOut) = run("/usr/bin/openssl", ["x509", "-noout", "-subject", "-in", certPath])
        guard subjStatus == 0 else { return "openssl -subject failed: \(subjOut)" }
        guard info.subject.contains("CN=selftest.cockpit.local"), info.subject.contains("O=Manjesh Grand Line") else {
            return "CertInspector subject '\(info.subject)' doesn't contain expected components; openssl said: \(subjOut)"
        }

        let (issuerStatus, issuerOut) = run("/usr/bin/openssl", ["x509", "-noout", "-issuer", "-in", certPath])
        guard issuerStatus == 0 else { return "openssl -issuer failed: \(issuerOut)" }
        // Self-signed: issuer == subject.
        guard info.issuer.contains("CN=selftest.cockpit.local") else {
            return "CertInspector issuer '\(info.issuer)' doesn't match self-signed subject; openssl said: \(issuerOut)"
        }

        let (serialStatus, serialOut) = run("/usr/bin/openssl", ["x509", "-noout", "-serial", "-in", certPath])
        guard serialStatus == 0 else { return "openssl -serial failed: \(serialOut)" }
        // openssl prints "serial=AABBCC..." (no colons, uppercase); CertInspector's is colon-separated lowercase hex.
        let opensslSerialHex = serialOut
            .replacingOccurrences(of: "serial=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ourSerialHex = info.serialHex.replacingOccurrences(of: ":", with: "")
        guard ourSerialHex == opensslSerialHex || ourSerialHex.trimmingCharacters(in: CharacterSet(charactersIn: "0")) == opensslSerialHex.trimmingCharacters(in: CharacterSet(charactersIn: "0")) else {
            return "serial mismatch: CertInspector='\(ourSerialHex)' openssl='\(opensslSerialHex)'"
        }

        // `-ext subjectAltName` needs a real OpenSSL - the LibreSSL that ships
        // as macOS's own `/usr/bin/openssl` doesn't support it (confirmed
        // live: "unknown option -ext") - so this reads the SAN extension out
        // of the full `-text` dump instead, which both support.
        let (sanStatus, sanOut) = run("/usr/bin/openssl", ["x509", "-noout", "-text", "-in", certPath])
        guard sanStatus == 0 else { return "openssl -text failed: \(sanOut)" }
        guard sanOut.contains("selftest.cockpit.local"), sanOut.contains("alt.cockpit.local") else {
            return "openssl SAN output missing expected DNS names: \(sanOut)"
        }
        guard info.sans.contains(where: { $0.contains("selftest.cockpit.local") }),
              info.sans.contains(where: { $0.contains("alt.cockpit.local") }) else {
            return "CertInspector SANs \(info.sans) missing expected DNS names"
        }

        // A freshly generated 365-day cert should not be expired or not-yet-valid.
        guard !info.isExpired else { return "freshly generated cert reported as expired" }
        guard !info.isNotYetValid else { return "freshly generated cert reported as not yet valid" }

        return nil
    }

    private static func test_malformedPEMIsRejected() -> String? {
        do {
            _ = try CertInspector.parse(pem: "-----BEGIN CERTIFICATE-----\nnot valid base64!!!\n-----END CERTIFICATE-----")
            return "expected malformed PEM to throw"
        } catch {
            return nil
        }
    }
}

#endif
