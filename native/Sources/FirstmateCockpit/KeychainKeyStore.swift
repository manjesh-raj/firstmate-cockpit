// Firstmate Cockpit - native macOS app.
//
// Secret storage for SSH key material. Phase 2 of the connection-manager work
// (design report `data/cockpit-ssh-manager-research/report.md`, Section C3 -
// "the part not to hand-wave"). Everything here is `Security.framework`
// (`SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`); there is no
// hand-rolled crypto and no plaintext file - the report is explicit that a
// plaintext-creds pattern (`backend/auth.py`) is "not acceptable" for private
// keys.
//
// Two Keychain items per saved key, both generic passwords scoped to this
// app's service name:
//   "<id>.key"  - the private key blob, exactly as generated or imported
//                 (still passphrase-encrypted if it was).
//   "<id>.pass" - the passphrase, only written when one was given.
// Both are protected by a `SecAccessControl` that requires the device to be
// unlocked *and* a fresh biometric (or, where Touch ID isn't enrolled, device
// passcode) challenge to succeed - mirroring the "Secure Enclave model" the
// task calls for. There is no code path that reads either item without that
// challenge; the OS enforces it, this file does not.
//
// Known limitation, stated plainly rather than papered over: this target is
// unsigned (Command Line Tools only, `swift build` / `swift run`, no
// Developer ID). An unsigned binary has no stable code-signing identity, so
// macOS may treat each rebuild as a "different app" for Keychain purposes -
// in practice this can mean an extra "<app> wants to use your confidential
// information" prompt after a rebuild, or in rarer cases a rebuilt binary
// being unable to re-read an item an earlier build wrote. This is inherent to
// the CLT-only dev workflow, not a flaw in the storage design, and resolves
// once the app is signed with a stable identity (Phase 4 packaging).

import Foundation
import Security
import LocalAuthentication

enum KeychainError: LocalizedError {
    case osStatus(OSStatus)
    case notFound
    case accessControlUnavailable

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        case .notFound:
            return "No secret is stored in the Keychain for this key."
        case .accessControlUnavailable:
            return "Could not create a biometric-protected Keychain entry."
        }
    }
}

enum KeychainKeyStore {
    private static let service = "com.firstmate.cockpit.sshkey"

    /// Whether Touch ID (or another biometric) is enrolled and usable right
    /// now. When it isn't, the fallback below is the device passcode - still
    /// a real authentication challenge, never an open door.
    static var biometryAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: Private key

    static func savePrivateKey(id: UUID, data: Data) throws {
        try save(account: account(id, "key"), data: data)
    }

    /// Read the private key blob. `context` drives the Touch ID / passcode
    /// prompt (its `localizedReason` is what the system sheet shows); pass the
    /// same context to `loadPassphrase` for the same key so the captain is
    /// only challenged once per connect, not twice.
    static func loadPrivateKey(id: UUID, context: LAContext) throws -> Data {
        try load(account: account(id, "key"), context: context)
    }

    // MARK: Passphrase

    static func savePassphrase(id: UUID, passphrase: String) throws {
        try save(account: account(id, "pass"), data: Data(passphrase.utf8))
    }

    /// Returns `nil` (rather than throwing) when no passphrase was ever saved
    /// for this key - that is the common case, not an error.
    static func loadPassphrase(id: UUID, context: LAContext) throws -> String? {
        do {
            let data = try load(account: account(id, "pass"), context: context)
            return String(data: data, encoding: .utf8)
        } catch KeychainError.notFound {
            return nil
        }
    }

    // MARK: Delete

    /// Remove both items for a key. Safe to call even if one or both were
    /// never written (`SecItemDelete` on a missing item is a no-op here).
    static func delete(id: UUID) {
        delete(account: account(id, "key"))
        delete(account: account(id, "pass"))
    }

    // MARK: Implementation

    private static func account(_ id: UUID, _ suffix: String) -> String {
        "\(id.uuidString).\(suffix)"
    }

    /// The access-control every item is written with: unlocked-device-only,
    /// this-device-only (never iCloud Keychain sync - private keys should not
    /// leave this Mac), and biometry if enrolled, else the device passcode.
    private static func accessControl() throws -> SecAccessControl {
        let flags: SecAccessControlCreateFlags = biometryAvailable ? .biometryCurrentSet : .userPresence
        guard let ac = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            nil
        ) else {
            throw KeychainError.accessControlUnavailable
        }
        return ac
    }

    private static func save(account: String, data: Data) throws {
        // Overwrite semantics: SecItemAdd fails on a duplicate primary key, and
        // SecItemUpdate cannot change access control on an existing item, so a
        // resave always deletes first.
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: try accessControl(),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    private static func load(account: String, context: LAContext) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.osStatus(status)
        }
        return data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
