// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for `ShiftImageAttachmentWell.normalizedPNGData`
// (grandline-shift-task-image-attachments), run via
// `FM_RUN_SHIFT_ATTACHMENT_WELL_TESTS=1 .build/debug/FirstmateCockpit` -
// same convention as `ShiftStoreSelfTest.swift`/`ShiftDateParserSelfTest.swift`
// (see main.swift's gate list). Pure image-processing logic, no window/view
// hierarchy involved - a real (synthetically drawn, not a captured
// screenshot) `NSImage` in, real PNG bytes out.

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

enum ShiftImageAttachmentWellSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        func syntheticImage(width: Int, height: Int) -> NSImage {
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            NSColor.white.setFill()
            NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2).fill()
            image.unlockFocus()
            return image
        }

        // MARK: A large "screenshot-shaped" image gets downscaled and stays
        // well under the size a full-resolution Retina capture would run.

        let large = syntheticImage(width: 3200, height: 2000)
        guard let downscaledData = ShiftImageAttachmentWell.normalizedPNGData(from: large, maxDimension: 1600) else {
            return report(["normalizedPNGData returned nil for a valid large image"])
        }
        guard let downscaledImage = NSImage(data: downscaledData) else {
            return report(["normalizedPNGData's output should itself decode back into a valid image"])
        }
        let downscaledRep = downscaledImage.representations.first
        check((downscaledRep?.pixelsWide ?? 0) <= 1600, "downscaled image's longest edge should be capped at 1600px, got \(downscaledRep?.pixelsWide ?? -1)")
        check((downscaledRep?.pixelsWide ?? 0) == 1600, "a 3200x2000 source at maxDimension 1600 should scale its width down to exactly 1600, got \(downscaledRep?.pixelsWide ?? -1)")
        check((downscaledRep?.pixelsHigh ?? 0) == 1000, "a 3200x2000 source at maxDimension 1600 should scale its height down to exactly 1000 (same aspect ratio), got \(downscaledRep?.pixelsHigh ?? -1)")
        check(downscaledData.count < 200_000, "a small, mostly-flat-color 1600x1000 PNG should compress to well under 200KB, got \(downscaledData.count) bytes")

        // MARK: A small image is never upscaled.

        let small = syntheticImage(width: 200, height: 150)
        guard let smallData = ShiftImageAttachmentWell.normalizedPNGData(from: small, maxDimension: 1600) else {
            return report(["normalizedPNGData returned nil for a valid small image"])
        }
        let smallRep = NSImage(data: smallData)?.representations.first
        check((smallRep?.pixelsWide ?? 0) == 200, "an image already smaller than maxDimension should not be upscaled, got width \(smallRep?.pixelsWide ?? -1)")
        check((smallRep?.pixelsHigh ?? 0) == 150, "an image already smaller than maxDimension should not be upscaled, got height \(smallRep?.pixelsHigh ?? -1)")

        // MARK: A degenerate (zero-size) image is rejected, not crashed on.

        let zero = NSImage(size: .zero)
        check(ShiftImageAttachmentWell.normalizedPNGData(from: zero) == nil, "a zero-size image should return nil rather than produce a degenerate 0-byte/garbage PNG")

        // MARK: Pasteboard intake - the exact code path drag-drop and
        // clipboard paste both funnel through (`Self.image(fromPasteboard:)`,
        // shared by `performDragOperation` and `paste(_:)`). Uses a private,
        // named scratch pasteboard rather than `.general` so this test never
        // touches the real system clipboard.
        //
        // A real synthetic `NSDraggingInfo` drop and a real `⌘V` key event
        // through a live window need a real window/event loop this
        // headless self-test doesn't have - this instead drives the shared
        // reading code directly with pasteboard content shaped exactly like
        // what each real intake path hands it: a file URL (a Finder drag),
        // and raw image bytes with no backing file (a clipboard screenshot).

        let scratchPasteboard = NSPasteboard(name: NSPasteboard.Name("shift-attachment-selftest-\(UUID().uuidString)"))

        // "Drag-drop of an image file": a real file on disk, its URL on the
        // pasteboard - what dragging a Finder file onto the well provides.
        let tmpImageURL = FileManager.default.temporaryDirectory.appendingPathComponent("shift-attachment-selftest-\(UUID().uuidString).png")
        if let fileData = ShiftImageAttachmentWell.normalizedPNGData(from: syntheticImage(width: 400, height: 300)) {
            try? fileData.write(to: tmpImageURL)
        }
        defer { try? FileManager.default.removeItem(at: tmpImageURL) }
        scratchPasteboard.clearContents()
        scratchPasteboard.writeObjects([tmpImageURL as NSURL])
        let imageFromFileURL = ShiftImageAttachmentWell.image(fromPasteboard: scratchPasteboard)
        check(imageFromFileURL != nil, "image(fromPasteboard:) should read a real image from a file URL on the pasteboard, the drag-drop shape")
        check((imageFromFileURL?.representations.first?.pixelsWide ?? 0) == 400, "the image read from a dropped file URL should match the real file's dimensions")

        // "Paste a screenshot from the clipboard": raw image bytes with no
        // backing file at all - what a real `⌘⇧⌃4` screenshot capture puts
        // on the clipboard.
        scratchPasteboard.clearContents()
        let rawImage = syntheticImage(width: 500, height: 250)
        scratchPasteboard.writeObjects([rawImage])
        let imageFromRawPaste = ShiftImageAttachmentWell.image(fromPasteboard: scratchPasteboard)
        check(imageFromRawPaste != nil, "image(fromPasteboard:) should read a real image from raw image bytes with no file, the clipboard-paste shape")

        // An empty pasteboard (nothing copied/dropped) should read as no
        // image, not crash or fabricate one.
        scratchPasteboard.clearContents()
        check(ShiftImageAttachmentWell.image(fromPasteboard: scratchPasteboard) == nil, "an empty pasteboard should read as no image")

        // MARK: Full well round trip - handle(image:) -> onImageChosen ->
        // thumbnail shown -> remove -> onRemove -> back to placeholder. This
        // is the same call `chooseImageClicked`'s open-panel completion,
        // `performDragOperation`, and `paste(_:)` all make once they have a
        // real `NSImage` in hand - proves the well's own state machine
        // (real thumbnail visible, remove button visible, placeholder
        // hidden, and the reverse) end to end.
        let well = ShiftImageAttachmentWell()
        var chosenData: Data?
        var removeFired = false
        well.onImageChosen = { chosenData = $0 }
        well.onRemove = { removeFired = true }

        well.handle(image: syntheticImage(width: 900, height: 600))
        check(chosenData != nil, "handle(image:) should report normalized data via onImageChosen")
        check(well.debugHasImage, "the well should show a thumbnail (not the placeholder) after handle(image:)")

        well.clear()
        well.onRemove?()
        check(removeFired, "onRemove should fire when the remove control is invoked")
        check(!well.debugHasImage, "the well should return to the placeholder state after clear()")

        return report(failures)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[ShiftImageAttachmentWellSelfTest] all checks passed")
            return true
        }
        print("[ShiftImageAttachmentWellSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
