// Manjesh Grand Line - native macOS app.
//
// Regression coverage for `fm/cockpit-fix-host-decode-regression`: block-view
// Stage 0 (`fm/cockpit-block-view-stage0`) added `blockViewOptIn` to `Host`'s
// `CodingKeys`, and Swift's synthesized `Decodable` requires every listed key
// to be present regardless of the Swift property's own default value - the
// captain's real `hosts.json`, saved before that field existed, failed to
// decode entirely and `HostStore.load()` (correctly, by design) treated the
// failure as file corruption, silently emptying the Hosts page. `Host.swift`
// now has a custom `init(from:)` that falls back to each field's default via
// `decodeIfPresent(...) ?? default` - see that file's header. This is the
// same env-var-gated, permanent self-test convention as `BackupSelfTest.swift`
// et al. Run via `FM_RUN_HOST_STORE_TESTS=1 .build/debug/FirstmateCockpit`.

import Foundation

enum HostStoreSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            if condition {
                print("[host-store-test] PASS: \(label)")
            } else {
                print("[host-store-test] FAIL: \(label)")
                ok = false
            }
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoststore-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // MARK: Old-format JSON - no `blockViewOptIn` key at all, exactly the
        // shape every host saved before that field existed. This is the
        // literal shape of the captain's real, live incident.
        let oldFormatJSON = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "label": "DEV Bastion",
            "address": "10.0.0.4",
            "port": 2222,
            "username": "deploy",
            "iconSymbol": "server.rack",
            "accentHex": "6cd7e3",
            "tags": ["dev"],
            "agentForward": true,
            "portForwards": []
          },
          {
            "id": "22222222-2222-2222-2222-222222222222",
            "label": "Prod Bastion",
            "address": "10.0.0.5",
            "port": 22,
            "username": "ops",
            "iconSymbol": "cloud.fill",
            "accentHex": "ff8179",
            "tags": [],
            "agentForward": false,
            "portForwards": [],
            "jumpVia": "DEV Bastion"
          }
        ]
        """

        let oldFormatURL = tmp.appendingPathComponent("old-format-hosts.json")
        try? Data(oldFormatJSON.utf8).write(to: oldFormatURL)

        do {
            let decoded = try JSONDecoder().decode([Host].self, from: Data(oldFormatJSON.utf8))
            check(decoded.count == 2, "old-format JSON (missing blockViewOptIn) decodes both hosts")
            check(decoded.allSatisfy { $0.blockViewOptIn == false }, "blockViewOptIn defaults to false when the key is absent")
            check(decoded[0].label == "DEV Bastion" && decoded[0].port == 2222 && decoded[0].username == "deploy" && decoded[0].agentForward == true,
                  "other fields on the first host survive the decode untouched")
            check(decoded[1].jumpVia == "DEV Bastion", "optional fields (jumpVia) still decode correctly")
        } catch {
            check(false, "old-format JSON decodes at all (\(error.localizedDescription))")
        }

        // MARK: HostStore.load() end to end against that exact file - the
        // real path the captain hit, not just JSONDecoder in isolation.
        setenv("FM_HOSTS_FILE", oldFormatURL.path, 1)
        let store = HostStore()
        check(store.hosts.count == 2, "HostStore.load() reads both hosts from old-format JSON")
        check(store.loadFailureBackupPath == nil, "HostStore.load() does NOT treat old-format JSON as corrupt")
        let corruptBackups = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        check(!corruptBackups.contains(where: { $0.contains(".corrupt-") }), "no hosts.json.corrupt-* backup file was created for valid-but-old-shape JSON")

        // MARK: Full round trip - load old-format JSON, re-save, reload -
        // confirm every field on both hosts (not just blockViewOptIn) survives.
        store.update(store.hosts[0]) // triggers persist() with no other change
        let reloadEnv = tmp.appendingPathComponent("old-format-hosts.json")
        guard let reloadedData = try? Data(contentsOf: reloadEnv),
              let reloaded = try? JSONDecoder().decode([Host].self, from: reloadedData) else {
            check(false, "re-saved hosts.json still decodes")
            return ok
        }
        check(reloaded.count == 2, "round trip keeps both hosts")
        if let devReloaded = reloaded.first(where: { $0.label == "DEV Bastion" }) {
            check(devReloaded.address == "10.0.0.4", "round trip preserves address")
            check(devReloaded.port == 2222, "round trip preserves port")
            check(devReloaded.username == "deploy", "round trip preserves username")
            check(devReloaded.agentForward == true, "round trip preserves agentForward")
            check(devReloaded.tags == ["dev"], "round trip preserves tags")
            check(devReloaded.blockViewOptIn == false, "round trip preserves blockViewOptIn default")
        } else {
            check(false, "DEV Bastion survives the round trip")
        }
        if let prodReloaded = reloaded.first(where: { $0.label == "Prod Bastion" }) {
            check(prodReloaded.jumpVia == "DEV Bastion", "round trip preserves jumpVia")
        } else {
            check(false, "Prod Bastion survives the round trip")
        }

        // MARK: New-format JSON (blockViewOptIn present, true) still decodes -
        // the fix must not have broken the ordinary present-key case.
        let newFormatJSON = """
        [{"id":"33333333-3333-3333-3333-333333333333","label":"Block view host","address":"10.0.0.6","port":22,"username":"","iconSymbol":"server.rack","accentHex":"6cd7e3","tags":[],"agentForward":false,"portForwards":[],"blockViewOptIn":true}]
        """
        do {
            let decoded = try JSONDecoder().decode([Host].self, from: Data(newFormatJSON.utf8))
            check(decoded.count == 1 && decoded[0].blockViewOptIn == true, "new-format JSON (blockViewOptIn present) still decodes correctly")
        } catch {
            check(false, "new-format JSON decodes (\(error.localizedDescription))")
        }

        // MARK: Genuinely malformed JSON is still correctly treated as
        // corrupt - the distinction in HostStore.load() must not have been
        // lost while fixing the missing-optional-key case.
        let malformedURL = tmp.appendingPathComponent("malformed-hosts.json")
        try? Data("{ this is not valid JSON at all".utf8).write(to: malformedURL)
        setenv("FM_HOSTS_FILE", malformedURL.path, 1)
        let malformedStore = HostStore()
        check(malformedStore.hosts.isEmpty, "genuinely malformed JSON still yields an empty host list")
        check(malformedStore.loadFailureBackupPath != nil, "genuinely malformed JSON is still backed up as corrupt")

        unsetenv("FM_HOSTS_FILE")
        return ok
    }
}
