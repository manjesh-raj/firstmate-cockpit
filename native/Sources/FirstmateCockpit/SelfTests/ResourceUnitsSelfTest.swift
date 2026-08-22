// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `ResourceUnits` - same convention
// as `DiffEngineSelfTest.swift`. Run with:
//
//   swift build && FM_RUN_RESOURCE_UNITS_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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

enum ResourceUnitsSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("cpuRoundTrip", test_cpuRoundTrip),
            ("exactGibiByteBoundary", test_exactGibiByteBoundary),
            ("decimalVsBinaryDoNotCollide", test_decimalVsBinaryDoNotCollide),
            ("plainNumberIsBytes", test_plainNumberIsBytes),
            ("fractionalGi", test_fractionalGi),
            ("unrecognizedSuffixErrors", test_unrecognizedSuffixErrors),
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
        print(failures == 0 ? "ResourceUnitsSelfTest: all \(cases.count) cases passed" : "ResourceUnitsSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    private static func test_cpuRoundTrip() -> String? {
        guard ResourceUnits.coresToMillicores(0.5) == 500 else { return "0.5 cores should be 500m" }
        guard ResourceUnits.millicoresToCores(250) == 0.25 else { return "250m should be 0.25 cores" }
        return nil
    }

    /// The exact binary/decimal boundary case the task's acceptance criteria
    /// calls out: 1 GiB is exactly 1,073,741,824 bytes (1024^3), which is
    /// exactly 1.073741824 decimal G (1e9) - not 1.0 G, which is what an
    /// off-by-1024-vs-1000 bug would produce.
    private static func test_exactGibiByteBoundary() -> String? {
        guard let bytes = try? ResourceUnits.parseMemoryBytes("1Gi") else { return "failed to parse 1Gi" }
        guard bytes == 1_073_741_824 else { return "expected 1Gi == 1073741824 bytes, got \(bytes)" }
        let conversion = ResourceUnits.convertMemory(bytes: bytes)
        guard conversion.gi == 1 else { return "expected gi == 1, got \(conversion.gi)" }
        guard conversion.ki == 1_048_576 else { return "expected ki == 1048576, got \(conversion.ki)" }
        guard abs(conversion.gDecimal - 1.073741824) < 1e-9 else { return "expected gDecimal ~= 1.073741824, got \(conversion.gDecimal)" }
        return nil
    }

    private static func test_decimalVsBinaryDoNotCollide() -> String? {
        guard let decimalG = try? ResourceUnits.parseMemoryBytes("1G") else { return "failed to parse 1G" }
        guard let binaryGi = try? ResourceUnits.parseMemoryBytes("1Gi") else { return "failed to parse 1Gi" }
        guard decimalG == 1_000_000_000 else { return "expected 1G == 1e9 bytes, got \(decimalG)" }
        guard binaryGi == 1_073_741_824 else { return "expected 1Gi == 1073741824 bytes, got \(binaryGi)" }
        guard decimalG != binaryGi else { return "1G and 1Gi must not be equal" }
        return nil
    }

    private static func test_plainNumberIsBytes() -> String? {
        guard let bytes = try? ResourceUnits.parseMemoryBytes("500") else { return "failed to parse 500" }
        guard bytes == 500 else { return "expected a bare number to be raw bytes, got \(bytes)" }
        return nil
    }

    private static func test_fractionalGi() -> String? {
        guard let bytes = try? ResourceUnits.parseMemoryBytes("1.5Gi") else { return "failed to parse 1.5Gi" }
        let expected = 1.5 * 1_073_741_824
        guard abs(bytes - expected) < 1 else { return "expected 1.5Gi ~= \(expected) bytes, got \(bytes)" }
        return nil
    }

    private static func test_unrecognizedSuffixErrors() -> String? {
        do {
            _ = try ResourceUnits.parseMemoryBytes("100Xy")
            return "expected an error for an unrecognized suffix"
        } catch ResourceUnitsError.notANumber {
            return nil // "100X" falls through to the bare-number path and fails there, which is an acceptable rejection
        } catch {
            return nil
        }
    }
}

#endif
