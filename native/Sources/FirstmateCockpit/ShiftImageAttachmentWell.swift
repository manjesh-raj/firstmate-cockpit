// Manjesh Grand Line - native macOS app.
//
// The task editor sheet's image-attachment control (grandline-shift-task-
// image-attachments) - a single well supporting all three ways a captain can
// attach an image: a file picker button (wired by the owning controller,
// not this view), dragging a file onto the well, and pasting an image
// directly from the clipboard (the most relevant path for a captain who
// just took a screenshot with something like `⌘⇧⌃4`). All three funnel into
// the same `handle(image:)` -> `onImageChosen` path, so there is exactly one
// "this is now the attachment" code path regardless of how the image
// arrived.
//
// Deliberately one attachment at a time (this pass's scope, per the task
// brief) - there is no gallery, just a placeholder state and a
// thumbnail-plus-remove state.

import AppKit

final class ShiftImageAttachmentWell: NSView {
    /// Fired with already-normalized (downscaled, PNG-encoded) image data -
    /// see `Self.normalizedPNGData`. The caller never has to re-process
    /// what's handed back here.
    var onImageChosen: ((Data) -> Void)?
    var onRemove: (() -> Void)?

    private let placeholderIcon = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: "Drop an image, paste, or choose a file")
    private let thumbnailView = NSImageView()
    private let removeButton = NSButton()
    private var hasImage = false
    private var isDropTargeted = false {
        didSet { needsDisplay = true }
    }

    static let wellHeight: CGFloat = 96

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.wellHeight).isActive = true

        placeholderIcon.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)
        placeholderIcon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = .systemFont(ofSize: 11)
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        let placeholderStack = NSStackView(views: [placeholderIcon, placeholderLabel])
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 6
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderStack)

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 6
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.isHidden = true
        addSubview(thumbnailView)

        removeButton.title = ""
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove image")
        removeButton.isBordered = false
        removeButton.imageScaling = .scaleProportionallyDown
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.isHidden = true
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            placeholderStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            placeholderStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            thumbnailView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            thumbnailView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            removeButton.widthAnchor.constraint(equalToConstant: 18),
            removeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        registerForDraggedTypes([.fileURL, .tiff, .png])
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Public state

    /// Exposed only for `ShiftImageAttachmentWellSelfTest` to confirm the
    /// well's visible state without a real window to inspect layer/isHidden
    /// state on - not read by any production code.
    var debugHasImage: Bool { hasImage }

    /// Shows a real thumbnail for `data` (from an existing on-disk
    /// attachment when the editor opens for an existing task, or after a
    /// fresh pick/drop/paste in this same session) without re-notifying
    /// `onImageChosen` - that closure only fires for a *new* captain
    /// choice, never for the initial reflect-existing-state call.
    func showExisting(data: Data) {
        guard let image = NSImage(data: data) else { return }
        showThumbnail(image)
    }

    func clear() {
        hasImage = false
        thumbnailView.isHidden = true
        thumbnailView.image = nil
        removeButton.isHidden = true
        placeholderIcon.isHidden = false
        placeholderLabel.isHidden = false
    }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(isDropTargeted ? 0.9 : 0.5).cgColor
        layer?.borderWidth = isDropTargeted ? 2 : 1
        placeholderIcon.contentTintColor = HelmTheme.mutedInk(theme)
        placeholderLabel.textColor = HelmTheme.mutedInk(theme)
    }

    // MARK: Image intake (shared by picker / drop / paste)

    private func showThumbnail(_ image: NSImage) {
        hasImage = true
        thumbnailView.image = image
        thumbnailView.isHidden = false
        removeButton.isHidden = false
        placeholderIcon.isHidden = true
        placeholderLabel.isHidden = true
    }

    /// Handles a freshly chosen/dropped/pasted `NSImage` - normalizes it and
    /// shows the real thumbnail immediately, then reports the normalized
    /// bytes to the caller. A source image that fails to normalize (e.g. a
    /// zero-size image) is silently ignored rather than clearing whatever
    /// attachment was already showing.
    func handle(image: NSImage) {
        guard let data = Self.normalizedPNGData(from: image) else { return }
        guard let normalized = NSImage(data: data) else { return }
        showThumbnail(normalized)
        onImageChosen?(data)
    }

    @objc private func removeClicked() {
        clear()
        onRemove?()
    }

    // MARK: Downscale + encode

    /// Downscales `image` so its longest edge is at most `maxDimension`
    /// (never upscales a smaller image) and re-encodes it as PNG. This is
    /// the one place every intake path (file picker, drag-drop, clipboard
    /// paste) funnels through, so a full-resolution Retina screenshot -
    /// which can otherwise run several MB - never lands in the git-synced
    /// repo at its original size. 1600px keeps a screenshot's text legible
    /// while keeping typical output in the low hundreds of KB to low
    /// single-digit MB range (see the PR description for measured sizes).
    static func normalizedPNGData(from image: NSImage, maxDimension: CGFloat = 1600) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let targetWidth = max(1, Int((size.width * scale).rounded()))
        let targetHeight = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetWidth, pixelsHigh: targetHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: .zero, operation: .copy, fraction: 1.0
        )
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: First responder / paste

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// Standard `NSResponder` paste action - reached via the responder chain
    /// whenever this view is first responder and the captain presses
    /// `⌘V` (or uses Edit > Paste), which is the direct "just took a
    /// screenshot" flow the task brief calls out. Reads through the same
    /// `Self.image(fromPasteboard:)` helper `performDragOperation` uses
    /// below, so a screenshot on the general pasteboard (raw image bytes,
    /// no file on disk) and a copied Finder file (a file URL) both work
    /// through one path.
    @objc func paste(_ sender: Any?) {
        guard let image = Self.image(fromPasteboard: .general) else {
            NSSound.beep()
            return
        }
        handle(image: image)
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canRead(sender.draggingPasteboard) else { return [] }
        isDropTargeted = true
        applyTheme(ThemeManager.shared.theme)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
        applyTheme(ThemeManager.shared.theme)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTargeted = false
        applyTheme(ThemeManager.shared.theme)
    }

    private func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = Self.image(fromPasteboard: sender.draggingPasteboard) else { return false }
        handle(image: image)
        return true
    }

    /// Tries a dropped/pasted file URL first (a Finder drag, or a copied
    /// file), then a raw image on the pasteboard (a clipboard screenshot,
    /// which has no backing file at all) - the one place both drag-drop and
    /// clipboard paste read a pasteboard, so there is exactly one "how do we
    /// get an image out of this pasteboard" behavior to reason about and
    /// test, not two independent copies of the same logic.
    static func image(fromPasteboard pasteboard: NSPasteboard) -> NSImage? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url) {
            return image
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            return image
        }
        return nil
    }
}
