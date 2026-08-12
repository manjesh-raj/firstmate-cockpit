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
// `SSHKey` has no such field.

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

        // MARK: "Machine A" - the source of the export.
        setenv("FM_HOSTS_FILE", tmp.appendingPathComponent("a-hosts.json").path, 1)
        setenv("FM_KEYS_FILE", tmp.appendingPathComponent("a-keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", tmp.appendingPathComponent("a-snippets.json").path, 1)
        let hostStoreA = HostStore()
        let keyStoreA = SSHKeyStore()
        let snippetStoreA = SnippetStore()

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

        let bundle = GrandLineBackupBuilder.build(hosts: hostStoreA.hosts, snippets: snippetStoreA.snippets, allKeys: keyStoreA.keys)
        check(bundle.hosts.count == 2, "bundle carries both hosts")
        check(bundle.snippets.count == 1, "bundle carries the one snippet")
        check(bundle.keys.count == 1 && bundle.keys[0].id == key.id, "bundle carries only the referenced key's metadata")

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

        // MARK: "Machine B" - a different machine, starting empty.
        setenv("FM_HOSTS_FILE", tmp.appendingPathComponent("b-hosts.json").path, 1)
        setenv("FM_KEYS_FILE", tmp.appendingPathComponent("b-keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", tmp.appendingPathComponent("b-snippets.json").path, 1)
        let hostStoreB = HostStore()
        let keyStoreB = SSHKeyStore()
        let snippetStoreB = SnippetStore()
        check(hostStoreB.hosts.isEmpty && snippetStoreB.snippets.isEmpty, "machine B starts with empty stores")

        guard let readBackData = try? Data(contentsOf: bundleURL), let readBack = try? GrandLineBackupFile.decode(readBackData) else {
            check(false, "read the bundle back")
            return ok
        }

        let firstDiff = BackupImport.diff(bundle: readBack, existingHosts: hostStoreB.hosts, existingSnippets: snippetStoreB.snippets, existingKeys: keyStoreB.keys)
        check(firstDiff.newHostsCount == 2 && firstDiff.changedHostsCount == 0 && firstDiff.unchangedHostsCount == 0, "first import diff: both hosts are new")
        check(firstDiff.newSnippetsCount == 1, "first import diff: the snippet is new")
        check(firstDiff.keyWarnings.count == 1 && firstDiff.keyWarnings[0].contains("Prod bastion"), "first import diff: flags the bastion's missing key by name")

        BackupImport.apply(firstDiff, bundle: readBack, hostStore: hostStoreB, snippetStore: snippetStoreB)
        check(hostStoreB.hosts.count == 2, "machine B now has both hosts")
        check(snippetStoreB.snippets.count == 1, "machine B now has the snippet")
        check(hostStoreB.hosts.contains { $0.label == "Prod bastion" && $0.keyID == key.id }, "machine B's bastion still references the same key id (still dangling, by design - never auto-created)")
        check(!keyStoreB.keys.contains { $0.id == key.id }, "machine B's key store was NOT modified by the import (metadata is informational only)")

        // Re-importing the identical bundle should now show everything as unchanged.
        let secondDiff = BackupImport.diff(bundle: readBack, existingHosts: hostStoreB.hosts, existingSnippets: snippetStoreB.snippets, existingKeys: keyStoreB.keys)
        check(secondDiff.unchangedHostsCount == 2 && secondDiff.newHostsCount == 0 && secondDiff.changedHostsCount == 0, "second import diff: both hosts now unchanged")
        check(secondDiff.unchangedSnippetsCount == 1, "second import diff: the snippet now unchanged")

        // Edit one host locally on machine B, then re-diff: exactly that one
        // should show as `.changed`, matched by id, everything else untouched.
        if var editedStaging = hostStoreB.hosts.first(where: { $0.label == "Staging box" }) {
            editedStaging.port = 2200
            hostStoreB.update(editedStaging)
        }
        let thirdDiff = BackupImport.diff(bundle: readBack, existingHosts: hostStoreB.hosts, existingSnippets: snippetStoreB.snippets, existingKeys: keyStoreB.keys)
        check(thirdDiff.changedHostsCount == 1, "third import diff: exactly one host changed after a local edit")
        check(thirdDiff.hostRows.first(where: { $0.label == "Staging box" })?.status == .changed, "third import diff: the edited host is the one flagged changed")
        check(thirdDiff.hostRows.first(where: { $0.label == "Prod bastion" })?.status == .unchanged, "third import diff: the untouched host is still unchanged")

        BackupImport.apply(thirdDiff, bundle: readBack, hostStore: hostStoreB, snippetStore: snippetStoreB)
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

        return ok
    }
}
