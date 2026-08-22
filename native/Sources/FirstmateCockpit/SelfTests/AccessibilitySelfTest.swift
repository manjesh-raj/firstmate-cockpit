// Manjesh Grand Line - native macOS app.
//
// GL-16: what the accessibility sweep actually guarantees, asserted rather
// than described.
//
// The review scored accessibility 2.5/10 - the app's weakest dimension - with
// one specific, countable finding: ~40 `NSClickGestureRecognizer`-driven
// controls that VoiceOver saw as static text, with no role, no label, and no
// way to activate them. The fix was made once, in the four shared components
// (`HoverHighlightView`, `HelmAccentRow`, `HelmSegmentedTabs`, `HelmStatTile`)
// plus `HelmButton`/`TabChipView`/`HelmTableView`, precisely so it would cover
// all ~40 sites without touching them. That is only true as long as those
// components keep their end of the bargain, which is what this suite pins.
//
// Two invariants matter more than the individual cases:
//
//   1. A control that *does* something announces as a button (or a radio
//      button in a one-of-many strip), carries a real label, and can be
//      pressed - by VoiceOver and from the keyboard.
//   2. A control that does *nothing* stays invisible to assistive technology
//      and out of the key view loop. Flooding VoiceOver with decorative
//      containers is its own accessibility failure, and this app is built
//      almost entirely out of decorative containers.
//
// Run: `FM_RUN_ACCESSIBILITY_TESTS=1 .build/debug/FirstmateCockpit`
//
// No window is created and no AppKit layout pass is needed for any of this,
// which is why this suite runs in CI where the render-based ones cannot.

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

import AppKit

enum AccessibilitySelfTest {

    static func run() -> Bool {
        var ok = true
        checkHoverHighlightView(&ok)
        checkSegmentedTabs(&ok)
        checkStatTile(&ok)
        checkAccentRow(&ok)
        checkIconButtonLabels(&ok)
        checkKeyboardActivation(&ok)
        checkFocusRingsRestored(&ok)
        checkReduceMotionIsHonoured(&ok)
        print(ok ? "AccessibilitySelfTest: all checks passed" : "AccessibilitySelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: The shared clickable surface

    private static func checkHoverHighlightView(_ ok: inout Bool) {
        print("\n-- HoverHighlightView: the surface behind most of the ~40 sites --")

        // Decorative: no recognizer, no press handler. Must stay silent.
        let decorative = HoverHighlightView()
        if decorative.isAccessibilityElement() {
            fail("a decorative hover card exposed itself as an accessibility element", &ok)
        }
        if decorative.acceptsFirstResponder {
            fail("a decorative hover card joined the key view loop", &ok)
        }

        // Clickable via a recognizer, exactly how every real call site does it.
        let target = RecordingTarget()
        let clickable = HoverHighlightView()
        let label = NSTextField(labelWithString: "Kubernetes")
        let count = NSTextField(labelWithString: "8 commands")
        clickable.addSubview(label)
        clickable.addSubview(count)
        clickable.addGestureRecognizer(
            NSClickGestureRecognizer(target: target, action: #selector(RecordingTarget.hit(_:))))

        if !clickable.isAccessibilityElement() {
            fail("a hover card with a click recognizer is still invisible to VoiceOver", &ok)
        }
        if clickable.accessibilityRole() != .button {
            fail("expected .button, got \(String(describing: clickable.accessibilityRole()))", &ok)
        }
        // The label is derived from the row's own text - the mechanism that
        // makes this a one-place fix rather than 40 call-site edits.
        let derived = clickable.accessibilityLabel() ?? ""
        if !derived.contains("Kubernetes") || !derived.contains("8 commands") {
            fail("derived label lost the row's own text: \"\(derived)\"", &ok)
        }
        if clickable.accessibilityChildren()?.isEmpty != true {
            fail("a button-role card still exposes its own labels as children (VoiceOver reads them twice)", &ok)
        }
        if !clickable.accessibilityPerformPress() || target.hits != 1 {
            fail("accessibilityPerformPress did not reach the recognizer's action (\(target.hits) hits)", &ok)
        }
        // The recognizer must be the sender: several handlers read
        // `sender.view` to know which row was hit.
        if !(target.lastSender is NSClickGestureRecognizer) {
            fail("press sent \(String(describing: target.lastSender)) rather than the recognizer", &ok)
        }

        // An explicit override wins over the derived text.
        clickable.accessibilityLabelOverride = "Open the Kubernetes category"
        if clickable.accessibilityLabel() != "Open the Kubernetes category" {
            fail("accessibilityLabelOverride was ignored", &ok)
        }

        // A press handler with no recognizer at all also counts.
        var pressed = false
        let handlerOnly = HoverHighlightView()
        handlerOnly.onAccessibilityPress = { pressed = true }
        if !handlerOnly.isAccessibilityElement() { fail("onAccessibilityPress did not make the view an element", &ok) }
        if !handlerOnly.accessibilityPerformPress() || !pressed {
            fail("onAccessibilityPress was not invoked", &ok)
        }
        print("  OK - role, derived label, override, press, and decorative views stay silent")
    }

    // MARK: Segmented tabs (the app-wide sub-navigation)

    private static func checkSegmentedTabs(_ ok: inout Bool) {
        print("\n-- HelmSegmentedTabs: a segment is one-of-many, and arrows move --")
        let tabs = HelmSegmentedTabs(items: [
            .init(id: "hosts", title: "Hosts"),
            .init(id: "keys", title: "SSH Keys"),
            .init(id: "snippets", title: "Snippets"),
        ], selected: "hosts")

        let pills = tabs.debugPillsForAccessibilityTests()
        guard pills.count == 3 else {
            fail("expected 3 pills, got \(pills.count)", &ok)
            return
        }
        for pill in pills {
            if pill.accessibilityRole() != .radioButton {
                fail("a segment announced as \(String(describing: pill.accessibilityRole())) rather than .radioButton", &ok)
            }
            if !pill.acceptsFirstResponder {
                fail("a segment cannot take keyboard focus - ⌘1-9 covers console tabs only", &ok)
            }
        }
        if pills[0].accessibilityValue() as? String != "selected" {
            fail("the active segment does not announce as selected", &ok)
        }
        if pills[1].accessibilityValue() as? String != "not selected" {
            fail("an inactive segment does not announce as not selected", &ok)
        }
        if pills[1].accessibilityLabel() != "SSH Keys" {
            fail("a segment's label is \(String(describing: pills[1].accessibilityLabel())), want its title", &ok)
        }

        // Pressing a segment selects it and reports it, exactly like a click.
        var reported: [String] = []
        tabs.onSelect = { reported.append($0) }
        _ = pills[2].accessibilityPerformPress()
        if tabs.selected != "snippets" || reported != ["snippets"] {
            fail("pressing a segment did not select it (selected=\(tabs.selected), reported=\(reported))", &ok)
        }
        if pills[2].accessibilityValue() as? String != "selected" {
            fail("the announced value did not follow the new selection", &ok)
        }
        print("  OK - radioButton role, live selected value, focusable, press selects")
    }

    // MARK: Stat tiles

    private static func checkStatTile(_ ok: inout Bool) {
        print("\n-- HelmStatTile: always readable, a button only when it does something --")
        let readOnly = HelmStatTile(symbol: "clock", value: "4", caption: "queued")
        if !readOnly.isAccessibilityElement() {
            fail("a stat tile is the page's headline number and must be readable", &ok)
        }
        if readOnly.accessibilityRole() != .staticText {
            fail("a tile with no action should be static text, got \(String(describing: readOnly.accessibilityRole()))", &ok)
        }
        if readOnly.acceptsFirstResponder {
            fail("a tile with no action joined the key view loop", &ok)
        }
        // Caption first: "ready to merge, 3" is how a captain would say it.
        if readOnly.accessibilityLabel() != "queued, 4" {
            fail("tile label is \(String(describing: readOnly.accessibilityLabel())), want \"queued, 4\"", &ok)
        }

        var tapped = false
        let clickable = HelmStatTile(symbol: "checkmark", value: "3", caption: "ready to merge")
        clickable.onClick = { tapped = true }
        if clickable.accessibilityRole() != .button {
            fail("a clickable tile should be a button", &ok)
        }
        if !clickable.acceptsFirstResponder {
            fail("a clickable tile is not keyboard-reachable", &ok)
        }
        if !clickable.accessibilityPerformPress() || !tapped {
            fail("pressing a clickable tile did not fire onClick", &ok)
        }
        print("  OK - staticText vs button, caption-first label, press fires onClick")
    }

    // MARK: Accent rows (hosts, tasks, notifications, PRs)

    private static func checkAccentRow(_ ok: inout Bool) {
        print("\n-- HelmAccentRow: the app's one list row --")
        let theme = ThemeManager.shared.theme

        let readOnly = HelmAccentRow(hover: false)
        readOnly.configure(.init(tint: .info, kicker: "TASK", title: "Ship phase 3"), theme: theme)
        if readOnly.isAccessibilityElement() {
            fail("a row with no onClick pretended to be a button", &ok)
        }

        var opened = false
        let row = HelmAccentRow()
        row.onClick = { opened = true }
        row.configure(.init(tint: .good, kicker: "HOST", title: "Prod Bastion",
                            meta: "ubuntu@10.0.0.4", chipText: "SSH"), theme: theme)
        if row.accessibilityRole() != .button {
            fail("a clickable row should be a button", &ok)
        }
        let label = row.accessibilityLabel() ?? ""
        for expected in ["HOST", "Prod Bastion", "ubuntu@10.0.0.4", "SSH"] {
            if !label.contains(expected) {
                fail("row label \"\(label)\" is missing \"\(expected)\"", &ok)
            }
        }
        if !row.accessibilityPerformPress() || !opened {
            fail("pressing a row did not fire onClick", &ok)
        }
        row.isRowSelected = true
        if row.accessibilityValue() as? String != "selected" {
            fail("a selected row does not announce its selection", &ok)
        }
        print("  OK - kicker/title/meta/chip read out, press activates, selection announced")
    }

    // MARK: Icon-only buttons

    private static func checkIconButtonLabels(_ ok: inout Bool) {
        print("\n-- icon-only HelmButtons must not read out an SF Symbol name --")
        let refresh = HelmButton(symbol: "arrow.clockwise", variant: .quiet)
        refresh.toolTip = "Refresh"
        guard let label = refresh.accessibilityLabel() else {
            fail("an icon-only button has no accessibility label at all", &ok)
            return
        }
        if label != "Refresh" {
            fail("icon button reads \"\(label)\" - the tooltip is the right words", &ok)
        }
        if label.contains("arrow") || label.contains("clockwise") {
            fail("the raw SF Symbol name is still being announced", &ok)
        }
        // A titled button keeps its title, tooltip or no tooltip.
        let titled = HelmButton(title: "Merge", variant: .primary)
        titled.toolTip = "Merge this pull request"
        if titled.accessibilityLabel() != "Merge" {
            fail("a titled button's label changed to \(String(describing: titled.accessibilityLabel()))", &ok)
        }
        print("  OK - tooltip wins for an icon, title wins for a labelled button")
    }

    // MARK: Keyboard

    private static func checkKeyboardActivation(_ ok: inout Bool) {
        print("\n-- keyboard: Return / Space / Enter activate, other keys do not --")
        // 36 = Return, 76 = keypad Enter, 49 = Space, 48 = Tab.
        let activation = [36, 76, 49]
        for keyCode in activation + [48] {
            var fired = 0
            let view = HoverHighlightView()
            view.onAccessibilityPress = { fired += 1 }
            guard let event = keyEvent(keyCode: keyCode) else {
                fail("could not synthesise a key event for keycode \(keyCode)", &ok)
                continue
            }
            view.keyDown(with: event)
            let expected = activation.contains(keyCode) ? 1 : 0
            if fired != expected {
                fail("keycode \(keyCode) fired \(fired) time(s), expected \(expected)", &ok)
            }
        }

        // `onKeyDown` gets first refusal - this is the seam segmented tabs use
        // for arrow keys, and it must be able to swallow an event.
        var swallowed = false
        var pressed = false
        let view = HoverHighlightView()
        view.onAccessibilityPress = { pressed = true }
        view.onKeyDown = { _ in swallowed = true; return true }
        if let event = keyEvent(keyCode: 36) { view.keyDown(with: event) }
        if !swallowed { fail("onKeyDown was not consulted", &ok) }
        if pressed { fail("onKeyDown returned true but the press ran anyway", &ok) }

        // A table row's primary action is `doubleAction`, and GL-16's fix is
        // that `clickedRow` reports the selected row during a keyboard
        // activation - so the four existing handlers work unchanged.
        let table = HelmTableView()
        let handler = RecordingTarget()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        let source = SingleRowSource()
        table.dataSource = source
        table.reloadData()
        table.target = handler
        table.doubleAction = #selector(RecordingTarget.tableActivated(_:))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        if let event = keyEvent(keyCode: 36) { table.keyDown(with: event) }
        if handler.hits != 1 {
            fail("Return on a selected table row did not fire doubleAction (\(handler.hits) hits)", &ok)
        }
        if handler.clickedRowAtActivation != 0 {
            fail("clickedRow was \(handler.clickedRowAtActivation) during keyboard activation - every handler in this app reads it", &ok)
        }
        // And it must go back to -1 afterwards, or an unrelated later read
        // would see a phantom click.
        if table.clickedRow != -1 {
            fail("clickedRow stayed at \(table.clickedRow) after the activation finished", &ok)
        }
        print("  OK - Return/Enter/Space activate, Tab does not, onKeyDown can swallow, clickedRow is right")
    }

    // MARK: Focus rings

    private static func checkFocusRingsRestored(_ ok: inout Bool) {
        print("\n-- focus rings: a de-bezeled control still has to show focus --")
        let cases: [(String, NSView)] = [
            ("HelmButton", HelmButton(title: "Save", variant: .primary)),
            ("HelmPopUpButton", HelmPopUpButton()),
            ("HoverHighlightView", HoverHighlightView()),
            ("HelmStatTile", HelmStatTile(symbol: "clock", value: "1", caption: "x")),
            ("TabChipView", TabChipView(tabID: UUID(), name: "Shell")),
        ]
        for (name, view) in cases {
            if view.focusRingType != .exterior {
                fail("\(name) has focusRingType .\(view.focusRingType == .none ? "none" : "default") - keyboard focus is invisible", &ok)
            }
        }
        // The mask must be a real shape, not the default empty one, or
        // `.exterior` draws nothing.
        let chip = TabChipView(tabID: UUID(), name: "Shell")
        chip.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        if chip.focusRingMaskBounds != chip.bounds {
            fail("TabChipView's focus ring mask bounds are \(chip.focusRingMaskBounds), want its own bounds", &ok)
        }
        print("  OK - all five carry .exterior and a real mask")
    }

    // MARK: Reduce Motion

    private static func checkReduceMotionIsHonoured(_ ok: inout Bool) {
        print("\n-- Reduce Motion: every looping animation is gated, and observed --")
        // Source-level, deliberately: the three looping animations live in
        // three different controllers, two of which need a real window to
        // instantiate. What must never regress is that each one both *checks*
        // the preference and *observes* changes to it - a check with no
        // observer means the setting only takes effect on relaunch, which is
        // the exact half-fix the review called out.
        guard let dir = SelfTestSources.appSourceDirectory() else {
            fail("could not locate the app sources - this check would silently pass", &ok)
            return
        }
        let required = [
            "LockScreenController.swift",
            "IconRailController.swift",
            "DictationHUD.swift",
            "HelmUIComponents.swift",
        ]
        for file in required {
            let url = dir.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                fail("could not read \(file) - has it moved? this check would silently pass", &ok)
                continue
            }
            if !text.contains("accessibilityDisplayShouldReduceMotion") {
                fail("\(file) has a looping/animated surface but never checks Reduce Motion", &ok)
            }
            // `HelmUIComponents`' hover fade is a one-shot on a real event, so
            // it needs the check but not a change observer.
            if file != "HelmUIComponents.swift",
               !text.contains("accessibilityDisplayOptionsDidChangeNotification") {
                fail("\(file) checks Reduce Motion but never observes changes to it - the setting would need a relaunch", &ok)
            }
        }
        print("  OK - lock screen, rail mark, dictation HUD and hover fade all consult it")
    }

    // MARK: Helpers

    private final class RecordingTarget: NSObject {
        var hits = 0
        var lastSender: Any?
        var clickedRowAtActivation = -99

        @objc func hit(_ sender: Any?) {
            hits += 1
            lastSender = sender
        }

        @objc func tableActivated(_ sender: Any?) {
            hits += 1
            lastSender = sender
            if let table = sender as? NSTableView { clickedRowAtActivation = table.clickedRow }
        }
    }

    private final class SingleRowSource: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 1 }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "row" }
    }

    private static func keyEvent(keyCode: Int) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: " ", charactersIgnoringModifiers: " ",
                         isARepeat: false, keyCode: UInt16(keyCode))
    }
}

#endif
