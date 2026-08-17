// Manjesh Grand Line - native macOS app.
//
// Data side of the VPN rail toggle + Tools "VPN" panel
// (fm/grandline-vpn-toggle-integration), built from a captain+firstmate
// Lavish plan that checked both VPNs live before proposing anything (see the
// task's own PR description for the plan doc, which is not committed to this
// repo - a planning artifact only):
//
//  - Barracuda VPN registers a real macOS Network Extension (confirmed live:
//    `scutil --nc list` / `networksetup -listallnetworkservices` both show
//    it as a first-class system VPN service named "Barracuda VPN") - so it
//    is controlled with one system call each way, exactly like flipping
//    Wi-Fi off: `scutil --nc start|stop|status "Barracuda VPN"`.
//  - OpenVPN Connect has genuinely no CLI/API/AppleScript/URL-scheme hook at
//    all (confirmed live: no `scutil --nc` entry, no `sdef`, no bundled CLI,
//    no system extension) - it's a legacy privileged-helper architecture
//    (`ovpnagent`/`ovpnhelper`) the GUI talks to over its own private
//    channel. Switching to a different OpenVPN client (e.g. `openvpn3`,
//    which *would* have a real CLI) was explicitly ruled out by the captain:
//    OpenVPN Connect is company-mandated, whatever IT hands out is what has
//    to be used. So OpenVPN control here is real UI automation of the
//    existing GUI via the Accessibility API (System Events-style scripting,
//    done in-process via `ApplicationServices` rather than shelling out to
//    `osascript`/System Events) - built defensively per the plan's explicit
//    checklist: find the Connect/Disconnect button by role+label (never
//    fixed coordinates), detect and dismiss the "Disconnect VPN - Are you
//    sure?" confirmation dialog OpenVPN Connect can pop before it actually
//    disconnects, and re-verify every toggle against the window's own real
//    status text rather than trusting the click - reporting "unknown /
//    couldn't confirm" rather than a false "Connected"/"Disconnected" if
//    that re-check can't settle one way or the other.
//
// Every piece that actually shells out or drives Accessibility sits behind
// an injectable seam (`VPNCommandExecutor`, `OpenVPNAccessibilityDriving`) so
// `VPNDataSelfTest.swift` can exercise the mutual-exclusion sequencing and
// status-parsing logic against fakes, never a real `scutil` call or a real
// OpenVPN Connect window - see this task's PR description for exactly what
// was (and wasn't) verified live, and why: this machine is the captain's
// real, currently-in-use development Mac, and a real connect/disconnect
// could drop a VPN session genuinely in use for real work happening
// concurrently with this task.
//
// `RealOpenVPNAccessibilityDriver` below was written to the plan's own
// checklist but was never run against a real OpenVPN Connect window in this
// task's own sandbox (no interactive GUI/Accessibility session was available
// here - see `VPNDataSelfTest.swift`'s header for what that means for this
// file's test coverage). The captain's own hands-on confirmation against the
// real app is still the last mile for this half of the feature.

import AppKit
import ApplicationServices

// MARK: - Models

enum VPNKind: Equatable, CaseIterable {
    case barracuda
    case openVPN

    var displayName: String {
        switch self {
        case .barracuda: return "Barracuda VPN"
        case .openVPN: return "OpenVPN"
        }
    }
}

/// A VPN's live connection state. `.unknown` is a real, first-class outcome
/// - not an error case bolted on afterward - since the plan's explicit
/// requirement is that a toggle whose result can't be confirmed must show
/// "unknown / couldn't confirm," never a guessed/false state.
enum VPNConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected(profile: String?, durationText: String?)
    case disconnecting
    case unknown

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// The outcome of one connect/disconnect action, before the coordinator
/// turns it into a `VPNToggleResult` for the kind that was actually
/// requested (see `VPNCoordinator.result(for:outcome:intendedOn:)`).
enum VPNActionOutcome: Equatable {
    case succeeded
    case failed(String)
    /// The action was issued (a real command ran, or a real button was
    /// clicked) but the follow-up status re-check couldn't confirm the new
    /// state within the retry budget - never coerced into `.succeeded`.
    case unknown(String)
}

/// What `VPNCoordinator.toggle` reports back to a caller (the rail toggle,
/// the Tools panel) - one shared decision path for both VPNs and both
/// directions (on/off), per the plan's explicit "one coordinator, not
/// duplicated per VPN" instruction.
enum VPNToggleResult: Equatable {
    case connected(VPNKind)
    case disconnected(VPNKind)
    case failed(VPNKind, reason: String)
    case unknown(VPNKind, reason: String)
}

// MARK: - Command execution seam (Barracuda)

struct VPNCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Injectable seam over `Process` - mirrors the shape of every other
/// `*Data.swift` file's private `run()` helper (see `VaultData.swift`), but
/// pulled out to a real protocol here specifically so
/// `VPNDataSelfTest.swift` can swap in a fake that returns canned `scutil`
/// output/exit codes without ever spawning a real process.
protocol VPNCommandExecutor {
    func run(_ executable: String, _ args: [String]) -> VPNCommandResult
}

struct RealVPNCommandExecutor: VPNCommandExecutor {
    func run(_ executable: String, _ args: [String]) -> VPNCommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.environment = childEnvironmentDict()
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return VPNCommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return VPNCommandResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

// MARK: - Accessibility automation seam (OpenVPN)

/// The one seam between OpenVPN's real UI-automation mechanics and this
/// file's decision logic - `VPNDataSelfTest.swift` drives `OpenVPNConnectController`
/// against a fake conforming to this, never `RealOpenVPNAccessibilityDriver`.
protocol OpenVPNAccessibilityDriving {
    /// Whether the OpenVPN Connect process is currently running at all.
    func isAppRunning() -> Bool

    /// Every visible string in the app's window(s) right now - title bar,
    /// status label, connected-duration readout, button titles, and any
    /// modal dialog's own text - flattened into one list, deliberately
    /// unstructured so the exact same parsing (`OpenVPNConnectController.parseStatus`)
    /// runs whether the strings came from a real AX traversal or a fake.
    func readWindowTexts() -> [String]

    /// Finds a button (real AX role `AXButton`) whose title contains
    /// `titleContains` (case-insensitive) anywhere in the app's window(s) -
    /// including a modal confirmation sheet on top of the main window, so
    /// the "Disconnect VPN - Are you sure?" dialog's own Disconnect/Cancel
    /// buttons are reachable through the same call - and presses it. Returns
    /// whether a matching, pressable button was actually found.
    @discardableResult
    func pressButton(titleContains: String) -> Bool
}

/// Real implementation - written to the plan's own checklist (find by
/// role+label, never coordinates; handle the confirmation dialog; nothing
/// here assumes success) but never run against a real OpenVPN Connect
/// install in this task's own sandbox. See this file's header and
/// `VPNDataSelfTest.swift`'s for exactly what that means for test coverage.
final class RealOpenVPNAccessibilityDriver: OpenVPNAccessibilityDriving {
    /// Matched by the app's localized display name rather than a hardcoded
    /// bundle identifier - this driver was never run against a real install
    /// here, so a guessed bundle id could easily be wrong in a way that's
    /// silently never true, whereas a display-name match is at least
    /// visibly correct against Applications/System Settings either way.
    static let appDisplayName = "OpenVPN Connect"

    /// Bounds on the AX tree walk - a real app's view hierarchy is not
    /// unbounded, and this keeps a pathological window from turning a status
    /// read into an expensive/slow traversal.
    private static let maxDepth = 8
    private static let maxChildrenPerElement = 80

    func isAppRunning() -> Bool {
        runningApp() != nil
    }

    private func runningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == Self.appDisplayName }
    }

    private func appElement() -> AXUIElement? {
        guard let app = runningApp() else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    func readWindowTexts() -> [String] {
        guard let appEl = appElement() else { return [] }
        var texts: [String] = []
        for window in windows(of: appEl) {
            collectTexts(from: window, depth: 0, into: &texts)
        }
        return texts
    }

    @discardableResult
    func pressButton(titleContains: String) -> Bool {
        guard let appEl = appElement() else { return false }
        for window in windows(of: appEl) {
            if let button = findButton(in: window, titleContains: titleContains, depth: 0) {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    private func windows(of appEl: AXUIElement) -> [AXUIElement] {
        arrayAttribute(appEl, kAXWindowsAttribute as String)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        arrayAttribute(element, kAXChildrenAttribute as String)
    }

    private func arrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func collectTexts(from element: AXUIElement, depth: Int, into texts: inout [String]) {
        guard depth < Self.maxDepth else { return }
        if let title = stringAttribute(element, kAXTitleAttribute as String), !title.isEmpty {
            texts.append(title)
        }
        if let value = stringAttribute(element, kAXValueAttribute as String), !value.isEmpty {
            texts.append(value)
        }
        if let desc = stringAttribute(element, kAXDescriptionAttribute as String), !desc.isEmpty {
            texts.append(desc)
        }
        for child in children(of: element).prefix(Self.maxChildrenPerElement) {
            collectTexts(from: child, depth: depth + 1, into: &texts)
        }
    }

    private func findButton(in element: AXUIElement, titleContains: String, depth: Int) -> AXUIElement? {
        guard depth < Self.maxDepth else { return nil }
        if stringAttribute(element, kAXRoleAttribute as String) == (kAXButtonRole as String),
           let title = stringAttribute(element, kAXTitleAttribute as String),
           title.localizedCaseInsensitiveContains(titleContains) {
            return element
        }
        for child in children(of: element).prefix(Self.maxChildrenPerElement) {
            if let found = findButton(in: child, titleContains: titleContains, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}

// MARK: - VPNControllable (what the coordinator operates over)

/// Both VPNs conform to this so `VPNCoordinator` can sequence either one
/// without knowing which underlying mechanism (a `scutil` call, or AX
/// automation) is behind it - the "small mutual-exclusion coordinator sits
/// in front of both" piece from the plan.
protocol VPNControllable: AnyObject {
    var kind: VPNKind { get }
    func currentStatus() -> VPNConnectionStatus
    func connect() -> VPNActionOutcome
    func disconnect() -> VPNActionOutcome
}

/// Shared "click/command, then re-verify against the real status rather than
/// trusting the action" retry loop - both controllers use the identical
/// shape, just over a different underlying status read.
enum VPNReverify {
    static func poll(
        attempts: Int = 6,
        delay: TimeInterval = 0.4,
        expectConnected: Bool,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        status: () -> VPNConnectionStatus
    ) -> VPNActionOutcome {
        for _ in 0..<attempts {
            sleep(delay)
            switch (expectConnected, status()) {
            case (true, .connected): return .succeeded
            case (false, .disconnected): return .succeeded
            default: continue
            }
        }
        return .unknown("Couldn't confirm the new state after \(attempts) checks")
    }
}

// MARK: - Barracuda (scutil-backed)

final class BarracudaVPNController: VPNControllable {
    let kind: VPNKind = .barracuda

    /// Confirmed live via `scutil --nc list` - the exact service name macOS
    /// registers this Network Extension under. `fm/grandline-hosts-vpn-flyout-redesign`
    /// confirmed live (read-only, no VPN connected) that only ONE Barracuda
    /// profile is currently registered as a system VPN service under this
    /// name on the captain's machine (`pramata-prod`) - a second profile the
    /// captain uses inside the Barracuda app itself is not reachable via
    /// `scutil --nc` unless it's also registered that way. Multi-profile
    /// support is out of scope here; this controller can only ever see and
    /// drive whatever profile macOS itself has registered under
    /// `serviceName` - documented in the Tools "VPN" panel's own copy
    /// (`ToolInstance.buildVpnPanel`) so it doesn't silently imply it
    /// controls "Barracuda" generically.
    static let serviceName = "Barracuda VPN"

    private let executor: VPNCommandExecutor
    private let scutilPath: String

    init(executor: VPNCommandExecutor = RealVPNCommandExecutor(), scutilPath: String = "/usr/sbin/scutil") {
        self.executor = executor
        self.scutilPath = scutilPath
    }

    func currentStatus() -> VPNConnectionStatus {
        let result = executor.run(scutilPath, ["--nc", "status", Self.serviceName])
        return Self.parseStatus(result.stdout)
    }

    /// `scutil --nc status <service>` prints one of `Connected`/`Connecting`/
    /// `Disconnecting`/`Disconnected`/`Invalid`/`Reasserting` as its first
    /// line, with an extended status dictionary on the lines after - only
    /// the first line is a stable, documented contract, so that's all this
    /// parses. Not `private` - exercised directly by `VPNDataSelfTest`.
    static func parseStatus(_ output: String) -> VPNConnectionStatus {
        guard let firstLine = output.split(separator: "\n").first else { return .unknown }
        switch firstLine.trimmingCharacters(in: .whitespaces) {
        case "Connected": return .connected(profile: serviceName, durationText: nil)
        case "Connecting": return .connecting
        case "Disconnecting": return .disconnecting
        case "Disconnected": return .disconnected
        default: return .unknown
        }
    }

    func connect() -> VPNActionOutcome {
        let result = executor.run(scutilPath, ["--nc", "start", Self.serviceName])
        guard result.status == 0 else {
            return .failed("scutil --nc start \"\(Self.serviceName)\" failed: \(result.stderr)")
        }
        return VPNReverify.poll(expectConnected: true) { currentStatus() }
    }

    func disconnect() -> VPNActionOutcome {
        let result = executor.run(scutilPath, ["--nc", "stop", Self.serviceName])
        guard result.status == 0 else {
            return .failed("scutil --nc stop \"\(Self.serviceName)\" failed: \(result.stderr)")
        }
        return VPNReverify.poll(expectConnected: false) { currentStatus() }
    }
}

// MARK: - OpenVPN Connect (Accessibility-automation-backed)

enum OpenVPNStatusMarkers {
    /// Confirmed live (captain screenshot) - OpenVPN Connect's own connected
    /// banner text.
    static let connectedMarker = "Securely Connected"
    /// Confirmed live (captain screenshot) - the confirmation dialog
    /// OpenVPN Connect can pop before actually disconnecting.
    static let confirmDialogQuestionMarker = "Are you sure"
}

final class OpenVPNConnectController: VPNControllable {
    let kind: VPNKind = .openVPN

    private let driver: OpenVPNAccessibilityDriving

    /// Injectable seam over the Accessibility trust check/request - defaults
    /// to the real `AXIsProcessTrusted`/`AXIsProcessTrustedWithOptions` pair
    /// (`requestRealAccessibilityTrust` below), the exact same system
    /// permission `DictationPermissions.requestAccessibility()` already
    /// uses for Dictation's paste-anywhere feature, per the plan's explicit
    /// note that this is a second feature reusing an existing grant, not a
    /// new kind of permission. Overridable so `VPNDataSelfTest.swift` can
    /// exercise `connect()`/`disconnect()` without ever calling the real AX
    /// API (which can surface a real system permission prompt) from an
    /// automated test run.
    private let ensureAccessibilityTrust: () -> Bool

    init(driver: OpenVPNAccessibilityDriving, ensureAccessibilityTrust: @escaping () -> Bool = OpenVPNConnectController.requestRealAccessibilityTrust) {
        self.driver = driver
        self.ensureAccessibilityTrust = ensureAccessibilityTrust
    }

    /// Shows the real system Accessibility permission prompt if not already
    /// granted - a no-op (returns `true` immediately, no dialog) once
    /// already trusted, matching `DictationPermissions.requestAccessibility()`'s
    /// own "safe to call every time" convention.
    static func requestRealAccessibilityTrust() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func currentStatus() -> VPNConnectionStatus {
        guard driver.isAppRunning() else { return .disconnected }
        return Self.parseStatus(driver.readWindowTexts())
    }

    /// Not `private` - exercised directly by `VPNDataSelfTest` against
    /// literal window-text shapes the plan's own screenshots/findings
    /// describe (never invented marker strings).
    static func parseStatus(_ texts: [String]) -> VPNConnectionStatus {
        if texts.isEmpty { return .unknown }
        if texts.contains(where: { $0.localizedCaseInsensitiveContains(OpenVPNStatusMarkers.connectedMarker) }) {
            let profile = texts.first { $0.contains("@") }
            let duration = texts.first { looksLikeDuration($0) }
            return .connected(profile: profile, durationText: duration)
        }
        // "disconnecting" must be checked before "connecting" - the former
        // is a substring of the latter ("dis-CONNECTING"), so checking
        // "connecting" first would misclassify a genuine "Disconnecting..."
        // readout as still connecting.
        if texts.contains(where: { $0.localizedCaseInsensitiveContains("disconnecting") }) { return .disconnecting }
        if texts.contains(where: { $0.localizedCaseInsensitiveContains("connecting") }) { return .connecting }
        return .disconnected
    }

    /// A bare `HH:MM:SS` connected-duration readout, e.g. "00:14:32".
    static func looksLikeDuration(_ s: String) -> Bool {
        let parts = s.split(separator: ":")
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { $0.count <= 2 && Int($0) != nil }
    }

    func connect() -> VPNActionOutcome {
        guard ensureAccessibilityTrust() else {
            return .failed("Accessibility permission is required to control OpenVPN Connect - grant it in System Settings \u{2192} Privacy & Security \u{2192} Accessibility, then try again.")
        }
        guard driver.isAppRunning() else { return .failed("OpenVPN Connect is not running") }
        guard driver.pressButton(titleContains: "Connect") else {
            return .failed("Couldn't find a Connect button in OpenVPN Connect's window")
        }
        return VPNReverify.poll(expectConnected: true) { currentStatus() }
    }

    /// Confirmation-dialog-aware: after pressing Disconnect, OpenVPN Connect
    /// can pop "Disconnect VPN - Are you sure?" before it actually
    /// disconnects (the plan's own screenshotted hazard) - this checks for
    /// that dialog's own marker text and, if present, presses its
    /// Disconnect/Yes button rather than assuming one click was enough.
    func disconnect() -> VPNActionOutcome {
        guard ensureAccessibilityTrust() else {
            return .failed("Accessibility permission is required to control OpenVPN Connect - grant it in System Settings \u{2192} Privacy & Security \u{2192} Accessibility, then try again.")
        }
        guard driver.isAppRunning() else { return .succeeded }
        guard driver.pressButton(titleContains: "Disconnect") else {
            return .failed("Couldn't find a Disconnect button in OpenVPN Connect's window")
        }
        let texts = driver.readWindowTexts()
        if texts.contains(where: { $0.localizedCaseInsensitiveContains(OpenVPNStatusMarkers.confirmDialogQuestionMarker) }) {
            guard driver.pressButton(titleContains: "Disconnect") || driver.pressButton(titleContains: "Yes") else {
                return .unknown("A confirmation dialog appeared but couldn't be dismissed")
            }
        }
        return VPNReverify.poll(expectConnected: false) { currentStatus() }
    }
}

// MARK: - Mutual exclusion coordinator

/// The one shared "disconnect the other, confirm, then connect this one"
/// code path both VPNs' toggles go through - per the plan's explicit
/// decision that only one of the two may be connected at a time, and that a
/// failed/unconfirmed auto-disconnect must stop the whole request rather
/// than risk starting the second VPN on top of an uncertain first one.
final class VPNCoordinator {
    private let barracuda: VPNControllable
    private let openVPN: VPNControllable

    init(barracuda: VPNControllable, openVPN: VPNControllable) {
        self.barracuda = barracuda
        self.openVPN = openVPN
    }

    private func controller(for kind: VPNKind) -> VPNControllable {
        kind == .barracuda ? barracuda : openVPN
    }

    private func other(of kind: VPNKind) -> VPNControllable {
        kind == .barracuda ? openVPN : barracuda
    }

    /// Turns `kind` on or off.
    ///
    /// Turning it OFF is a direct disconnect of just that VPN - the other
    /// VPN (if any) is left exactly as it was.
    ///
    /// Turning it ON: if the other VPN is currently connected, it is
    /// disconnected first and reconfirmed via its own real status re-check
    /// before `kind` is ever connected. If that disconnect fails outright or
    /// can't be confirmed, this returns immediately without attempting the
    /// requested connect - never proceeding to connect the second VPN on top
    /// of an uncertain first one.
    func toggle(_ kind: VPNKind, requestOn: Bool) -> VPNToggleResult {
        let target = controller(for: kind)

        guard requestOn else {
            return Self.result(for: kind, outcome: target.disconnect(), intendedOn: false)
        }

        let otherController = other(of: kind)
        if case .connected = otherController.currentStatus() {
            switch otherController.disconnect() {
            case .succeeded:
                break
            case .failed(let reason):
                return .failed(kind, reason: "couldn't disconnect \(otherController.kind.displayName) first: \(reason)")
            case .unknown(let reason):
                return .unknown(kind, reason: "couldn't confirm \(otherController.kind.displayName) disconnected first: \(reason)")
            }
        }

        return Self.result(for: kind, outcome: target.connect(), intendedOn: true)
    }

    private static func result(for kind: VPNKind, outcome: VPNActionOutcome, intendedOn: Bool) -> VPNToggleResult {
        switch outcome {
        case .succeeded: return intendedOn ? .connected(kind) : .disconnected(kind)
        case .failed(let reason): return .failed(kind, reason: reason)
        case .unknown(let reason): return .unknown(kind, reason: reason)
        }
    }
}

// MARK: - Production singleton (live status + UI wiring)

/// The app-lifetime singleton both the rail's VPN section and the Tools
/// "VPN" panel observe - one shared source of truth so the rail toggle and
/// the Tools panel never disagree about which VPN is on. Mirrors
/// `ThemeManager`/`FontSizeManager`'s observe/notify shape (a token-keyed
/// observer dictionary, `observe` calling the handler immediately with the
/// current snapshot).
///
/// Read-only status polling (`refresh()`, a plain `scutil --nc status`/AX
/// window-text read) is safe to run continuously in the background - it
/// never starts or stops anything. `toggle(_:requestOn:)` is the only path
/// that ever issues a real connect/disconnect, and it is only ever called
/// from a real user click on the rail toggle or the Tools panel's own
/// button - never from a timer, and never from this app's self-tests (which
/// exercise `VPNCoordinator`/`BarracudaVPNController.parseStatus`/
/// `OpenVPNConnectController.parseStatus` directly against fakes instead,
/// see `VPNDataSelfTest.swift`).
final class VPNStatusCenter {
    static let shared = VPNStatusCenter()

    struct Snapshot {
        var barracuda: VPNConnectionStatus = .unknown
        var openVPN: VPNConnectionStatus = .unknown
    }

    private(set) var snapshot = Snapshot()
    private var observers: [UUID: (Snapshot) -> Void] = [:]

    /// `fm/grandline-hosts-vpn-flyout-redesign`, Part 2: a failed/unknown
    /// toggle result used to only reach `NSLog` (see `apply(_:)` below),
    /// which the captain never sees - a real captain-reported bug (3 real
    /// Barracuda connect attempts, 0 succeeded, and the toggle looked "dead"
    /// with no feedback at all). `main.swift` wires this to
    /// `AppShellController.showToast`, the same main-window `Toast.swift`
    /// pill every other save-confirmation/error in this app already uses -
    /// forward-don't-own, matching `SettingsController.onFontSizeStep`'s own
    /// convention. Always carries the real reason text `VPNToggleResult`
    /// already has, never a bare "something went wrong."
    var onFailure: ((String) -> Void)?

    private let barracudaController: VPNControllable
    private let openVPNController: VPNControllable
    private let coordinator: VPNCoordinator

    private let queue = DispatchQueue(label: "com.firstmate.cockpit.vpn-status")
    private var pollTimer: Timer?
    private var inFlight: Set<VPNKind> = []

    private init() {
        let barracuda = BarracudaVPNController()
        let openVPN = OpenVPNConnectController(driver: RealOpenVPNAccessibilityDriver())
        self.barracudaController = barracuda
        self.openVPNController = openVPN
        self.coordinator = VPNCoordinator(barracuda: barracuda, openVPN: openVPN)
    }

    @discardableResult
    func observe(_ handler: @escaping (Snapshot) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        handler(snapshot)
        return token
    }

    func unobserve(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// Starts the periodic read-only status poll - safe to call repeatedly
    /// (a no-op once already started). Every read here is a plain status
    /// check (`scutil --nc status`, or an AX window-text read), never a
    /// connect/disconnect.
    func start() {
        guard pollTimer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let b = self.barracudaController.currentStatus()
            let o = self.openVPNController.currentStatus()
            DispatchQueue.main.async {
                // A poll landing mid-toggle shouldn't stomp the transitional
                // state `toggle(_:requestOn:)` already published for a kind
                // currently in flight.
                if !self.inFlight.contains(.barracuda) { self.snapshot.barracuda = b }
                if !self.inFlight.contains(.openVPN) { self.snapshot.openVPN = o }
                self.publish()
            }
        }
    }

    /// Requests `kind` connect/disconnect. Publishes an immediate
    /// transitional status (`.connecting`/`.disconnecting`) - and, when
    /// turning one on while the other looks connected, also marks the other
    /// as `.disconnecting` right away - so the UI never shows both toggles
    /// "on" at once, even momentarily, matching the plan's explicit
    /// requirement. The real sequencing (`VPNCoordinator.toggle`) runs on a
    /// background queue; a kind already mid-toggle ignores a second request
    /// rather than racing two toggles of the same VPN.
    func toggle(_ kind: VPNKind, requestOn: Bool) {
        guard !inFlight.contains(kind) else { return }
        inFlight.insert(kind)
        setStatus(requestOn ? .connecting : .disconnecting, for: kind)
        if requestOn {
            let otherKind: VPNKind = kind == .barracuda ? .openVPN : .barracuda
            if status(for: otherKind).isConnected {
                inFlight.insert(otherKind)
                setStatus(.disconnecting, for: otherKind)
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.coordinator.toggle(kind, requestOn: requestOn)
            DispatchQueue.main.async {
                self.apply(result)
                self.inFlight.remove(kind)
                self.inFlight = []
                self.refresh()
            }
        }
    }

    private func status(for kind: VPNKind) -> VPNConnectionStatus {
        kind == .barracuda ? snapshot.barracuda : snapshot.openVPN
    }

    private func setStatus(_ status: VPNConnectionStatus, for kind: VPNKind) {
        if kind == .barracuda { snapshot.barracuda = status } else { snapshot.openVPN = status }
        publish()
    }

    private func apply(_ result: VPNToggleResult) {
        switch result {
        case .connected(let kind):
            setStatus(.connected(profile: nil, durationText: nil), for: kind)
        case .disconnected(let kind):
            setStatus(.disconnected, for: kind)
        case .failed(let kind, let reason):
            NSLog("[vpn] toggle failed for \(kind.displayName): \(reason)")
            onFailure?(Self.failureMessage(kind: kind, reason: reason))
            setStatus(.unknown, for: kind)
        case .unknown(let kind, let reason):
            NSLog("[vpn] toggle result unknown for \(kind.displayName): \(reason)")
            onFailure?(Self.failureMessage(kind: kind, reason: reason))
            setStatus(.unknown, for: kind)
        }
    }

    private func publish() {
        for handler in observers.values { handler(snapshot) }
    }

    /// The exact text `onFailure` receives - pulled out as a static, testable
    /// function (not `private`) so `VPNDataSelfTest.swift` can check it names
    /// the real VPN and carries the real reason, without ever touching
    /// `VPNStatusCenter.shared` itself (see this file's own safety
    /// discipline note on why that singleton is never exercised from a test).
    static func failureMessage(kind: VPNKind, reason: String) -> String {
        "\(kind.displayName): \(reason)"
    }
}
