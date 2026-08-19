// Manjesh Grand Line - native macOS app.
//
// The in-app Notification Center (`fm/grandline-notification-center`,
// captain-approved design: `data/grandline-notification-center/design-
// reference.html`). A single aggregation point for every "the captain
// should know about this" signal already computed somewhere else in the
// app - fleet decisions, PR readiness, tool updates, fork drift, Vault
// attention, machine-setup drift, SRE Lead replies, Shift due items, and
// fleet tasks finishing - so there is one bell + one badge + one list
// instead of a captain needing to remember to open six different pages.
//
// Mirrors this codebase's own established "app-lifetime singleton with an
// `observe`/notify shape" convention (`ThemeManager`, `FontSizeManager`,
// `DocsSyncCenter`) rather than inventing a new one. Every real source is a
// thin adapter (see `NotificationSources.swift`) that reads state a page
// already computes (or, for the handful of signals with nowhere else to
// live, a small dedicated poller - `BackgroundSignalsPoller.swift`) and
// calls `set(_:id:)`/`remove(id:)` here. This file owns none of the
// detection logic itself, only the aggregated list, its two clearing
// semantics, and the observer fan-out the bell/panel UI subscribe to.
//
// Two kinds of item, per the design doc's own "two fundamentally different
// kinds of item" section:
//   - `.actionNeeded` ("waiting for you"): a decision needs input, a PR is
//     ready, an SRE Lead reply is unread. These auto-clear the moment the
//     underlying condition resolves (the next `set`/`remove` from that
//     source reflects it) - there is no manual dismiss for this kind, since
//     dismissing something that still genuinely needs the captain would be
//     actively misleading.
//   - `.informational` ("FYI, something changed"): an update is available,
//     a fork is behind, a security tool needs attention, setup drifted.
//     These clear on resolution too, but can also be manually dismissed
//     ("I know, I'll do it later") via `dismiss(id:)`/`markAllRead()`. A
//     dismiss is remembered by the *exact subtext* of the dismissed entry
//     (`dismissedDetail`) - if the same underlying condition is still true
//     next time this source reports in with the identical detail text, the
//     dismissal holds and it stays hidden; the moment the detail text
//     changes (a new tool joins the update-available count, a fork's
//     behind-by count changes), that's materially new information and the
//     item resurfaces. This is the direct implementation of the design
//     doc's own resolution: "the honest default is to keep resurfacing it
//     until the real condition clears," while still honoring a "not now."
//
// Every source owns exactly one notification id and calls `set(_:id:)` with
// its own freshly-computed truth on every check: passing a real
// `AppNotification` means "this condition is true right now, here is its
// current text," passing `nil` means "resolved." There is no separate
// diffing step here and therefore no way for the same underlying condition
// to produce two entries - `id` is the dedup key, always exactly one entry
// per id. SRE Lead's per-tab replies are the one signal with more than one
// live id at once (`sre-lead.<tabID>`), each independently set/removed by
// its own tab.

import Foundation

enum AppNotificationKind: Equatable {
    case actionNeeded
    case informational
}

/// One row in the panel. Two entries with the same `id` are always meant to
/// be the same logical notification (see `GrandLineNotificationCenter.set`);
/// `navigate` is excluded from `Equatable` since closures can't conform -
/// every other field fully determines whether two entries are "the same,"
/// which is all the self-test and `set`'s own resurface-on-change logic need.
struct AppNotification: Equatable {
    let id: String
    let title: String
    /// "Page/tab it's from + its own clear rule" - matches the panel mock's
    /// copy exactly (e.g. "Overview · clears when answered").
    let subtext: String
    let kind: AppNotificationKind
    let tint: HelmTint
    let navigate: () -> Void

    static func == (lhs: AppNotification, rhs: AppNotification) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtext == rhs.subtext
            && lhs.kind == rhs.kind && lhs.tint == rhs.tint
    }
}

/// An opaque handle to a live `GrandLineNotificationCenter.observe`
/// registration - mirrors `ThemeObservation`. Every observer in this app so
/// far (the topbar bell) is an app-lifetime singleton and can discard it.
final class NotificationCenterObservation {}

final class GrandLineNotificationCenter {
    static let shared = GrandLineNotificationCenter()

    private(set) var entries: [AppNotification] = []

    /// `id -> the subtext it had when dismissed`. See the file header for
    /// why the exact subtext (not just a bare "dismissed" bit) is what's
    /// remembered.
    private var dismissedDetail: [String: String] = [:]

    private var observers: [(token: NotificationCenterObservation, fn: () -> Void)] = []

    /// The bell's badge count - every current entry, regardless of kind.
    var badgeCount: Int { entries.count }

    private init() {}

    @discardableResult
    func observe(_ fn: @escaping () -> Void) -> NotificationCenterObservation {
        let token = NotificationCenterObservation()
        observers.append((token, fn))
        fn()
        return token
    }

    func unobserve(_ token: NotificationCenterObservation) {
        observers.removeAll { $0.token === token }
    }

    /// The one entry point every source calls. `notification == nil` means
    /// "the condition this id represents is no longer true" - removes it
    /// unconditionally (including any remembered dismissal, so a condition
    /// that resolves and later recurs starts fresh). `notification != nil`
    /// means "still true, here is the current text" - added if new, updated
    /// in place if already present, or silently skipped if it's an
    /// `.informational` entry the captain already dismissed with this exact
    /// subtext (see file header).
    func set(_ notification: AppNotification?, id: String) {
        guard let notification else {
            let changed = entries.contains { $0.id == id }
            entries.removeAll { $0.id == id }
            dismissedDetail.removeValue(forKey: id)
            if changed { notifyObservers() }
            return
        }
        precondition(notification.id == id, "AppNotification.id must match the id it's set under")
        if notification.kind == .informational, dismissedDetail[id] == notification.subtext {
            return
        }
        dismissedDetail.removeValue(forKey: id)
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            guard entries[idx] != notification else { return }
            entries[idx] = notification
        } else {
            entries.append(notification)
        }
        notifyObservers()
    }

    /// Removes an entry outright regardless of kind, with no dismissal
    /// remembered - used when the captain's own action IS the resolution
    /// (e.g. opening the tab an SRE Lead reply landed on), as opposed to
    /// `dismiss(id:)`'s "not now, but still true" semantics.
    func remove(id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        dismissedDetail.removeValue(forKey: id)
        notifyObservers()
    }

    /// Manual dismiss - `.informational` only. An `.actionNeeded` item can't
    /// be dismissed away from something that still genuinely needs the
    /// captain; per the design doc, those only ever clear via resolution.
    func dismiss(id: String) {
        guard let entry = entries.first(where: { $0.id == id }), entry.kind == .informational else { return }
        dismissedDetail[id] = entry.subtext
        entries.removeAll { $0.id == id }
        notifyObservers()
    }

    /// The panel's "Mark all read" - every `.informational` entry currently
    /// showing, dismissed in one shot. `.actionNeeded` entries are
    /// untouched, per the rule above.
    func markAllRead() {
        let informational = entries.filter { $0.kind == .informational }
        guard !informational.isEmpty else { return }
        for entry in informational { dismissedDetail[entry.id] = entry.subtext }
        entries.removeAll { $0.kind == .informational }
        notifyObservers()
    }

    private func notifyObservers() {
        observers.forEach { $0.fn() }
    }

    /// Test-only reset - not used by production code. Lets
    /// `GrandLineNotificationCenterSelfTest` start from a clean slate
    /// without disturbing the app-lifetime singleton's observers.
    func resetForTesting() {
        entries.removeAll()
        dismissedDetail.removeAll()
    }
}
