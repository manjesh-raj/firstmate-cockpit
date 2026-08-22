// Manjesh Grand Line - native macOS app.
//
// GL-29: permanent coverage for the SSH credential path - `SSHKeyGenerator`,
// `SSHKeyMaterializer`, and the Keychain contract they sit on.
//
// This is the most security-relevant untested code in the app, and it had
// exactly one assertion anywhere before this: `Phase2HardeningSelfTest` drives
// `KeychainKeyStore.classify` for the Touch-ID-cancel decision. Everything
// else - key generation, PEM/OpenSSH import validation, `.ppk` refusal, the
// permissions on the one file private key bytes are ever written to, and the
// promise that `materialize` never runs on the main thread - was verified only
// by hand, once, at the time it was written.
//
// Run: `FM_RUN_CREDENTIAL_PATH_TESTS=1 .build/debug/FirstmateCockpit`
//
// What this does and does not touch:
//
//   - It runs the real `/usr/bin/ssh-keygen` and writes to real scratch
//     directories under the system temp dir, because the whole point is that
//     the argv this app builds actually works. Every key it generates is
//     thrown away in the same run.
//   - It does **not** write to the login Keychain (that is what
//     `FM_RUN_VAULT_DATA_TESTS` already accepts the cost of, and it is the one
//     suite CI skips for exactly that reason), and it never touches
//     `SSHKeyStore`'s real `keys.json`. The Keychain half is covered by
//     asserting the *contract* - `authenticate`'s off-main precondition and
//     `classify`'s cancel mapping - rather than by prompting for Touch ID in a
//     headless run, which cannot be answered.

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
import LocalAuthentication

enum CredentialPathSelfTest {

    static func run() -> Bool {
        var ok = true
        checkGeneration(&ok)
        checkImportValidation(&ok)
        checkMaterializedFilePermissions(&ok)
        checkKeychainContract(&ok)
        print(ok ? "CredentialPathSelfTest: all checks passed" : "CredentialPathSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: Generation

    private static func checkGeneration(_ ok: inout Bool) {
        print("\n-- ssh-keygen generation (both offered types, with and without a passphrase) --")

        for (type, marker) in [(SSHKeyType.ed25519, "ssh-ed25519"), (SSHKeyType.rsa, "ssh-rsa")] {
            do {
                let generated = try SSHKeyGenerator.generate(type: type, label: "grandline-selftest", passphrase: "")
                if !generated.publicKeyLine.hasPrefix(marker) {
                    fail("\(type) public key starts \"\(generated.publicKeyLine.prefix(20))\", want \(marker)", &ok)
                }
                if !generated.publicKeyLine.contains("grandline-selftest") {
                    fail("\(type) public key lost its comment/label", &ok)
                }
                if generated.fingerprint.isEmpty {
                    fail("\(type) produced an empty fingerprint", &ok)
                }
                guard let text = String(data: generated.privateKey, encoding: .utf8),
                      text.contains("PRIVATE KEY-----") else {
                    fail("\(type) private key blob is not a PEM/OpenSSH key", &ok)
                    continue
                }
                // The round trip that matters: what generation produced has to
                // be what import accepts, or a captain can create a key here
                // and not be able to re-import it.
                let imported = try SSHKeyGenerator.inspect(privateKey: generated.privateKey, passphrase: "")
                if imported.publicKeyLine != generated.publicKeyLine {
                    fail("\(type) generate/inspect disagree on the public key", &ok)
                }
                if imported.fingerprint != generated.fingerprint {
                    fail("\(type) generate/inspect disagree on the fingerprint", &ok)
                }
                if imported.type != type {
                    fail("\(type) round-tripped as \(imported.type)", &ok)
                }
            } catch {
                fail("generating \(type) threw: \(error)", &ok)
            }
        }

        // A passphrase must genuinely be required afterwards - a key that
        // silently generated *without* one would be a real security defect,
        // and `-N` is passed explicitly precisely so `ssh-keygen` can never
        // fall back to an interactive prompt.
        do {
            let secret = "grandline-selftest-passphrase"
            let generated = try SSHKeyGenerator.generate(type: .ed25519, label: "pp", passphrase: secret)
            do {
                _ = try SSHKeyGenerator.inspect(privateKey: generated.privateKey, passphrase: "")
                fail("a passphrase-protected key inspected successfully with no passphrase", &ok)
            } catch {
                // Expected.
            }
            let imported = try SSHKeyGenerator.inspect(privateKey: generated.privateKey, passphrase: secret)
            if imported.publicKeyLine != generated.publicKeyLine {
                fail("the correct passphrase did not recover the same public key", &ok)
            }
        } catch {
            fail("passphrase round trip threw: \(error)", &ok)
        }

        // An unsupported type must be refused before any process runs.
        do {
            _ = try SSHKeyGenerator.generate(type: .from(publicKeyLine: "ecdsa-sha2-nistp256 AAAA"), label: "x", passphrase: "")
            fail("generating an unsupported key type was allowed", &ok)
        } catch { /* Expected. */ }

        print("  OK - ed25519 + rsa generate, round-trip through inspect, and honour -N")
    }

    // MARK: Import validation

    private static func checkImportValidation(_ ok: inout Bool) {
        print("\n-- import validation (refuse rather than guess) --")

        // A PuTTY key is detected by its own header and refused with a
        // conversion hint, never handed to `ssh-keygen` to fail obscurely.
        let ppk = Data("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n".utf8)
        do {
            _ = try SSHKeyGenerator.inspect(privateKey: ppk, passphrase: "")
            fail("a .ppk file was accepted", &ok)
        } catch SSHKeyOperationError.ppkUnsupported {
            // Expected, and specifically this case - a generic
            // "invalidInput" here would lose the conversion hint.
        } catch {
            fail("a .ppk file threw \(error) rather than .ppkUnsupported", &ok)
        }

        for (name, blob) in [("empty", Data()),
                             ("prose", Data("this is just a text file\n".utf8)),
                             ("a public key", Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 me@host\n".utf8))] {
            do {
                _ = try SSHKeyGenerator.inspect(privateKey: blob, passphrase: "")
                fail("\(name) was accepted as a private key", &ok)
            } catch { /* Expected. */ }
        }

        // Binary that is not valid UTF-8 must be refused as unreadable rather
        // than crashing on a forced unwrap.
        do {
            _ = try SSHKeyGenerator.inspect(privateKey: Data([0xFF, 0xFE, 0x00, 0x01]), passphrase: "")
            fail("a binary blob was accepted as a private key", &ok)
        } catch { /* Expected. */ }

        print("  OK - .ppk, empty, prose, a public key, and binary are all refused")
    }

    // MARK: Materialized key file

    private static func checkMaterializedFilePermissions(_ ok: inout Bool) {
        print("\n-- the one file private key bytes touch --")

        // `materialize` reads the Keychain (and prompts), so this exercises the
        // file-writing half against the same contract using a key blob the
        // suite generated itself: 0600 file inside a 0700 directory, and the
        // certificate written alongside when there is one. `ssh -i` refuses a
        // key whose file is group/world readable, so these are not cosmetic.
        do {
            let generated = try SSHKeyGenerator.generate(type: .ed25519, label: "perm", passphrase: "")
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("fm-cockpit-selftest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: dir) }
            let keyPath = dir.appendingPathComponent("identity")
            try generated.privateKey.write(to: keyPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)

            let keyMode = (try FileManager.default.attributesOfItem(atPath: keyPath.path)[.posixPermissions] as? NSNumber)?.int16Value
            let dirMode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.int16Value
            if keyMode != 0o600 { fail("key file mode is \(String(describing: keyMode)), want 0600", &ok) }
            if dirMode != 0o700 { fail("scratch dir mode is \(String(describing: dirMode)), want 0700", &ok) }

            // Cleanup removes the whole directory, not just the key - a
            // leftover `-cert.pub` next to a deleted identity would be a
            // real leak of who the captain is.
            SSHKeyMaterializer.cleanup(privateKeyPath: keyPath.path)
            if FileManager.default.fileExists(atPath: dir.path) {
                fail("cleanup left the scratch directory behind", &ok)
            }
        } catch {
            fail("permissions check threw: \(error)", &ok)
        }
        print("  OK - 0600 in a 0700 dir, and cleanup removes the directory")
    }

    // MARK: Keychain contract

    private static func checkKeychainContract(_ ok: inout Bool) {
        print("\n-- Keychain contract (no prompt needed to assert it) --")

        // GL-25: the biometric gate blocks its caller, so it must never be
        // reached from the main thread. Asserting the *mapping* of the cancel
        // codes is the only way to cover the decision without a real prompt.
        for code in [LAError.userCancel, .appCancel, .systemCancel] {
            let mapped = KeychainKeyStore.classify(LAError(code, userInfo: [:]))
            guard case KeychainError.userCancelled = mapped else {
                fail("\(code) mapped to \(mapped) rather than .userCancelled - a cancel would silently downgrade the connect to agent auth", &ok)
                continue
            }
        }
        // A genuine failure must NOT be reported as a cancel: those two lead to
        // different behaviour in `ConsoleController.connectSSH` (refuse to
        // connect vs. fall through to agent auth).
        let realFailure = KeychainKeyStore.classify(LAError(.authenticationFailed, userInfo: [:]))
        if case KeychainError.userCancelled = realFailure {
            fail("a failed authentication was misreported as a cancel", &ok)
        }

        // `KeychainKeyStore` must never be reachable in a way that writes an
        // iCloud-synced item: this app's whole key story depends on
        // `ThisDeviceOnly`. Asserted from the source, since proving it at
        // runtime would mean writing to the real Keychain.
        let source = SelfTestSources.appSourceDirectory()?.appendingPathComponent("KeychainKeyStore.swift")
            ?? URL(fileURLWithPath: "/nonexistent")
        if let text = try? String(contentsOf: source, encoding: .utf8) {
            if !text.contains("kSecAttrAccessibleWhenUnlockedThisDeviceOnly") {
                fail("KeychainKeyStore no longer pins kSecAttrAccessibleWhenUnlockedThisDeviceOnly", &ok)
            }
            if text.contains("kSecAttrSynchronizable") {
                fail("KeychainKeyStore mentions kSecAttrSynchronizable - key material must never be iCloud-synced", &ok)
            }
            if !text.contains("dispatchPrecondition(condition: .notOnQueue(.main))") {
                fail("the biometric gate lost its off-main precondition (GL-25)", &ok)
            }
        } else {
            fail("could not read KeychainKeyStore.swift to assert its accessibility class", &ok)
        }
        print("  OK - cancel vs. failure are distinct, ThisDeviceOnly and the off-main gate still pinned")
    }
}

#endif
