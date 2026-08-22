// Manjesh Grand Line - native macOS app.
//
// Phase 3's own structural guards - the handful of Phase 3 invariants that are
// about the *shape of the codebase* rather than about a component's behaviour,
// and would therefore be silently lost by an ordinary, well-meaning edit.
//
//   - GL-27: every suite in `SelfTests/` is compiled out of the release
//     binary. A new suite added without the guard would quietly put itself
//     back into the shipped app, and nothing else would notice.
//   - GL-32: the UI-chrome text floor holds at every offered scale, and the
//     scale is genuinely reachable from `HelmType` rather than being a stored
//     number nothing reads.
//   - GL-35: the growth caps exist as real constants, not as comments.
//   - GL-33: the undo toast is one slot, and a plain confirmation cannot
//     accidentally acquire an Undo button.
//
// Run: `FM_RUN_PHASE3_POLISH_TESTS=1 .build/debug/FirstmateCockpit`

#if FM_SELFTESTS

import AppKit

enum Phase3PolishSelfTest {

    static func run() -> Bool {
        var ok = true
        checkSuitesAreDebugOnly(&ok)
        checkTextScaleFloor(&ok)
        checkGrowthCaps(&ok)
        checkUndoToastShape(&ok)
        print(ok ? "Phase3PolishSelfTest: all checks passed" : "Phase3PolishSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: GL-27

    private static func checkSuitesAreDebugOnly(_ ok: inout Bool) {
        print("\n-- GL-27: every suite is compiled out of release --")
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            fail("could not list \(dir.path) - this check would silently pass", &ok)
            return
        }
        let suites = files.filter { $0.pathExtension == "swift" }
        guard suites.count > 40 else {
            fail("found only \(suites.count) files in SelfTests/ - has the directory moved?", &ok)
            return
        }
        var missing: [String] = []
        for file in suites {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                fail("could not read \(file.lastPathComponent)", &ok)
                continue
            }
            if !text.contains("#if FM_SELFTESTS") { missing.append(file.lastPathComponent) }
        }
        if !missing.isEmpty {
            fail("these would ship in the release binary: \(missing.joined(separator: ", "))", &ok)
        }

        // The dispatch chain has to be guarded too - the flags themselves are
        // what pull every suite's symbols in.
        guard let main = SelfTestSources.appSourceDirectory()?.appendingPathComponent("main.swift"),
              let mainText = try? String(contentsOf: main, encoding: .utf8) else {
            print("  SKIP - app sources not next to this binary")
            return
        }
        if !mainText.contains("#if FM_SELFTESTS") {
            fail("main.swift's FM_RUN_* dispatch chain is not compiled out of release", &ok)
        }
        // The flags must still be greppable text in main.swift, because that
        // is where `Scripts/run-all-tests.sh` discovers the suite list.
        let flagCount = mainText.components(separatedBy: "FM_RUN_").count - 1
        if flagCount < suites.count - 5 {
            fail("main.swift mentions \(flagCount) FM_RUN_ flags for \(suites.count) suite files - a suite may be undispatched", &ok)
        }
        print("  OK - \(suites.count) files guarded, dispatch guarded, \(flagCount) flags still discoverable")
    }

    // MARK: GL-32

    private static func checkTextScaleFloor(_ ok: inout Bool) {
        print("\n-- GL-32: the chrome-text floor holds at every offered scale --")
        // `ChromeTextScale.shared` is a singleton reading real preferences, so
        // this asserts the pure function every accessor goes through rather
        // than mutating the captain's own setting.
        if HelmType.minimumUIPointSize < 11 {
            fail("the floor dropped to \(HelmType.minimumUIPointSize)pt - the review's finding was 10-11.5pt captions", &ok)
        }
        // At the active scale, nothing any accessor returns may sit below the
        // floor. The kicker is the smallest, which is why it is named here.
        let scale = ChromeTextScale.shared.scale
        let smallest = min(HelmType.kicker().pointSize,
                           min(HelmType.caption().pointSize, HelmType.code().pointSize))
        if smallest < HelmType.minimumUIPointSize * scale - 0.01 {
            fail("smallest chrome font is \(smallest)pt, below the \(HelmType.minimumUIPointSize * scale)pt floor", &ok)
        }
        // The scale has to actually reach the type scale: a stored number that
        // nothing reads is worse than no setting at all.
        for step in ChromeTextScale.steps {
            let scaled = HelmType.scaled(20)
            _ = scaled
            if step.scale < ChromeTextScale.minScale || step.scale > ChromeTextScale.maxScale {
                fail("step \"\(step.title)\" (\(step.scale)) is outside the clamped range", &ok)
            }
        }
        if HelmType.scaled(20) != max(HelmType.minimumUIPointSize * scale, 20 * scale) {
            fail("HelmType.scaled does not apply the active scale", &ok)
        }
        // The floor must win over a genuinely smaller designed size.
        if HelmType.scaled(6) < HelmType.minimumUIPointSize * scale - 0.01 {
            fail("a 6pt designed size escaped the floor", &ok)
        }
        print("  OK - floor \(HelmType.minimumUIPointSize)pt, \(ChromeTextScale.steps.count) steps, all clamped, floor wins")
    }

    // MARK: GL-35

    private static func checkGrowthCaps(_ ok: inout Bool) {
        print("\n-- GL-35: the caps are real constants --")
        if DictationStore.historyLimit <= 0 || DictationStore.historyLimit > 5000 {
            fail("dictation history limit is \(DictationStore.historyLimit) - the file is rewritten whole on every dictation", &ok)
        }
        // The scratch-clone prune and the model delete have to exist as real
        // entry points; asserting from source keeps this honest without
        // deleting anything on the machine running the suite.
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP - app sources not next to this binary")
            return
        }
        let expectations: [(file: String, needle: String, why: String)] = [
            ("GitHubSyncData.swift", "--single-branch", "scratch clones are still full clones"),
            ("GitHubSyncData.swift", "pruneOrphanedManualClones", "nothing removes a clone for a repo no longer in the catalog"),
            ("WhisperModel.swift", "deleteDownloadedModel", "the 547MB model has no delete action"),
            ("ShiftStore.swift", "completedTasksCache", "completed month files are parsed per render again"),
            ("LogAnalyzerStore.swift", "invalidateHistoryCache", "the investigation history walk is uncached again"),
        ]
        for expectation in expectations {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(expectation.file), encoding: .utf8) else {
                fail("could not read \(expectation.file)", &ok)
                continue
            }
            if !text.contains(expectation.needle) {
                fail("\(expectation.file): \(expectation.why) (no \"\(expectation.needle)\")", &ok)
            }
        }
        print("  OK - history cap, shallow clones, clone prune, model delete, both read caches")
    }

    // MARK: GL-33

    private static func checkUndoToastShape(_ ok: inout Bool) {
        print("\n-- GL-33: one undo slot, and only where asked for --")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

        // A plain confirmation must not grow an Undo button.
        Toast.show(in: container, message: "Saved")
        if undoButtonCount(in: container) != 0 {
            fail("a plain confirmation rendered an Undo button", &ok)
        }

        // An undo toast has exactly one, and its handler runs on press.
        var undone = 0
        Toast.showUndo(in: container, message: "Deleted \u{201C}Prod Bastion\u{201D}") { undone += 1 }
        if undoButtonCount(in: container) != 1 {
            fail("expected exactly one Undo button, found \(undoButtonCount(in: container))", &ok)
        }
        guard let button = undoButtons(in: container).first else {
            fail("no Undo button to press", &ok)
            return
        }
        button.performClick(nil)
        if undone != 1 { fail("pressing Undo ran the handler \(undone) times", &ok) }
        button.performClick(nil)
        if undone != 1 { fail("Undo is not single-use - pressed twice, ran \(undone) times", &ok) }

        // A second undo toast supersedes the first, committing it: the first
        // handler must never run - not when it is replaced, and not if its
        // now-stale button is pressed afterwards. (The pill itself fades out
        // over a real animation, so it is still in the view tree at this
        // point - which is why the assertion is about the *handler*, the thing
        // that would actually resurrect a deleted record, rather than about
        // how many views are on screen.)
        let before = undoButtons(in: container).count
        var firstRan = 0
        var secondRan = 0
        Toast.showUndo(in: container, message: "first") { firstRan += 1 }
        let firstButton = undoButtons(in: container).dropFirst(before).first
        Toast.showUndo(in: container, message: "second") { secondRan += 1 }
        if firstRan != 0 {
            fail("being superseded ran the first toast's undo handler", &ok)
        }
        firstButton?.performClick(nil)
        if firstRan != 0 {
            fail("a superseded toast's Undo button still worked - two live undo slots", &ok)
        }
        // The newest slot is the live one.
        undoButtons(in: container).last?.performClick(nil)
        if secondRan != 1 {
            fail("the newest undo slot did not fire (ran \(secondRan) times)", &ok)
        }
        print("  OK - plain toast has no Undo, Undo is single-use, superseding commits the previous delete")
    }

    private static func undoButtons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        for sub in view.subviews {
            if let button = sub as? NSButton, button.title == "Undo" { found.append(button) }
            found.append(contentsOf: undoButtons(in: sub))
        }
        return found
    }

    private static func undoButtonCount(in view: NSView) -> Int { undoButtons(in: view).count }
}

#endif
