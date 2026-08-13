// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-stage0`: the volume test the scout report
// (`data/cockpit-block-view-scout/report.md`, "Mechanism B") calls for -
// neither prior self-test ever exercised more than 5 hand-built blocks with
// a couple of lines of output each, so neither could have given any signal
// about the plausible-but-unverified main-thread cost blowup under real
// scrollback volume (the same class of pathology this codebase's own
// Diff-tool history hit and fixed at `fm/cockpit-tools-yaml-quotes-diff-perf`
// - see AGENTS.md's Diff-tool bullets for the ~13.6-second `NSStackView`-of-
// hundreds-of-rows blowup that motivated switching that tool to an
// `NSTableView`).
//
// Stage 0 deliberately still renders via a plain `NSStackView`
// (`BlockContainerView`, matching the original PR #79/#83 design) rather
// than pre-emptively rewriting it as an `NSTableView` - the mitigating
// factor here is that Stage 0 only ever renders on an explicit manual
// Refresh click, never per host-output chunk (see `TerminalBlockTracker`'s
// header), so a single render's cost is paid once per click, not once per
// ~128KB of host output the way the original attempt's `refreshRunningBlock`
// wiring made it. This test measures whether that single-click cost is
// still acceptable at real volume, not whether it's zero.
//
// Two phases are measured and reported separately, mirroring how the
// Diff-tool perf fix was verified (actual wall-clock cost at increasing row
// counts, not just "it doesn't crash"): (1) parsing hundreds of OSC-133
// prompt cycles into `TerminalBlock`s via a real `HeadlessTerminal` (the
// same parsing path `TerminalBlockTrackerSelfTest` already covers at small
// scale), and (2) rendering that same block list into a real,
// window-mounted `BlockContainerView` and forcing a real
// `layoutSubtreeIfNeeded()` - the actual Auto Layout cost the Diff-tool
// blowup was in. Run with:
//
//   swift build && FM_RUN_BLOCK_VIEW_VOLUME_TESTS=1 .build/debug/FirstmateCockpit; echo $?

import AppKit
import SwiftTerm

enum BlockViewVolumeSelfTest {

    /// Chosen to comfortably exceed the ~300-340 rows that made the
    /// Diff-tool's old `NSStackView` approach take ~13.6 seconds - if this
    /// test's block count were much smaller, a real regression here could
    /// hide the same way the original 5-block hierarchy test hid Mechanism B.
    private static let blockCount = 400

    /// A generous ceiling, not a tight one - this test exists to catch a
    /// gross regression, not to enforce a specific number. See this task's
    /// PR description for the actual measured timings on real hardware.
    ///
    /// `parseBudgetSeconds` is deliberately not tight: this test found a
    /// real, measured cost, not a hypothetical one -
    /// `TerminalBlockTracker.bufferLines(_:)` calls `getBufferAsData()` on
    /// every `B`/`D` marker (see that file's header), which re-serializes
    /// the terminal's *entire* accumulated buffer each time, not just the
    /// delta - so parsing scales worse than linearly with total session
    /// output. 400 events measured at ~4.3s here. In real use this cost is
    /// spread across an entire session as commands actually run (not paid
    /// in one batch the way this synthetic test pays it), so it is not the
    /// same shape of user-facing freeze the render-side fix below addresses
    /// - but it is exactly the `bufferLines`/`getBufferAsData` cost the
    /// scout report's Mechanism B names, confirmed real rather than
    /// "plausible but unverified," and worth carrying into Stage 1's design
    /// (which reintroduces per-chunk parsing) rather than re-discovering.
    private static let parseBudgetSeconds: Double = 8.0
    private static let renderBudgetSeconds: Double = 5.0

    static func run() -> Bool {
        var failures = 0

        let (blocks, parseSeconds, parseFailure) = measureParse()
        if let parseFailure {
            print("FAIL parsesLargeSyntheticBufferWithinBudget: \(parseFailure)")
            failures += 1
        } else {
            print("PASS parsesLargeSyntheticBufferWithinBudget (\(blocks.count) blocks in \(String(format: "%.3f", parseSeconds))s)")
        }

        let (renderSeconds, renderFailure) = measureRender(blocks: blocks)
        if let renderFailure {
            print("FAIL rendersLargeBlockListWithinBudget: \(renderFailure)")
            failures += 1
        } else {
            print("PASS rendersLargeBlockListWithinBudget (\(blocks.count) blocks in \(String(format: "%.3f", renderSeconds))s)")
        }

        print("BlockViewVolumeSelfTest: parse=\(String(format: "%.3f", parseSeconds))s render=\(String(format: "%.3f", renderSeconds))s total=\(String(format: "%.3f", parseSeconds + renderSeconds))s for \(blockCount) synthetic blocks")
        print(failures == 0 ? "BlockViewVolumeSelfTest: all cases passed" : "BlockViewVolumeSelfTest: \(failures)/2 cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    /// One prompt cycle's raw bytes, matching `TerminalBlockTrackerSelfTest`'s
    /// own validated shape - the `B` marker, the echoed command, a
    /// realistic multi-line output body (not a couple of words - a real
    /// bastion session's command output is often many lines), then the `D`
    /// marker closing it.
    private static func promptCycle(index: Int) -> String {
        let command = "kubectl logs pod-\(index) --tail=20"
        let output = (0..<12).map { "line \($0) of output for command #\(index): some realistic log content here" }.joined(separator: "\r\n")
        return "\u{1b}]133;B\u{07}" + command + "\r\n" + output + "\r\n" + "\u{1b}]133;D;0;\(b64(command))\u{07}"
    }

    // MARK: Measurement

    private static func measureParse() -> (blocks: [TerminalBlock], seconds: Double, failure: String?) {
        let headless = HeadlessTerminal(options: .default) { _ in }
        let terminal: Terminal = headless.terminal
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        let start = DispatchTime.now()
        for i in 0..<blockCount {
            terminal.feed(byteArray: [UInt8](promptCycle(index: i).utf8))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        guard tracker.blocks.count == blockCount else {
            return (tracker.blocks, elapsed, "expected \(blockCount) parsed blocks, got \(tracker.blocks.count)")
        }
        guard elapsed <= parseBudgetSeconds else {
            return (tracker.blocks, elapsed, "parsing \(blockCount) blocks took \(elapsed)s, over the \(parseBudgetSeconds)s budget")
        }
        return (tracker.blocks, elapsed, nil)
    }

    private static func measureRender(blocks: [TerminalBlock]) -> (seconds: Double, failure: String?) {
        guard !blocks.isEmpty else { return (0, "no blocks to render (parse phase produced none)") }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = root
        let container = BlockContainerView(frame: .zero)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()

        // This is the exact call Stage 0's manual Refresh action makes -
        // one wholesale `render(_:)` plus the real Auto Layout resolve that
        // follows, at real volume rather than the 5-block case
        // `BlockViewHierarchySelfTest` covers.
        let start = DispatchTime.now()
        container.render(blocks)
        root.layoutSubtreeIfNeeded()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        guard container.subviews.contains(where: { $0 is NSScrollView }) else {
            return (elapsed, "container lost its scroll view after a \(blocks.count)-block render")
        }
        guard elapsed <= renderBudgetSeconds else {
            return (elapsed, "rendering \(blocks.count) blocks took \(elapsed)s, over the \(renderBudgetSeconds)s budget - see AGENTS.md's Diff-tool history for this exact NSStackView pathology")
        }
        return (elapsed, nil)
    }
}
