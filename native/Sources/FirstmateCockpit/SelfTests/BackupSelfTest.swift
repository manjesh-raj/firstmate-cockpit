// Manjesh Grand Line - native macOS app.
//
// A real, end-to-end exercise of the export/import/diff/apply path
// (`BackupData.swift`) against actual on-disk stores - not just reasoning
// about the code. Run via `FM_RUN_BACKUP_TESTS=1 .build/debug/FirstmateCockpit`
// (main.swift), the same env-var-gated, permanent self-test convention this
// file's neighbors already use for pure-Swift logic with no AppKit window to
// screenshot (`SRELeadBridgeSelfTest.swift`, `SRELeadMarkdownSelfTest.swift`).
//
// Exercises: writing a bundle from one set of hosts/snippets/keys, reading it
// back on a "different machine" (separate scratch store files, driven by
// `HostStore`/`SSHKeyStore`/`SnippetStore`'s own `FM_HOSTS_FILE`/
// `FM_KEYS_FILE`/`FM_SNIPPETS_FILE` overrides), diffing against empty stores
// (expect all `.new`), applying, re-diffing the unchanged result (expect all
// `.unchanged`), editing one host locally and re-diffing (expect exactly that
// one `.changed`), and grepping the actual written bundle file's bytes for
// anything that looks like private key material - never just trusting that
// `SSHKey` has no such field. Also covers Dictation's vocabulary/shortcut
// (`fm/grandline-dictation-vocab-backup`): a fresh word imports as `.new`, an
// already-present one (case-insensitively) as `.unchanged`, the shortcut
// changes when the bundle's differs from what's configured, and
// `DictationHistoryEntry`/history is never present in the exported bytes at
// all - it's per-machine usage data, deliberately excluded from the bundle.
//
// One case here is specifically about a *removed* field rather than an added
// one: `fm/grandline-remove-session-logging` dropped
// `BackupSettings.sessionLoggingDefault` when the session-logging feature was
// deleted, so a `.glbackup` a captain exported from an earlier build still
// carries that key. `legacyBundleWithRemovedKeyStillDecodes` asserts that
// bundle imports rather than failing the decode - which is what makes
// dropping an optional field from this format safe with no `formatVersion`
// bump, in the same way adding one already was.

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

import AppKit
import Foundation

enum BackupSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            if condition {
                print("[backup-test] PASS: \(label)")
            } else {
                print("[backup-test] FAIL: \(label)")
                ok = false
            }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("glbackup-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // `AppSettings.shared` is backed by the real `UserDefaults.standard` -
        // there's no scratch-file override for it the way the stores have
        // `FM_*_FILE`/`FM_*_DIR`. Save whatever the real machine's dictation
        // shortcut is set to and restore it unconditionally, so this test
        // never leaves the captain's actual configured shortcut altered.
        let realShortcut = AppSettings.shared.dictationShortcut
        defer { AppSettings.shared.dictationShortcut = realShortcut }

        // MARK: "Machine A" - the source of the export.
        setenv("FM_HOSTS_FILE", tmp.appendingPathComponent("a-hosts.json").path, 1)
        setenv("FM_KEYS_FILE", tmp.appendingPathComponent("a-keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", tmp.appendingPathComponent("a-snippets.json").path, 1)
        setenv("FM_DICTATION_DIR", tmp.appendingPathComponent("a-dictation").path, 1)
        let hostStoreA = HostStore()
        let keyStoreA = SSHKeyStore()
        let snippetStoreA = SnippetStore()
        let dictationStoreA = DictationStore()
        dictationStoreA.addVocabularyWord("Pramata")
        dictationStoreA.addVocabularyWord("Grand Line")
        let shortcutA = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue, isModifierOnly: false)
        AppSettings.shared.dictationShortcut = shortcutA
        // Real usage data - must never appear in the exported bundle, see
        // this file's header and `BackupData.swift`'s header.
        dictationStoreA.recordHistory(text: "THIS-IS-HISTORY-AND-MUST-NEVER-APPEAR-IN-A-BACKUP-FILE", durationSeconds: 4, date: Date(timeIntervalSince1970: 0))

        var key = SSHKey(label: "Bastion key", type: .ed25519, publicKey: "ssh-ed25519 AAAAC3example test@a", fingerprint: "SHA256:abcdefTestFingerprint")
        // A real Keychain write, exactly like the Keys screen/host editor's
        // "+ New Key…" flow - `addNew` writes secret bytes to the Keychain
        // FIRST, then the non-secret metadata to `keyStoreA`.
        let privateKeyMaterial = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nTHIS-MUST-NEVER-APPEAR-IN-A-BACKUP-FILE\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
        let passphrase = "correct-horse-battery-staple-THIS-MUST-NEVER-LEAK"
        do {
            try keyStoreA.addNew(key, privateKeyData: privateKeyMaterial, passphrase: passphrase)
        } catch {
            print("[backup-test] Keychain write failed (\(error.localizedDescription)) - continuing without a real Keychain-backed key; the no-secrets-in-bundle check still holds since SSHKey itself carries no secret field.")
            keyStoreA.add(key)
        }
        key = keyStoreA.keys[0]

        var bastion = Host(label: "Prod bastion", address: "10.0.0.4", port: 2222, username: "deploy")
        bastion.keyID = key.id
        bastion.tags = ["prod"]
        hostStoreA.add(bastion)
        hostStoreA.add(Host(label: "Staging box", address: "10.0.0.5"))
        snippetStoreA.add(Snippet(label: "tail logs", command: "tail -f /var/log/app.log"))

        let bundle = GrandLineBackupBuilder.build(hosts: hostStoreA.hosts, snippets: snippetStoreA.snippets, allKeys: keyStoreA.keys, dictationStore: dictationStoreA)
        check(bundle.hosts.count == 2, "bundle carries both hosts")
        check(bundle.snippets.count == 1, "bundle carries the one snippet")
        check(bundle.keys.count == 1 && bundle.keys[0].id == key.id, "bundle carries only the referenced key's metadata")
        check(bundle.dictation?.vocabulary?.count == 2, "bundle carries both vocabulary words")
        check(bundle.dictation?.vocabulary?.contains("Pramata") == true && bundle.dictation?.vocabulary?.contains("Grand Line") == true, "bundle carries the exact vocabulary words")
        check(bundle.dictation?.shortcut == shortcutA, "bundle carries the configured shortcut")

        let bundleURL = tmp.appendingPathComponent("export.glbackup")
        do {
            let data = try GrandLineBackupFile.encode(bundle)
            try data.write(to: bundleURL)
        } catch {
            check(false, "wrote the bundle to disk (\(error.localizedDescription))")
            return ok
        }

        // The actual byte content of the written file, grepped for anything
        // that looks like the private key or passphrase above - not a
        // structural argument about `SSHKey`'s fields.
        let rawBundleText = (try? String(contentsOf: bundleURL, encoding: .utf8)) ?? ""
        check(!rawBundleText.contains("THIS-MUST-NEVER-APPEAR-IN-A-BACKUP-FILE"), "exported file bytes contain no private key material")
        check(!rawBundleText.contains(passphrase), "exported file bytes contain no passphrase")
        check(!rawBundleText.contains("BEGIN OPENSSH PRIVATE KEY"), "exported file bytes contain no PEM/OpenSSH key header")
        check(rawBundleText.contains(key.fingerprint), "exported file bytes DO contain the key's public fingerprint (metadata is expected)")
        check(rawBundleText.contains("Pramata") && rawBundleText.contains("Grand Line"), "exported file bytes DO contain the dictation vocabulary words (expected)")
        check(!rawBundleText.contains("THIS-IS-HISTORY-AND-MUST-NEVER-APPEAR-IN-A-BACKUP-FILE"), "exported file bytes contain no transcription history text")
        check(!rawBundleText.lowercased().contains("history"), "exported bundle has no \"history\" key at all - it's per-machine usage data, deliberately excluded")

        // MARK: "Machine B" - a different machine, starting empty.
        setenv("FM_HOSTS_FILE", tmp.appendingPathComponent("b-hosts.json").path, 1)
        setenv("FM_KEYS_FILE", tmp.appendingPathComponent("b-keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", tmp.appendingPathComponent("b-snippets.json").path, 1)
        setenv("FM_DICTATION_DIR", tmp.appendingPathComponent("b-dictation").path, 1)
        let hostStoreB = HostStore()
        let keyStoreB = SSHKeyStore()
        let snippetStoreB = SnippetStore()
        let dictationStoreB = DictationStore()
        // Machine B already has one of the two words, case-differently
        // spelled - the diff should still recognize it as already present.
        dictationStoreB.addVocabularyWord("pramata")
        let shortcutB = DictationShortcut.defaultShortcut
        check(hostStoreB.hosts.isEmpty && snippetStoreB.snippets.isEmpty, "machine B starts with empty stores")

        guard let readBackData = try? Data(contentsOf: bundleURL), let readBack = try? GrandLineBackupFile.decode(readBackData) else {
            check(false, "read the bundle back")
            return ok
        }

        let firstDiff = BackupImport.diff(
            bundle: readBack, existingHosts: hostStoreB.hosts, existingSnippets: snippetStoreB.snippets, existingKeys: keyStoreB.keys,
            existingVocabulary: dictationStoreB.vocabulary, existingShortcut: shortcutB
        )
        check(firstDiff.newHostsCount == 2 && firstDiff.changedHostsCount == 0 && firstDiff.unchangedHostsCount == 0, "first import diff: both hosts are new")
        check(firstDiff.newSnippetsCount == 1, "first import diff: the snippet is new")
        check(firstDiff.keyWarnings.count == 1 && firstDiff.keyWarnings[0].contains("Prod bastion"), "first import diff: flags the bastion's missing key by name")
        check(firstDiff.newVocabularyCount == 1 && firstDiff.unchangedVocabularyCount == 1, "first import diff: one vocabulary word new, one already present (case-insensitively)")
        check(firstDiff.vocabularyRows.first(where: { $0.word == "Grand Line" })?.status == .new, "first import diff: \"Grand Line\" is the new word")
        check(firstDiff.vocabularyRows.first(where: { $0.word == "Pramata" })?.status == .unchanged, "first import diff: \"Pramata\" matches machine B's \"pramata\" case-insensitively")
        check(firstDiff.shortcutStatus == .changed, "first import diff: shortcut differs from machine B's default")

        BackupImport.apply(firstDiff, bundle: readBack, hostStore: hostStoreB, snippetStore: snippetStoreB, dictationStore: dictationStoreB)
        check(hostStoreB.hosts.count == 2, "machine B now has both hosts")
        check(snippetStoreB.snippets.count == 1, "machine B now has the snippet")
        check(hostStoreB.hosts.contains { $0.label == "Prod bastion" && $0.keyID == key.id }, "machine B's bastion still references the same key id (still dangling, by design - never auto-created)")
        check(!keyStoreB.keys.contains { $0.id == key.id }, "machine B's key store was NOT modified by the import (metadata is informational only)")
        check(dictationStoreB.vocabulary.count == 2 && dictationStoreB.vocabulary.contains("Grand Line") && dictationStoreB.vocabulary.contains("pramata"), "machine B's vocabulary gained the new word and kept its own casing of the already-present one")
        check(AppSettings.shared.dictationShortcut == shortcutA, "machine B's shortcut now matches the imported bundle's")
        check(dictationStoreB.history.isEmpty, "machine B's history is untouched by the import - nothing to apply, since none was ever in the bundle")

        // Re-importing the identical bundle should now show everything as unchanged.
        let secondDiff = BackupImport.diff(
            bundle: readBack, existingHosts: hostStoreB.hosts, existingSnippets: snippetStoreB.snippets, existingKeys: keyStoreB.keys,
            existingVocabulary: dictationStoreB.vocabulary, existingShortcut: AppSettings.shared.dictationShortcut
        )
        check(secondDiff.unchangedHostsCount == 2 && secondDiff.newHostsCount == 0 && secondDiff.changedHostsCount == 0, "second import diff: both hosts now unchanged")
        check(secondDiff.unchangedSnippetsCount == 1, "second import diff: the snippet now unchanged")
        check(secondDiff.newVocabularyCount == 0 && secondDiff.unchangedVocabularyCount == 2, "second import diff: both vocabulary words now unchanged")
        check(secondDiff.shortcutStatus == .unchanged, "second import diff: shortcut now unchanged")

        // Edit one host locally on machine B, then re-diff: exactly that one
        // should show as `.changed`, matched by id, everything else untouched.
        if var editedStaging = hostStoreB.hosts.first(where: { $0.label == "Staging box" }) {
            editedStaging.port = 2200
            hostStoreB.update(editedStaging)
        }
        let thirdDiff = BackupImport.diff(
            bundle: readBack, existingHosts: hostStoreB.hosts, existingSnippets: snippetStoreB.snippets, existingKeys: keyStoreB.keys,
            existingVocabulary: dictationStoreB.vocabulary, existingShortcut: AppSettings.shared.dictationShortcut
        )
        check(thirdDiff.changedHostsCount == 1, "third import diff: exactly one host changed after a local edit")
        check(thirdDiff.hostRows.first(where: { $0.label == "Staging box" })?.status == .changed, "third import diff: the edited host is the one flagged changed")
        check(thirdDiff.hostRows.first(where: { $0.label == "Prod bastion" })?.status == .unchanged, "third import diff: the untouched host is still unchanged")

        BackupImport.apply(thirdDiff, bundle: readBack, hostStore: hostStoreB, snippetStore: snippetStoreB, dictationStore: dictationStoreB)
        check(hostStoreB.hosts.first(where: { $0.label == "Staging box" })?.port == 22, "re-applying the bundle reverts the local edit back to the exported value")

        // A future, unsupported format version must be rejected, not silently misread.
        var futureBundle = bundle
        futureBundle.formatVersion = GrandLineBackup.currentFormatVersion + 1
        if let futureData = try? GrandLineBackupFile.encode(futureBundle) {
            do {
                _ = try GrandLineBackupFile.decode(futureData)
                check(false, "a future format version is rejected on decode")
            } catch is BackupError {
                check(true, "a future format version is rejected on decode")
            } catch {
                check(false, "a future format version is rejected on decode (wrong error type: \(error))")
            }
        }

        // fm/grandline-remove-session-logging: a bundle exported by an
        // earlier build still carries the now-deleted
        // `BackupSettings.sessionLoggingDefault` key. Decoding it must
        // succeed and simply ignore that key - never throw - and every
        // setting this file still declares must survive alongside it.
        // Built by injecting the legacy key into a real encoded bundle's
        // JSON rather than hand-writing a whole bundle literal, so this
        // case cannot drift out of shape as the format grows.
        if let realData = try? GrandLineBackupFile.encode(bundle),
           var json = (try? JSONSerialization.jsonObject(with: realData)) as? [String: Any] {
            var settings = (json["settings"] as? [String: Any]) ?? [:]
            settings["sessionLoggingDefault"] = true
            settings["mirrorTarget"] = "legacy-session"
            json["settings"] = settings
            if let legacyData = try? JSONSerialization.data(withJSONObject: json) {
                // Guard against this case passing vacuously: the bytes being
                // decoded must genuinely carry the removed key.
                check(String(data: legacyData, encoding: .utf8)?.contains("sessionLoggingDefault") == true,
                      "the legacy bundle's bytes genuinely carry the removed sessionLoggingDefault key")
                do {
                    let legacy = try GrandLineBackupFile.decode(legacyData)
                    check(true, "a legacy bundle carrying the removed sessionLoggingDefault key still decodes")
                    check(legacy.settings.mirrorTarget == "legacy-session",
                          "the legacy bundle's other settings still decode alongside the removed key")
                    check(legacy.hosts.count == bundle.hosts.count,
                          "the legacy bundle's hosts still decode alongside the removed key")
                } catch {
                    check(false, "a legacy bundle carrying the removed sessionLoggingDefault key still decodes (threw: \(error))")
                }
            }
        }

        return ok
    }
}

#endif
