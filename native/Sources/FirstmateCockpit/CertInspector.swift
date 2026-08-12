// Manjesh Grand Line - native macOS app.
//
// Tools page (cockpit-tools-page-specialist, phase 3 of 3), certificate
// inspector. Per the task brief: use `Security.framework`'s real
// certificate-parsing APIs, not a hand-rolled ASN.1/DER parser -
// `SecCertificateCreateWithData` plus `SecCertificateCopyValues`'s
// property-list accessors (`kSecOIDX509V1SubjectName`/`...IssuerName`/
// `...ValidityNotBefore`/`...ValidityNotAfter`/`kSecOIDSubjectAltName`) -
// the same framework `KeychainKeyStore.swift` already uses elsewhere in
// this app, just a different API surface of it.
// `SecCertificateCopyValues` returns each X.509 field as a small dict with
// its own "value" already broken into human-readable parts (subject/issuer
// as an array of RDN component dicts, SAN as an array of {label, value}
// pairs) - far less code than decoding DER by hand, and correct by
// construction since the OS already validated the certificate parses.
//
// Verified against a real `openssl req -x509`-generated certificate and
// cross-checked field-by-field against `openssl x509 -noout -subject
// -issuer -dates -serial -ext subjectAltName` on that same cert - see
// `CertInspectorSelfTest.swift`, which does this as a permanent, live
// (not mocked) self-test, and this task's PR description for the exact
// transcript.

import Foundation
import Security

enum CertInspectorError: Error, Equatable {
    case notPEM
    case invalidBase64
    case invalidCertificate
    case couldNotReadValues
}

struct CertInfo {
    let subject: String
    let issuer: String
    let notBefore: Date
    let notAfter: Date
    let serialHex: String
    let sans: [String]

    var isExpired: Bool { notAfter < Date() }
    var isNotYetValid: Bool { notBefore > Date() }
}

enum CertInspector {

    /// Strips PEM armor and decodes the base64 body to DER bytes.
    private static func derData(fromPEM pem: String) throws -> Data {
        let lines = pem.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let body = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard !body.isEmpty else { throw CertInspectorError.notPEM }
        guard let data = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
            throw CertInspectorError.invalidBase64
        }
        return data
    }

    /// Flattens a `SecCertificateCopyValues` subject/issuer property (an
    /// array of RDN component dicts, each `{label, localizedLabel, value}`)
    /// into an `openssl -subject`-style "C=US, O=Org, CN=example.com" line -
    /// most-significant component first, matching how `openssl` and browsers
    /// conventionally print a DN, even though the property list itself
    /// carries no ordering guarantee beyond source encoding order.
    private static func flattenDistinguishedName(_ property: [String: Any]?) -> String {
        guard let values = property?[kSecPropertyKeyValue as String] as? [[String: Any]] else { return "" }
        let parts = values.compactMap { entry -> String? in
            guard let label = entry[kSecPropertyKeyLabel as String] as? String,
                  let value = entry[kSecPropertyKeyValue as String] else { return nil }
            return "\(shortName(for: label))=\(value)"
        }
        return parts.joined(separator: ", ")
    }

    /// `SecCertificateCopyValues`'s per-RDN "label" comes back as the raw
    /// dotted attribute OID (`2.5.4.3`, `2.5.4.6`, ...), not a human name -
    /// confirmed live via a standalone probe dumping the real dictionary
    /// before writing this, since Apple's own header docs don't spell out
    /// the label format. Map the common attribute OIDs to the short RDN
    /// names (`CN`, `O`, `C`) `openssl`'s `-subject`/`-issuer` output uses,
    /// so a captain comparing the two side by side sees matching text; a
    /// couple of already-human labels are mapped too in case a future OS
    /// version resolves them differently.
    private static func shortName(for label: String) -> String {
        switch label {
        case "2.5.4.3", "Common Name": return "CN"
        case "2.5.4.10", "Organization": return "O"
        case "2.5.4.11", "Organizational Unit": return "OU"
        case "2.5.4.6", "Country or Region", "Country": return "C"
        case "2.5.4.8", "State/Province": return "ST"
        case "2.5.4.7", "Locality": return "L"
        case "1.2.840.113549.1.9.1", "Email Address": return "emailAddress"
        default: return label
        }
    }

    static func parse(pem: String) throws -> CertInfo {
        let der = try derData(fromPEM: pem)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertInspectorError.invalidCertificate
        }

        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(cert, nil, &error) as? [String: [String: Any]] else {
            throw CertInspectorError.couldNotReadValues
        }

        let subject = flattenDistinguishedName(values[kSecOIDX509V1SubjectName as String])
        let issuer = flattenDistinguishedName(values[kSecOIDX509V1IssuerName as String])

        // `SecCertificateCopyValues` returns validity dates as a plain
        // `NSNumber` - a `CFAbsoluteTime` (seconds since the 2001-01-01
        // reference date), not an `NSDate` - confirmed live via a standalone
        // probe dumping the raw dictionary before writing this cast.
        guard let notBeforeSeconds = values[kSecOIDX509V1ValidityNotBefore as String]?[kSecPropertyKeyValue as String] as? NSNumber,
              let notAfterSeconds = values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber else {
            throw CertInspectorError.couldNotReadValues
        }
        let notBefore = Date(timeIntervalSinceReferenceDate: notBeforeSeconds.doubleValue)
        let notAfter = Date(timeIntervalSinceReferenceDate: notAfterSeconds.doubleValue)

        var serialHex = "unknown"
        if let serialData = SecCertificateCopySerialNumberData(cert, nil) as Data? {
            serialHex = serialData.map { String(format: "%02x", $0) }.joined(separator: ":")
        }

        // The SAN section's value array also carries a "Critical" flag entry
        // alongside the actual name entries (DNS Name/IP Address/...) -
        // confirmed live in the same probe - so it's excluded by label here
        // rather than assumed absent.
        var sans: [String] = []
        if let sanEntries = values[kSecOIDSubjectAltName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] {
            for entry in sanEntries {
                if let label = entry[kSecPropertyKeyLabel as String] as? String, label != "Critical",
                   let value = entry[kSecPropertyKeyValue as String] {
                    sans.append("\(label): \(value)")
                }
            }
        }

        return CertInfo(subject: subject, issuer: issuer, notBefore: notBefore, notAfter: notAfter, serialHex: serialHex, sans: sans)
    }
}
