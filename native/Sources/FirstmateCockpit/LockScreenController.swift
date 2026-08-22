// Manjesh Grand Line - native macOS app.
//
// The app-level lock screen (fm/grandline-app-lock): a sailing scene per the
// captain-approved design - gradient sky, a bobbing sailboat, a drifting
// wave, and a password form. Originally a fixed, non-Helm-themed dark night
// scene by deliberate choice ("a distinct gate, not another themed page");
// `fm/grandline-lockscreen-theme` reversed that per later captain ask - it
// now follows the app's active Helm theme's light/dark `mode` like every
// other view (see `ThemeManager.swift`'s header checklist), with a genuine
// second "daytime sailing" palette (sun instead of stars, a lighter sky/wave,
// dark ink/boat tint for contrast) rather than a dimmed copy of the dark one.
// Only the palette follows the theme - the password-check logic, timers, and
// avatar/logout flow this screen sits in front of are unaffected.
//
// Ordinary AppKit + Core Animation only (`CAGradientLayer`/`CAShapeLayer`/
// `CABasicAnimation`) - the first use of any of these three in this codebase,
// confirmed buildable natively during design review rather than assumed.
//
// This controller only collects a password and reports it via `onAttempt` -
// it knows nothing about Automic Vault or `av`; `AppShellController` wires
// `onAttempt` to `VaultSource.verifyAppPassword` on a background queue (see
// its own header) so a slow/approval-gated `av inject` call never blocks the
// main thread or this view.
import AppKit

final class LockScreenController: NSViewController {

    enum ContentState {
        case locked(subtitle: String)
        case noPasswordConfigured
        /// `av` itself isn't installed on this Mac at all - distinct from
        /// `.noPasswordConfigured` (av installed, no secret saved yet): the
        /// "run av save..." instruction is actively wrong here since there's
        /// no `av` to run. Shows a real "Install Automic Vault" action
        /// instead (`onInstallAutomicVault`).
        case avUnavailable
        /// `av` is on PATH but its background approval service (the
        /// "Automic Vault" menu-bar app) isn't reachable yet - the password
        /// secret may already exist, `av` just can't confirm it right now.
        /// `AppShellController` retries the underlying check on a timer
        /// while this state is showing; this screen just displays it.
        case serviceNotRunning
        /// `av list` failed (or timed out) for a reason that isn't the
        /// specific `.serviceNotRunning` marker text - e.g. the approval
        /// helper being transiently unresponsive right after a long
        /// sleep/wake (`fm/grandline-vault-wake-recheck-fix`, live-
        /// confirmed: a suspended helper process makes `av list` hang
        /// indefinitely). The password secret may well already exist here
        /// too; `AppShellController` retries on the same cadence as
        /// `.serviceNotRunning` - this screen just displays it.
        case transientFailure
    }

    /// `(typed password, completion(success))` - the caller verifies on a
    /// background queue and calls `completion` back on the main thread.
    var onAttempt: ((String, @escaping (Bool) -> Void) -> Void)?

    /// Fired when the captain clicks "Install Automic Vault" on the
    /// `.avUnavailable` state - the caller runs the real Homebrew-cask
    /// install (`VaultSource.updateInstall()`, the same mechanism the
    /// Updates/Vault pages already use for this catalog entry) on a
    /// background queue and calls back with the outcome; this controller
    /// only shows install progress/result text, it knows nothing about
    /// `UpdatesSource`/`DependencyCatalog`.
    var onInstallAutomicVault: ((@escaping (Bool, String) -> Void) -> Void)?

    /// Fired once the success animation (below) has actually finished
    /// playing - `AppShellController` hides the overlay and records the
    /// unlock from here, not from `onAttempt`'s own completion, so the
    /// flourish plays fully visible instead of running on a view that's
    /// already been hidden out from under it.
    var onUnlockAnimationFinished: (() -> Void)?

    private let boatImageView = NSImageView()
    private let waveLayer = CAShapeLayer()
    private var waveWidth: CGFloat = 0

    private let titleLabel = NSTextField(labelWithString: "Welcome back, Captain")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let passwordField = NSSecureTextField()
    private let fieldContainer = NSView()
    private let lockIcon = NSImageView()
    private let unlockButton = NSButton(title: "Unlock", target: nil, action: nil)
    private let formStack = NSStackView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    // `.avUnavailable`-only UI: a distinct message plus a real install
    // action - see `onInstallAutomicVault` above.
    private let avMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install Automic Vault", target: nil, action: nil)
    private let installStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let avUnavailableStack = NSStackView()

    // Theme-following scene elements. `skyLayer` is `root.layer` itself;
    // `starLayers` (night) and `sunLayer` (day) are both built once up front
    // and toggled via `isHidden` in `applyTheme` rather than swapped in/out,
    // so there is never a moment with neither (or both) attached.
    private let skyLayer = CAGradientLayer()
    private var starLayers: [CALayer] = []
    private let sunLayer = CALayer()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        root.wantsLayer = true
        view = root

        skyLayer.locations = [0, 0.55, 1]
        skyLayer.startPoint = CGPoint(x: 0.5, y: 1)
        skyLayer.endPoint = CGPoint(x: 0.5, y: 0)
        root.layer = skyLayer

        // A handful of small, fixed-position stars (night) - deterministic
        // rather than randomized so this view renders identically on every
        // launch and every live-verification probe. Always built, hidden in
        // day mode via `applyTheme` rather than added/removed, so there's
        // never a frame where the sky has neither stars nor a sun.
        let starPositions: [(CGFloat, CGFloat, CGFloat)] = [
            (0.08, 0.85, 1.4), (0.15, 0.72, 1.0), (0.22, 0.90, 1.6), (0.30, 0.65, 1.1),
            (0.38, 0.88, 1.3), (0.46, 0.70, 1.0), (0.55, 0.92, 1.5), (0.63, 0.78, 1.1),
            (0.70, 0.60, 1.3), (0.78, 0.87, 1.0), (0.85, 0.73, 1.6), (0.92, 0.83, 1.2),
            (0.12, 0.55, 1.0), (0.35, 0.45, 1.2), (0.58, 0.50, 1.0), (0.80, 0.48, 1.3),
        ]
        for (xFrac, yFrac, radius) in starPositions {
            let star = CALayer()
            star.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            star.cornerRadius = radius / 2
            star.frame = NSRect(x: 0, y: 0, width: radius, height: radius)
            star.setValue(xFrac, forKey: "xFrac")
            star.setValue(yFrac, forKey: "yFrac")
            root.layer?.addSublayer(star)
            starLayers.append(star)
        }

        // Sun (day) - same xFrac/yFrac positioning convention as the stars
        // above (`layoutSceneLayers` repositions any sublayer carrying those
        // keys, star or sun alike), a warm glowing disc via a soft shadow
        // rather than a plain flat circle.
        sunLayer.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.45, alpha: 1).cgColor
        sunLayer.cornerRadius = 44
        sunLayer.frame = NSRect(x: 0, y: 0, width: 88, height: 88)
        sunLayer.shadowColor = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.35, alpha: 1).cgColor
        sunLayer.shadowOpacity = 0.75
        sunLayer.shadowRadius = 28
        sunLayer.shadowOffset = .zero
        sunLayer.setValue(CGFloat(0.78), forKey: "xFrac")
        sunLayer.setValue(CGFloat(0.82), forKey: "yFrac")
        root.layer?.addSublayer(sunLayer)

        // Wave: a simple sine-ish shape near the bottom, drawn twice as wide
        // as the view and drifted horizontally in a seamless loop.
        root.layer?.addSublayer(waveLayer)

        // Sailboat mark - the same "sailboat" SF Symbol used for the rail's
        // own mark and the Tasks icon/menu-bar item. A real `NSImageView`
        // laid out as part of `contentStack` below (not a freeform `CALayer`
        // positioned by a fixed fraction of the window's height, which is
        // this file's first draft) - a captain screenshot on a real, much
        // taller window than the 1220x720 default caught the fraction-based
        // position landing squarely on top of the password field/Unlock
        // button, since a height-fraction and an Auto-Layout-centered stack
        // are two independent layout systems with no reason to agree at
        // every window size. Living inside the stack means Auto Layout
        // keeps it correctly spaced above the title at any window size; it's
        // still layer-animatable (`wantsLayer = true` + `.layer?.add` in
        // `startAnimationsIfNeeded`), so the bob animation is unaffected.
        let config = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular)
        boatImageView.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Manjesh Grand Line")?
            .withSymbolConfiguration(config)
        boatImageView.wantsLayer = true
        boatImageView.translatesAutoresizingMaskIntoConstraints = false
        boatImageView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        boatImageView.heightAnchor.constraint(equalToConstant: 72).isActive = true

        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // A glassy, translucent field matching the scene rather than the
        // stock white/square-cornered/blue-focus-ring system text field -
        // per live captain feedback that the first draft's plain form
        // clashed with the rest of the scene. `focusRingType = .none` +
        // `isBordered = false` hand all the drawing to this field's own
        // layer (rounded corners, a soft border, translucent fill);
        // `placeholderAttributedString` is needed because the plain
        // `placeholderString` setter always renders in the system's default
        // placeholder gray, which doesn't track this view's own palette.
        // Actual colors (both here and below) are set by `applyTheme`, which
        // `loadView` calls via `ThemeManager.shared.observe` at the end of
        // this method - this is just static/structural setup.
        passwordField.font = .systemFont(ofSize: 17)
        passwordField.isBordered = false
        passwordField.drawsBackground = false
        passwordField.focusRingType = .none
        passwordField.target = self
        passwordField.action = #selector(submitTapped)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        if let cell = passwordField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
        }

        // A small lock glyph inside the field, left of the text - the kind
        // of detail that made the first plain-fill draft read as unfinished.
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        lockIcon.translatesAutoresizingMaskIntoConstraints = false

        fieldContainer.wantsLayer = true
        fieldContainer.layer?.cornerRadius = 10
        fieldContainer.layer?.borderWidth = 1
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.heightAnchor.constraint(equalToConstant: 44).isActive = true
        fieldContainer.addSubview(lockIcon)
        fieldContainer.addSubview(passwordField)
        NSLayoutConstraint.activate([
            lockIcon.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 14),
            lockIcon.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 14),

            // Centered on the container's Y, not top/bottom-pinned to the
            // container's full height - a plain `NSTextFieldCell` doesn't
            // vertically center its text within a frame taller than its own
            // natural line height (it stays top-aligned), which is why the
            // first draft's placeholder text sat visibly above center inside
            // its 40pt-tall field. Letting the field keep its own natural,
            // font-driven height and centering *that* inside the taller pill
            // sidesteps the cell's own vertical layout entirely.
            passwordField.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 8),
            passwordField.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -14),
            passwordField.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
        ])

        // A real filled pill, not the stock `.rounded` bezel (a light-gray
        // system button that read as an afterthought against the scene) -
        // `isBordered = false` + a layer fill hands the whole look to this
        // button, with `attributedTitle` carrying the white bold label since
        // a borderless `NSButton`'s plain `title` renders in the system's
        // default (dark) label color regardless of `contentTintColor`.
        unlockButton.isBordered = false
        unlockButton.wantsLayer = true
        unlockButton.layer?.cornerRadius = 10
        unlockButton.layer?.backgroundColor = NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.92, alpha: 1).cgColor
        unlockButton.attributedTitle = NSAttributedString(
            string: "Unlock",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            ]
        )
        unlockButton.target = self
        unlockButton.action = #selector(submitTapped)
        unlockButton.keyEquivalent = "\r"
        unlockButton.translatesAutoresizingMaskIntoConstraints = false
        unlockButton.widthAnchor.constraint(equalToConstant: 280).isActive = true
        unlockButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        formStack.orientation = .vertical
        formStack.alignment = .centerX
        formStack.spacing = 12
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(fieldContainer)
        formStack.addArrangedSubview(unlockButton)

        messageLabel.font = .systemFont(ofSize: 13.5)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 4
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isHidden = true

        avMessageLabel.font = .systemFont(ofSize: 13.5)
        avMessageLabel.alignment = .center
        avMessageLabel.maximumNumberOfLines = 5
        avMessageLabel.translatesAutoresizingMaskIntoConstraints = false

        // Styled like `unlockButton` above (a filled pill, not the stock
        // bezel) so it reads as a real primary action on this screen rather
        // than an afterthought.
        installButton.isBordered = false
        installButton.wantsLayer = true
        installButton.layer?.cornerRadius = 10
        installButton.layer?.backgroundColor = NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.92, alpha: 1).cgColor
        installButton.attributedTitle = NSAttributedString(
            string: "Install Automic Vault",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            ]
        )
        installButton.target = self
        installButton.action = #selector(installTapped)
        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.widthAnchor.constraint(equalToConstant: 280).isActive = true
        installButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        installStatusLabel.font = .systemFont(ofSize: 12.5)
        installStatusLabel.alignment = .center
        installStatusLabel.maximumNumberOfLines = 4
        installStatusLabel.lineBreakMode = .byWordWrapping
        installStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        avUnavailableStack.orientation = .vertical
        avUnavailableStack.alignment = .centerX
        avUnavailableStack.spacing = 12
        avUnavailableStack.translatesAutoresizingMaskIntoConstraints = false
        avUnavailableStack.addArrangedSubview(avMessageLabel)
        avUnavailableStack.addArrangedSubview(installButton)
        avUnavailableStack.addArrangedSubview(installStatusLabel)
        avUnavailableStack.isHidden = true

        let contentStack = NSStackView(views: [boatImageView, titleLabel, subtitleLabel, formStack, messageLabel, avUnavailableStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 18
        contentStack.setCustomSpacing(24, after: boatImageView)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 40),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            messageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            avMessageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            installStatusLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        // Follow the app's active Helm theme's light/dark mode, live - see
        // `ThemeManager.swift`'s header checklist. `applyTheme` is called
        // immediately here (current theme) and again on every later change,
        // including while this screen is on screen and locked; this
        // controller is a permanent, app-lifetime singleton owned by
        // `AppShellController`, so the returned token can be discarded per
        // that file's own convention for such observers.
        ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }
    }

    /// Repaints every themed element of the scene for `theme.mode` - a
    /// genuine second "daytime sailing" palette (sun, lighter sky/wave, dark
    /// ink/boat tint for contrast), not a dimmed copy of the night one. Does
    /// not force `view.appearance`: every color here is drawn explicitly
    /// (layer fills, `NSAttributedString` foregrounds) rather than via a
    /// system-semantic color, so there's nothing here that would resolve
    /// against the OS's own light/dark setting regardless.
    private func applyTheme(_ theme: HelmTheme) {
        let isDark = theme.mode == .dark

        let skyColors: [NSColor]
        let waveColor: NSColor
        let boatTint: NSColor
        let inkPrimary: NSColor
        let inkSecondary: NSColor
        let inkTertiary: NSColor
        let fieldFill: NSColor
        let fieldBorder: NSColor
        let placeholderColor: NSColor
        let lockTint: NSColor

        if isDark {
            skyColors = [
                NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.11, alpha: 1),
                NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.22, alpha: 1),
                NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.32, alpha: 1),
            ]
            waveColor = NSColor(calibratedRed: 0.09, green: 0.22, blue: 0.38, alpha: 0.9)
            boatTint = .white
            inkPrimary = .white
            inkSecondary = NSColor.white.withAlphaComponent(0.75)
            inkTertiary = NSColor.white.withAlphaComponent(0.85)
            fieldFill = NSColor.white.withAlphaComponent(0.10)
            fieldBorder = NSColor.white.withAlphaComponent(0.30)
            placeholderColor = NSColor.white.withAlphaComponent(0.45)
            lockTint = NSColor.white.withAlphaComponent(0.55)
        } else {
            // A daytime sailing scene, not a dimmed night one: a brighter
            // sky blue at the zenith fading to a pale, warm horizon; a
            // lighter turquoise wave; dark ink/boat/field chrome, since
            // white text and a translucent white pill both lose contrast
            // against a pale sky.
            skyColors = [
                NSColor(calibratedRed: 0.32, green: 0.58, blue: 0.86, alpha: 1),
                NSColor(calibratedRed: 0.58, green: 0.78, blue: 0.93, alpha: 1),
                NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.90, alpha: 1),
            ]
            waveColor = NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.62, alpha: 0.85)
            boatTint = NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.32, alpha: 1)
            inkPrimary = NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.20, alpha: 1)
            inkSecondary = inkPrimary.withAlphaComponent(0.68)
            inkTertiary = inkPrimary.withAlphaComponent(0.80)
            fieldFill = NSColor.black.withAlphaComponent(0.06)
            fieldBorder = NSColor.black.withAlphaComponent(0.18)
            placeholderColor = inkPrimary.withAlphaComponent(0.40)
            lockTint = inkPrimary.withAlphaComponent(0.55)
        }

        skyLayer.colors = skyColors.map(\.cgColor)
        waveLayer.fillColor = waveColor.cgColor
        boatImageView.contentTintColor = boatTint
        starLayers.forEach { $0.isHidden = !isDark }
        sunLayer.isHidden = isDark

        titleLabel.textColor = inkPrimary
        subtitleLabel.textColor = inkSecondary
        messageLabel.textColor = inkTertiary
        avMessageLabel.textColor = inkTertiary
        installStatusLabel.textColor = inkSecondary

        fieldContainer.layer?.backgroundColor = fieldFill.cgColor
        fieldContainer.layer?.borderColor = fieldBorder.cgColor
        passwordField.textColor = inkPrimary
        passwordField.placeholderAttributedString = NSAttributedString(
            string: "Password",
            attributes: [
                .foregroundColor: placeholderColor,
                .font: NSFont.systemFont(ofSize: 17),
            ]
        )
        lockIcon.contentTintColor = lockTint
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSceneLayers()
    }

    private func layoutSceneLayers() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        for star in view.layer?.sublayers ?? [] where star.value(forKey: "xFrac") != nil {
            let xFrac = star.value(forKey: "xFrac") as? CGFloat ?? 0
            let yFrac = star.value(forKey: "yFrac") as? CGFloat ?? 0
            let size = star.bounds.width
            star.position = CGPoint(x: bounds.width * xFrac, y: bounds.height * yFrac)
            star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        }

        waveWidth = bounds.width * 2
        let waveHeight: CGFloat = 90
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        let segments = 8
        let segmentWidth = waveWidth / CGFloat(segments)
        for i in 0...segments {
            let x = CGFloat(i) * segmentWidth
            let y = (i % 2 == 0) ? waveHeight : waveHeight * 0.6
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: waveWidth, y: 0))
        path.closeSubpath()
        waveLayer.path = path
        waveLayer.bounds = CGRect(x: 0, y: 0, width: waveWidth, height: waveHeight)
        waveLayer.position = CGPoint(x: 0, y: 0)
        waveLayer.anchorPoint = CGPoint(x: 0, y: 0)

        startAnimationsIfNeeded()
    }

    private var animationsStarted = false
    private var reduceMotionObserver: Any?

    /// GL-16: the two animations below (the boat's bob and the wave's drift)
    /// loop forever, and this screen is *mandatory* - a captain who has turned
    /// on Reduce Motion cannot dismiss it or navigate away from it, so ignoring
    /// that setting here is worse than anywhere else in the app. Both are
    /// purely decorative: with them off the scene renders as a still
    /// illustration and every function of the screen (typing a password,
    /// submitting, reading the state text) is unchanged.
    ///
    /// The failure shake and the success sail-away are deliberately left
    /// alone: they are brief, non-looping, and the success one carries the
    /// `CATransaction` completion block that actually unlocks the app - a
    /// change there risks a state where the password is accepted and the
    /// overlay never lifts. Motion in the shared components (`HelmAccentRow`'s
    /// hover, etc.) already honours the setting.
    private static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func startAnimationsIfNeeded() {
        guard !animationsStarted, waveWidth > 0 else { return }
        animationsStarted = true

        // Observe live changes so toggling Reduce Motion while the lock screen
        // is up takes effect, rather than only on the next launch.
        if reduceMotionObserver == nil {
            reduceMotionObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.applyMotionPreference()
            }
        }

        guard !Self.prefersReducedMotion else { return }
        addLoopingAnimations()
    }

    /// Adds or removes the looping decoration to match the current setting.
    private func applyMotionPreference() {
        if Self.prefersReducedMotion {
            boatImageView.layer?.removeAnimation(forKey: "bob")
            waveLayer.removeAnimation(forKey: "drift")
        } else if animationsStarted, boatImageView.layer?.animation(forKey: "bob") == nil {
            addLoopingAnimations()
        }
    }

    private func addLoopingAnimations() {
        let bob = CAKeyframeAnimation(keyPath: "transform")
        var transforms: [CATransform3D] = []
        for step in 0...8 {
            let t = CGFloat(step) / 8
            let offset = sin(t * .pi * 2) * 6
            let rotation = sin(t * .pi * 2) * 0.03
            var transform = CATransform3DMakeTranslation(0, offset, 0)
            transform = CATransform3DRotate(transform, rotation, 0, 0, 1)
            transforms.append(transform)
        }
        bob.values = transforms
        bob.duration = 3.4
        bob.repeatCount = .infinity
        bob.calculationMode = .cubic
        boatImageView.layer?.add(bob, forKey: "bob")

        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = 0
        drift.toValue = -(waveWidth / 2)
        drift.duration = 14
        drift.repeatCount = .infinity
        drift.isRemovedOnCompletion = false
        drift.fillMode = .forwards
        waveLayer.add(drift, forKey: "drift")
    }

    deinit {
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
        }
    }

    // MARK: - Content

    func apply(_ state: ContentState) {
        switch state {
        case .locked(let subtitle):
            subtitleLabel.stringValue = subtitle
            formStack.isHidden = false
            messageLabel.isHidden = true
            avUnavailableStack.isHidden = true
            passwordField.stringValue = ""
            passwordField.isEnabled = true
            unlockButton.isEnabled = true
            // This same controller instance is reused for every lock, so a
            // previous success animation's boat position/opacity needs
            // resetting - otherwise the *next* lock screen would show a
            // half-faded, sailed-off boat instead of the normal scene.
            boatImageView.layer?.removeAnimation(forKey: "sailAway")
            boatImageView.layer?.removeAnimation(forKey: "fadeAway")
            boatImageView.layer?.opacity = 1
        case .noPasswordConfigured:
            subtitleLabel.stringValue = "No password is set yet"
            formStack.isHidden = true
            avUnavailableStack.isHidden = true
            messageLabel.isHidden = false
            // Vault-tab wording deliberately doesn't offer it as a first-setup
            // option here either - the Vault tab lives behind this same lock
            // screen, so it's only ever reachable to rotate an already-set
            // password, never to set the first one. See `setup-guide.md`.
            messageLabel.stringValue = "Run \u{201c}av save GRANDLINE_APP_PASSWORD\u{201d} in a terminal, or set it from Automic Vault's own app, then relaunch Manjesh Grand Line."
        case .avUnavailable:
            subtitleLabel.stringValue = "Automic Vault isn't installed"
            formStack.isHidden = true
            messageLabel.isHidden = true
            avUnavailableStack.isHidden = false
            avMessageLabel.stringValue = "Automic Vault isn't installed on this Mac. Install it below, then set a password with \u{201c}av save GRANDLINE_APP_PASSWORD\u{201d} (or Automic Vault's own app) and relaunch."
            installButton.isEnabled = true
            installStatusLabel.stringValue = ""
        case .serviceNotRunning:
            subtitleLabel.stringValue = "Starting Automic Vault"
            formStack.isHidden = true
            avUnavailableStack.isHidden = true
            messageLabel.isHidden = false
            messageLabel.stringValue = "Automic Vault's background service isn't running yet - starting it now. This should only take a moment."
        case .transientFailure:
            subtitleLabel.stringValue = "Checking Automic Vault"
            formStack.isHidden = true
            avUnavailableStack.isHidden = true
            messageLabel.isHidden = false
            messageLabel.stringValue = "Automic Vault didn't respond in time - retrying automatically. This should only take a moment."
        }
    }

    /// Focuses the password field - called every time the overlay becomes
    /// visible so a captain can start typing immediately with no extra
    /// click, matching how every other sheet/form in this app auto-focuses
    /// its first field.
    func focusPasswordField() {
        view.window?.makeFirstResponder(passwordField)
    }

    @objc private func submitTapped() {
        let typed = passwordField.stringValue
        guard !typed.isEmpty, let onAttempt else { return }
        passwordField.isEnabled = false
        unlockButton.isEnabled = false
        onAttempt(typed) { [weak self] success in
            guard let self else { return }
            if success {
                // Deliberately NOT re-enabling the field/button or hiding
                // the overlay here - `playUnlockSuccessAnimation` plays out
                // fully first, and `onUnlockAnimationFinished` (not this
                // callback) is what actually tells `AppShellController` to
                // hide the lock screen.
                self.playUnlockSuccessAnimation()
            } else {
                self.passwordField.isEnabled = true
                self.unlockButton.isEnabled = true
                self.passwordField.stringValue = ""
                self.playUnlockFailureAnimation()
                self.view.window?.makeFirstResponder(self.passwordField)
            }
        }
    }

    @objc private func installTapped() {
        guard let onInstallAutomicVault else { return }
        installButton.isEnabled = false
        installStatusLabel.stringValue = "Installing Automic Vault\u{2026}"
        onInstallAutomicVault { [weak self] success, message in
            guard let self else { return }
            self.installStatusLabel.stringValue = message
            // Leave the button disabled on success (the state itself will
            // move on to `.noPasswordConfigured`/`.serviceNotRunning` once
            // `AppShellController` re-checks); re-enable on failure so the
            // captain can retry without relaunching.
            self.installButton.isEnabled = !success
        }
    }

    /// A calmer alternative to a harsh red flash, per the approved design: a
    /// small horizontal shake on the password field's whole pill container,
    /// paired with a quick distressed rock on the boat itself (captain ask:
    /// a distinct animation for success vs. failure, not just the field).
    private func playUnlockFailureAnimation() {
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        let base = fieldContainer.layer?.position.x ?? 0
        shake.values = [base, base - 8, base + 8, base - 5, base + 5, base]
        shake.duration = 0.36
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fieldContainer.layer?.add(shake, forKey: "shake")

        let rock = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rock.values = [0, -0.09, 0.09, -0.05, 0.05, 0]
        rock.duration = 0.36
        rock.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        boatImageView.layer?.add(rock, forKey: "distress")
    }

    /// The success flourish: the boat sails off to the right and fades,
    /// as if departing now that the gate's open - a deliberately different
    /// shape of motion than the failure rock above, not just the same
    /// animation with different numbers. `onUnlockAnimationFinished` fires
    /// once this completes, which is what actually tells the app shell to
    /// hide the overlay (see `submitTapped`'s header comment on why that
    /// can't happen any earlier).
    private func playUnlockSuccessAnimation() {
        let duration = 0.55
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.onUnlockAnimationFinished?()
        }

        let sail = CABasicAnimation(keyPath: "position.x")
        let baseX = boatImageView.layer?.position.x ?? 0
        sail.fromValue = baseX
        sail.toValue = baseX + 90
        sail.duration = duration
        sail.timingFunction = CAMediaTimingFunction(name: .easeIn)
        sail.fillMode = .forwards
        sail.isRemovedOnCompletion = false
        boatImageView.layer?.add(sail, forKey: "sailAway")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        boatImageView.layer?.add(fade, forKey: "fadeAway")

        CATransaction.commit()
    }
}
