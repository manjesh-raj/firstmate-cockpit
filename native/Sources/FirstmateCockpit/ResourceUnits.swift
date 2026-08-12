// Manjesh Grand Line - native macOS app.
//
// Tools page (cockpit-tools-page-specialist, phase 3 of 3), Kubernetes
// resource-unit converter: CPU millicores <-> cores, and a memory quantity
// (Kubernetes `resource.Quantity` syntax, e.g. `256Mi`, `1.5Gi`, `500M`)
// converted to every common unit at once. Pure Foundation logic, no AppKit -
// see `ResourceUnitsSelfTest.swift`.

import Foundation

enum ResourceUnitsError: Error, Equatable {
    case empty
    case unrecognizedSuffix(String)
    case notANumber(String)
}

enum ResourceUnits {

    // MARK: CPU

    static func millicoresToCores(_ millicores: Double) -> Double { millicores / 1000 }
    static func coresToMillicores(_ cores: Double) -> Double { cores * 1000 }

    // MARK: Memory

    /// Kubernetes `resource.Quantity` binary/decimal suffixes. Lowercase `k`
    /// is the real spec's decimal-kilo suffix; uppercase `K` is accepted too
    /// as a common, harmless typo (Kubernetes itself rejects it) rather than
    /// erroring on input every other converter of this kind tolerates.
    private static let suffixMultipliers: [(String, Double)] = [
        ("Ei", pow(1024, 6)), ("Pi", pow(1024, 5)), ("Ti", pow(1024, 4)),
        ("Gi", pow(1024, 3)), ("Mi", pow(1024, 2)), ("Ki", 1024),
        ("E", 1e18), ("P", 1e15), ("T", 1e12), ("G", 1e9), ("M", 1e6), ("k", 1e3), ("K", 1e3),
    ]

    /// Parses a Kubernetes-style quantity string into an exact byte count.
    static func parseMemoryBytes(_ raw: String) throws -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ResourceUnitsError.empty }

        for (suffix, multiplier) in suffixMultipliers {
            if trimmed.hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(suffix.count))
                guard let value = Double(numberPart) else { throw ResourceUnitsError.notANumber(numberPart) }
                return value * multiplier
            }
        }
        guard let value = Double(trimmed) else { throw ResourceUnitsError.notANumber(trimmed) }
        return value
    }

    struct MemoryConversion {
        let bytes: Double
        let ki: Double
        let mi: Double
        let gi: Double
        let kDecimal: Double
        let mDecimal: Double
        let gDecimal: Double
    }

    static func convertMemory(bytes: Double) -> MemoryConversion {
        MemoryConversion(
            bytes: bytes,
            ki: bytes / 1024,
            mi: bytes / pow(1024, 2),
            gi: bytes / pow(1024, 3),
            kDecimal: bytes / 1e3,
            mDecimal: bytes / 1e6,
            gDecimal: bytes / 1e9
        )
    }

    /// Trims trailing zeros without switching to scientific notation for
    /// large/small magnitudes - `String(format:)` with a fixed precision,
    /// then a plain-string zero/decimal-point trim.
    static func formatNumber(_ value: Double, decimals: Int = 6) -> String {
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
