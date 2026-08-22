// Manjesh Grand Line - native macOS app.
//
// GL-10 / GL-30 (production-readiness review): the one place a failed write is
// reported. Before this, ~25 persistence writes across `ShiftStore`,
// `CommandLibraryStore` and `DocsRunbookData` were `try?` - so a write that
// failed (disk full, a permissions change, an `FM_*_DIR` override pointing
// somewhere that has since vanished, a read-only volume) left the in-memory
// model and the UI both confirming a save that had never reached disk. The data
// was simply gone at next launch, with no error, no log line and nothing the
// captain could have noticed at the time.
//
// The shape here is deliberately narrow. It does *not* try to make persistence
// transactional or to roll back the in-memory model: keeping the edit visible
// so the captain can copy it out or retry is better than silently discarding
// their work a second time. What it changes is that the failure is no longer
// silent - it lands in the unified log, in the Health card, and (once anything
// has failed) in the Notification Center.
//
// Two rules for call sites:
//
//  1. **`try` at the boundary, `report` at the store.** The low-level write
//     helpers throw; the store method catches once and calls `report`. That
//     keeps the "which record failed" context, which a throw propagated all the
//     way to a view would lose.
//  2. **Never swallow.** `try?` on a persistence write is now a bug, not a
//     shortcut. `Phase2HardeningSelfTest.noSilentPersistenceWrites` greps for
//     the pattern in the three files this finding names, so a reintroduced
//     `try?` fails the build's own test run rather than waiting to be noticed.

import Foundation

enum PersistenceFailureReporter {

    /// A bounded, newest-first log of what failed, for the Health card. Bounded
    /// because an `FM_SHIFT_DIR` pointing at a vanished volume fails on every
    /// keystroke-driven autosave, and an unbounded list of identical failures
    /// is not more informative than the last few.
    private(set) static var recent: [Failure] = []
    private static let recentLimit = 20
    private static var totalCount = 0

    struct Failure {
        let when: Date
        /// What was being saved, in the captain's terms ("task", "runbook",
        /// "command library entry") - not a file path alone, which does not say
        /// what was lost.
        let what: String
        let path: String
        let reason: String
    }

    /// Call from a store's own catch block. Safe from any thread.
    static func report(what: String, path: String, error: Error) {
        let reason = (error as NSError).localizedDescription
        AppLog.store.error("""
            failed to save \(what, privacy: .public) to \(path, privacy: .public): \
            \(reason, privacy: .public)
            """)

        DispatchQueue.main.async {
            totalCount += 1
            recent.insert(Failure(when: Date(), what: what, path: path, reason: reason), at: 0)
            if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }

            ServiceHealthRegistry.shared.recordFailure(
                .persistence, "\(what): \(reason)")
            NotificationSources.setPersistenceFailure(
                count: totalCount, detail: "\(what) \u{2192} \(path): \(reason)")
        }
    }

    /// Call after a write that succeeded. Keeps the Health card's "last saved"
    /// timestamp honest and resets the consecutive-failure count that drives
    /// the notification threshold.
    ///
    /// Deliberately *not* called from every single write: a store that saves on
    /// every keystroke would turn this into a hot path for no benefit. The
    /// convention is "report success from the store-level save, failure from
    /// anywhere".
    static func reportSuccess() {
        ServiceHealthRegistry.shared.recordSuccess(.persistence)
    }

    /// The captain has seen it. Clears the notification but keeps the log, so
    /// the Health card still shows what happened.
    static func acknowledge() {
        totalCount = 0
        NotificationSources.setPersistenceFailure(count: 0, detail: "")
    }

    /// Test seam only - `Phase2HardeningSelfTest` drives real failures through
    /// `report` and needs a clean slate between cases.
    static func resetForTests() {
        recent = []
        totalCount = 0
    }
}

// MARK: - Throwing write helpers

/// The two write shapes every store in this app uses, as throwing functions.
/// Before GL-10 each store had its own `try?`-ed copy; the atomic-write
/// property (which is what stops a crash mid-write from truncating a real file)
/// was already there and is preserved exactly.
enum AtomicWrite {

    /// Write `data` to `url`, creating intermediate directories. `.atomic`
    /// means the bytes land via a temp file and a rename, so a reader never
    /// sees a half-written file.
    static func data(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    static func text(_ text: String, to url: URL) throws {
        try data(Data(text.utf8), to: url)
    }
}
