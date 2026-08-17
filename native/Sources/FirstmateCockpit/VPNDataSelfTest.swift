// Manjesh Grand Line - native macOS app.
//
// Permanent regression coverage for `VPNData.swift`
// (fm/grandline-vpn-toggle-integration), same `FM_RUN_..._TESTS=1` convention
// as every other `*SelfTest.swift` in this project. Run via
// `FM_RUN_VPN_DATA_TESTS=1 .build/debug/FirstmateCockpit`.
//
// This machine is the captain's real, currently-in-use development Mac - a
// real corporate VPN session may genuinely be in use concurrently with any
// automated run. Per this project's own herdr-lifecycle safety discipline
// (read-only checks are always fine; a real start/stop/connect/disconnect of
// a live session is not something to trigger from an automated test), this
// file NEVER constructs a `RealVPNCommandExecutor` or a
// `RealOpenVPNAccessibilityDriver`, and never touches
// `VPNStatusCenter.shared` (which is what wires the real ones together) at
// all. Every case here drives `BarracudaVPNController.parseStatus`/
// `OpenVPNConnectController.parseStatus` (pure functions) and `VPNCoordinator`
// (the mutual-exclusion sequencing logic) against fakes conforming to
// `VPNCommandExecutor`/`OpenVPNAccessibilityDriving`/`VPNControllable` -
// real command names (`scutil --nc status`) and real marker strings
// ("Securely Connected", "Are you sure") lifted straight from the plan's own
// live findings, never invented ones, but no real process is ever spawned
// and no real Accessibility API call is ever made.
//
// `RealOpenVPNAccessibilityDriver`'s actual AX traversal mechanics (finding a
// button by role+label, reading window text, dismissing a dialog) are NOT
// covered here - this sandbox has no interactive GUI/Accessibility session
// to drive even a disposable test app against (confirmed: `AXIsProcessTrusted()`
// has no meaningful effect without a real login session), and the task brief
// is explicit that any such proof, if attempted, must be against a
// throwaway test app the agent builds and controls itself, never the real
// OpenVPN Connect. That mechanical proof was not attempted in this session -
// see this task's PR description for the full honest breakdown of what was
// and wasn't verified live.

import Foundation

// MARK: - Fakes

private final class FakeVPNCommandExecutor: VPNCommandExecutor {
    /// Queued canned responses, keyed by the joined `args` string (e.g.
    /// "--nc status Barracuda VPN") - each call consumes one, falling back
    /// to the last queued response for that key once exhausted, so a test
    /// can seed "start succeeds" then "status now Connected" without needing
    /// an exact call count.
    var responses: [String: [VPNCommandResult]] = [:]
    private(set) var calls: [[String]] = []

    func run(_ executable: String, _ args: [String]) -> VPNCommandResult {
        calls.append(args)
        let key = args.joined(separator: " ")
        guard var queue = responses[key], !queue.isEmpty else {
            return responses[key]?.last ?? VPNCommandResult(status: 0, stdout: "Disconnected", stderr: "")
        }
        let next = queue.removeFirst()
        responses[key] = queue.isEmpty ? [next] : queue
        return next
    }
}

private final class FakeOpenVPNDriver: OpenVPNAccessibilityDriving {
    var running = true
    /// Queued window-text snapshots consumed in order by successive
    /// `readWindowTexts()` calls, sticking on the last one once exhausted -
    /// lets a test script "not connected" -> "connected" the way a real
    /// window would transition across a connect action's re-verify polls.
    var textSequence: [[String]] = [[]]
    var connectButtonPresent = true
    var disconnectButtonPresent = true
    var confirmDialogAppearsOnDisconnect = false
    private(set) var pressedTitles: [String] = []

    func isAppRunning() -> Bool { running }

    func readWindowTexts() -> [String] {
        guard !textSequence.isEmpty else { return [] }
        if textSequence.count > 1 { return textSequence.removeFirst() }
        return textSequence[0]
    }

    func pressButton(titleContains: String) -> Bool {
        pressedTitles.append(titleContains)
        let lower = titleContains.lowercased()
        if lower.contains("disconnect") {
            // The confirmation dialog's own "Disconnect" button is a second,
            // distinct press from the main window's - both share the same
            // title substring in real life, so the fake tracks press COUNT
            // for "disconnect" rather than treating every press identically.
            let disconnectPresses = pressedTitles.filter { $0.lowercased().contains("disconnect") }.count
            if disconnectPresses == 1 { return disconnectButtonPresent }
            // Second+ "Disconnect" press = the confirmation dialog's button.
            return confirmDialogAppearsOnDisconnect
        }
        if lower.contains("yes") { return confirmDialogAppearsOnDisconnect }
        if lower.contains("connect") { return connectButtonPresent }
        return false
    }
}

/// A directly-scriptable `VPNControllable`, used by the `VPNCoordinator`
/// sequencing tests below so each scenario can dictate exactly what
/// `currentStatus()`/`connect()`/`disconnect()` return without going through
/// either real controller's own parsing.
private final class FakeVPNControllable: VPNControllable {
    let kind: VPNKind
    var status: VPNConnectionStatus
    var connectOutcome: VPNActionOutcome = .succeeded
    var disconnectOutcome: VPNActionOutcome = .succeeded
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    init(kind: VPNKind, status: VPNConnectionStatus) {
        self.kind = kind
        self.status = status
    }

    func currentStatus() -> VPNConnectionStatus { status }

    func connect() -> VPNActionOutcome {
        connectCallCount += 1
        if case .succeeded = connectOutcome { status = .connected(profile: nil, durationText: nil) }
        return connectOutcome
    }

    func disconnect() -> VPNActionOutcome {
        disconnectCallCount += 1
        if case .succeeded = disconnectOutcome { status = .disconnected }
        return disconnectOutcome
    }
}

// MARK: - Self test

enum VPNDataSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            if condition {
                print("[vpn-data-test] PASS: \(label)")
            } else {
                print("[vpn-data-test] FAIL: \(label)")
                ok = false
            }
        }

        // MARK: Barracuda status parsing (real `scutil --nc status` shapes)

        check(
            BarracudaVPNController.parseStatus("Connected\n<dictionary> {\n  ...\n}") == .connected(profile: "Barracuda VPN", durationText: nil),
            "Barracuda: 'Connected' first line parses to .connected"
        )
        check(BarracudaVPNController.parseStatus("Disconnected\n") == .disconnected, "Barracuda: 'Disconnected' parses to .disconnected")
        check(BarracudaVPNController.parseStatus("Connecting\n") == .connecting, "Barracuda: 'Connecting' parses to .connecting")
        check(BarracudaVPNController.parseStatus("Disconnecting\n") == .disconnecting, "Barracuda: 'Disconnecting' parses to .disconnecting")
        check(BarracudaVPNController.parseStatus("") == .unknown, "Barracuda: empty output parses to .unknown")
        check(BarracudaVPNController.parseStatus("Invalid\n") == .unknown, "Barracuda: unrecognized first line parses to .unknown")

        // MARK: Barracuda controller against a fake executor

        do {
            let exec = FakeVPNCommandExecutor()
            exec.responses["--nc status Barracuda VPN"] = [VPNCommandResult(status: 0, stdout: "Connected", stderr: "")]
            let controller = BarracudaVPNController(executor: exec, scutilPath: "/usr/sbin/scutil")
            check(controller.currentStatus() == .connected(profile: "Barracuda VPN", durationText: nil), "Barracuda controller: status reflects fake executor's canned output")
            check(exec.calls.last == ["--nc", "status", "Barracuda VPN"], "Barracuda controller: issues the real 'scutil --nc status \"Barracuda VPN\"' argv shape")
        }

        do {
            let exec = FakeVPNCommandExecutor()
            exec.responses["--nc start Barracuda VPN"] = [VPNCommandResult(status: 0, stdout: "", stderr: "")]
            exec.responses["--nc status Barracuda VPN"] = [VPNCommandResult(status: 0, stdout: "Connected", stderr: "")]
            let controller = BarracudaVPNController(executor: exec, scutilPath: "/usr/sbin/scutil")
            let outcome = controller.connect()
            check(outcome == .succeeded, "Barracuda controller: connect() succeeds when start exits 0 and re-check confirms Connected")
        }

        do {
            let exec = FakeVPNCommandExecutor()
            exec.responses["--nc start Barracuda VPN"] = [VPNCommandResult(status: 1, stdout: "", stderr: "permission denied")]
            let controller = BarracudaVPNController(executor: exec, scutilPath: "/usr/sbin/scutil")
            guard case .failed(let reason) = controller.connect() else {
                check(false, "Barracuda controller: connect() reports .failed on a non-zero scutil exit, never .succeeded/.unknown")
                return false
            }
            check(reason.contains("permission denied"), "Barracuda controller: .failed reason carries the real scutil stderr")
        }

        do {
            let exec = FakeVPNCommandExecutor()
            exec.responses["--nc start Barracuda VPN"] = [VPNCommandResult(status: 0, stdout: "", stderr: "")]
            // Status never confirms Connected - stays stuck reporting
            // Disconnected across every re-check.
            exec.responses["--nc status Barracuda VPN"] = [VPNCommandResult(status: 0, stdout: "Disconnected", stderr: "")]
            let controller = BarracudaVPNController(executor: exec, scutilPath: "/usr/sbin/scutil")
            guard case .unknown = controller.connect() else {
                check(false, "Barracuda controller: connect() reports .unknown - never a false .succeeded - when the re-check never confirms Connected")
                return false
            }
            check(true, "Barracuda controller: connect() reports .unknown when the re-check never confirms Connected")
        }

        // MARK: OpenVPN status parsing (real window-text marker strings)

        check(
            OpenVPNConnectController.parseStatus(["Securely Connected!", "manjeshp@pramata.openvpn.com", "00:14:32", "Disconnect"])
                == .connected(profile: "manjeshp@pramata.openvpn.com", durationText: "00:14:32"),
            "OpenVPN: 'Securely Connected!' + profile + duration text parses to .connected with both fields"
        )
        check(OpenVPNConnectController.parseStatus(["Disconnected", "Connect"]) == .disconnected, "OpenVPN: no connected marker parses to .disconnected")
        check(OpenVPNConnectController.parseStatus(["Connecting..."]) == .connecting, "OpenVPN: 'Connecting...' parses to .connecting")
        check(OpenVPNConnectController.parseStatus(["Disconnecting..."]) == .disconnecting, "OpenVPN: 'Disconnecting...' parses to .disconnecting")
        check(OpenVPNConnectController.parseStatus([]) == .unknown, "OpenVPN: empty window-text list (couldn't read the window) parses to .unknown")
        check(OpenVPNConnectController.looksLikeDuration("00:14:32"), "OpenVPN: '00:14:32' is recognized as a duration readout")
        check(!OpenVPNConnectController.looksLikeDuration("manjeshp@pramata.openvpn.com"), "OpenVPN: a profile string is never mistaken for a duration readout")

        // MARK: OpenVPN controller - connect happy path

        do {
            let driver = FakeOpenVPNDriver()
            driver.textSequence = [["Disconnected", "Connect"], ["Securely Connected!", "00:00:05", "Disconnect"]]
            let controller = OpenVPNConnectController(driver: driver, ensureAccessibilityTrust: { true })
            check(controller.connect() == .succeeded, "OpenVPN controller: connect() succeeds when the Connect button is found and the re-check confirms Securely Connected")
            check(driver.pressedTitles == ["Connect"], "OpenVPN controller: connect() presses exactly the Connect button, nothing else")
        }

        // MARK: OpenVPN controller - Connect button missing (UI changed)

        do {
            let driver = FakeOpenVPNDriver()
            driver.connectButtonPresent = false
            let controller = OpenVPNConnectController(driver: driver, ensureAccessibilityTrust: { true })
            guard case .failed = controller.connect() else {
                check(false, "OpenVPN controller: connect() reports .failed when no Connect button can be found - never a silent no-op success")
                return false
            }
            check(true, "OpenVPN controller: connect() reports .failed when no Connect button can be found")
        }

        // MARK: OpenVPN controller - the "Disconnect VPN - Are you sure?" dialog hazard

        do {
            let driver = FakeOpenVPNDriver()
            driver.confirmDialogAppearsOnDisconnect = true
            // First read (right after the initial Disconnect press): the
            // confirmation dialog is up. Later reads (after dismissing it):
            // genuinely disconnected.
            driver.textSequence = [
                ["Disconnect VPN", "Are you sure you want to disconnect?", "Disconnect", "Cancel"],
                ["Disconnected", "Connect"],
            ]
            let controller = OpenVPNConnectController(driver: driver, ensureAccessibilityTrust: { true })
            check(controller.disconnect() == .succeeded, "OpenVPN controller: disconnect() detects and dismisses the confirmation dialog, then confirms Disconnected")
            check(driver.pressedTitles == ["Disconnect", "Disconnect"], "OpenVPN controller: disconnect() presses Disconnect twice - the main button, then the dialog's own confirm button")
        }

        do {
            // The dialog appears but nothing manages to dismiss it (neither
            // "Disconnect" nor "Yes" is found the second time) - must report
            // .unknown, never a false .succeeded.
            let driver = FakeOpenVPNDriver()
            driver.confirmDialogAppearsOnDisconnect = false
            driver.textSequence = [["Disconnect VPN", "Are you sure you want to disconnect?", "Cancel"]]
            let controller = OpenVPNConnectController(driver: driver, ensureAccessibilityTrust: { true })
            guard case .unknown = controller.disconnect() else {
                check(false, "OpenVPN controller: disconnect() reports .unknown when the confirmation dialog appears but can't be dismissed - never a false .succeeded")
                return false
            }
            check(true, "OpenVPN controller: disconnect() reports .unknown when the confirmation dialog can't be dismissed")
        }

        // MARK: VPNCoordinator - mutual exclusion sequencing

        do {
            // Turning Barracuda on while OpenVPN is already connected:
            // OpenVPN must be disconnected first, confirmed, THEN Barracuda
            // connects - and the other VPN is never touched when it wasn't
            // connected to begin with.
            let barracuda = FakeVPNControllable(kind: .barracuda, status: .disconnected)
            let openVPN = FakeVPNControllable(kind: .openVPN, status: .connected(profile: nil, durationText: nil))
            let coordinator = VPNCoordinator(barracuda: barracuda, openVPN: openVPN)
            let result = coordinator.toggle(.barracuda, requestOn: true)
            check(result == .connected(.barracuda), "Coordinator: toggling Barracuda on while OpenVPN is connected reports Barracuda connected")
            check(openVPN.disconnectCallCount == 1, "Coordinator: disconnects the other (OpenVPN) exactly once before connecting the requested VPN")
            check(barracuda.connectCallCount == 1, "Coordinator: connects the requested VPN (Barracuda) exactly once")
            check(openVPN.status == .disconnected, "Coordinator: the other VPN (OpenVPN) ends up disconnected")
        }

        do {
            // The reverse direction: OpenVPN on while Barracuda is connected.
            let barracuda = FakeVPNControllable(kind: .barracuda, status: .connected(profile: nil, durationText: nil))
            let openVPN = FakeVPNControllable(kind: .openVPN, status: .disconnected)
            let coordinator = VPNCoordinator(barracuda: barracuda, openVPN: openVPN)
            let result = coordinator.toggle(.openVPN, requestOn: true)
            check(result == .connected(.openVPN), "Coordinator: toggling OpenVPN on while Barracuda is connected reports OpenVPN connected")
            check(barracuda.disconnectCallCount == 1, "Coordinator: disconnects Barracuda first when turning OpenVPN on")
            check(openVPN.connectCallCount == 1, "Coordinator: connects OpenVPN exactly once")
        }

        do {
            // Neither VPN connected: turning one on never touches the other
            // at all.
            let barracuda = FakeVPNControllable(kind: .barracuda, status: .disconnected)
            let openVPN = FakeVPNControllable(kind: .openVPN, status: .disconnected)
            let coordinator = VPNCoordinator(barracuda: barracuda, openVPN: openVPN)
            _ = coordinator.toggle(.barracuda, requestOn: true)
            check(openVPN.disconnectCallCount == 0, "Coordinator: never disconnects the other VPN when it wasn't connected to begin with")
            check(openVPN.connectCallCount == 0, "Coordinator: never connects the other VPN as a side effect of toggling one on")
        }

        do {
            // The critical safety case: the automatic disconnect of the
            // other VPN fails outright - the coordinator must stop there and
            // never attempt to connect the requested VPN on top of an
            // uncertain first one.
            let barracuda = FakeVPNControllable(kind: .barracuda, status: .disconnected)
            let openVPN = FakeVPNControllable(kind: .openVPN, status: .connected(profile: nil, durationText: nil))
            openVPN.disconnectOutcome = .failed("simulated: OpenVPN UI didn't respond")
            let coordinator = VPNCoordinator(barracuda: barracuda, openVPN: openVPN)
            let result = coordinator.toggle(.barracuda, requestOn: true)
            guard case .failed(let kind, let reason) = result else {
                check(false, "Coordinator: reports .failed when the automatic disconnect of the other VPN fails outright")
                return false
            }
            check(kind == .barracuda, "Coordinator: the failure is reported against the VPN the captain actually requested")
            check(reason.contains("OpenVPN"), "Coordinator: the failure reason names which VPN's auto-disconnect failed")
            check(barracuda.connectCallCount == 0, "Coordinator: never attempts to connect the requested VPN when the other's auto-disconnect failed outright")
        }

        do {
            // The other VPN's disconnect can't be CONFIRMED (not a hard
            // failure, just an unconfirmed re-check) - same stop-here rule.
            let barracuda = FakeVPNControllable(kind: .barracuda, status: .disconnected)
            let openVPN = FakeVPNControllable(kind: .openVPN, status: .connected(profile: nil, durationText: nil))
            openVPN.disconnectOutcome = .unknown("simulated: re-check never confirmed Disconnected")
            let coordinator = VPNCoordinator(barracuda: barracuda, openVPN: openVPN)
            let result = coordinator.toggle(.barracuda, requestOn: true)
            guard case .unknown(let kind, _) = result else {
                check(false, "Coordinator: reports .unknown when the other VPN's auto-disconnect can't be confirmed")
                return false
            }
            check(kind == .barracuda, "Coordinator: the unknown result is reported against the requested VPN")
            check(barracuda.connectCallCount == 0, "Coordinator: never attempts to connect the requested VPN when the other's auto-disconnect couldn't be confirmed")
        }

        do {
            // Turning a VPN OFF is a direct disconnect of just that one - the
            // other is left completely untouched.
            let barracuda = FakeVPNControllable(kind: .barracuda, status: .connected(profile: nil, durationText: nil))
            let openVPN = FakeVPNControllable(kind: .openVPN, status: .connected(profile: nil, durationText: nil))
            let coordinator = VPNCoordinator(barracuda: barracuda, openVPN: openVPN)
            let result = coordinator.toggle(.barracuda, requestOn: false)
            check(result == .disconnected(.barracuda), "Coordinator: toggling a VPN off reports it disconnected")
            check(openVPN.disconnectCallCount == 0, "Coordinator: toggling one VPN off never touches the other")
            check(openVPN.connectCallCount == 0, "Coordinator: toggling one VPN off never connects the other")
        }

        do {
            // A direct connect failure (not the mutual-exclusion path) still
            // reports .failed, not a false .connected.
            let barracuda = FakeVPNControllable(kind: .barracuda, status: .disconnected)
            barracuda.connectOutcome = .failed("simulated: scutil start failed")
            let openVPN = FakeVPNControllable(kind: .openVPN, status: .disconnected)
            let coordinator = VPNCoordinator(barracuda: barracuda, openVPN: openVPN)
            guard case .failed(let kind, _) = coordinator.toggle(.barracuda, requestOn: true) else {
                check(false, "Coordinator: a direct connect failure reports .failed, never .connected")
                return false
            }
            check(kind == .barracuda, "Coordinator: a direct connect failure names the requested VPN")
        }

        return ok
    }
}
