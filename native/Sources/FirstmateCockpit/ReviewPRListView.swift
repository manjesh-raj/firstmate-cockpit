// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-review-page-stuck-loading-fix`: the per-forge PR list body
// behind `ReviewController`'s GitHub/Bitbucket/Other cards.
//
// **Root cause of the regression this fixes.** `fm/grandline-review-page-
// redesign` (#221) replaced each PR's flat pill-and-button row with a
// `HelmAccentRow` - several levels deeper of nested `NSStackView`s (card >
// row > textStack > titleRow, plus an accent bar, a badge, and a chip) than
// the plain row it replaced - while leaving every PR row a *permanent
// arranged subview of a plain `NSStackView`* (`githubStack`/`bitbucketStack`/
// `otherStack`), exactly the "an NSStackView with hundreds of arranged
// subviews blows up far faster than the row count" pathology this codebase
// has already hit and fixed at least three times before: the Diff tool's
// ~13.6-second blowup at ~340 rows (`fm/cockpit-tools-yaml-quotes-diff-perf`,
// `DiffResultView.swift`'s header), Block View's ~102-second blowup at 400
// blocks (`BlockView.swift`'s header), and the Tools-page resize-handler
// regression. #221's own verification used a small synthetic PR list (per
// its PR description), so it never exercised this at the captain's real
// open-PR count - the exact scale that first surfaces this pathology in
// every one of its prior occurrences here. `render()`'s final
// `view.layoutSubtreeIfNeeded()` is what pays that cost, synchronously, on
// the main thread: the `isHidden` flags that hide the loading skeleton and
// reveal the forge cards are flipped *before* that call (see
// `ReviewController.render`), so the screen visibly stays on the last frame
// it painted - the loading spinner - for as long as that Auto Layout resolve
// takes, which is why the captain's real, populated app showed "stuck
// forever on Loading" instead of a merely slow render.
//
// The fix is the same one already applied in every prior instance: a
// single-column, view-based `NSTableView`, demand-driven so
// `tableView(_:viewFor:row:)` only runs for rows actually on screen (plus a
// small buffer) regardless of the real PR count. Unlike `BlockContainerView`
// (multi-line, collapsible rows, needing `usesAutomaticRowHeights`), a PR
// row's title never wraps (`HelmAccentRow.Content.titleWraps` stays `false`,
// matching #221's own row) and its chip is a fixed-height pill, so every row
// is a fixed height - `DiffResultView`/`HostsListSection`'s simpler
// "fixed `rowHeight`" convention, not automatic measurement.
//
// This view owns no internal scroller: `ReviewController`'s page is already
// one big outer `NSScrollView` (see `ReviewController.loadView`), so each
// forge's table is sized to its own full content height (`recomputeHeight`)
// and left for that outer scroll view to carry, exactly like the plain
// `NSStackView` it replaces did.

import AppKit

/// One PR row: a `HelmAccentRow` (chip below body) with a persistent
/// Review + Merge action pair, reused across table rows via
/// `NSTableView.makeView(withIdentifier:owner:)` - `configure(pr:...)`
/// rebinds a dequeued instance to a different `MergedPR` rather than
/// rebuilding the row's view tree, matching `BlockRowView`/`DiffRowView`'s
/// established reuse shape.
private final class ReviewPRRowCellView: NSView {
    private let accentRow: HelmAccentRow
    private let reviewButton = HelmButton(title: "Review", variant: .secondary, size: .small)
    private let mergeButton = HelmButton(title: "Merge", variant: .primary, size: .small)

    override init(frame frameRect: NSRect) {
        let actionsRow = NSStackView(views: [reviewButton, mergeButton])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 6
        // The reused-row-with-toggling-button-visibility gotcha
        // (`HostsListRecordView`'s own `actions` stack, `HostsListSection.
        // swift`, is the reference fix): unlike the old per-render-fresh
        // `prRowView`, whose `actionsRow` only ever contained the buttons
        // that should show, this cell's `reviewButton`/`mergeButton` are
        // built once and REUSED across many different `configure(pr:...)`
        // calls as the table dequeues this row for different PRs -
        // `mergeButton.isHidden` toggles instead of the button being added/
        // omitted. Left at the default `.gravityAreas` distribution with no
        // explicit hugging on the buttons themselves, AGENTS.md gotcha (10)
        // applies exactly as documented: "leftover width is resolved by Auto
        // Layout's own tie-breaking - which can drift between runs/rows
        // depending on transient sibling content... even with no code
        // change" - here, whether the *previous* row this cell displayed had
        // Merge visible. `HelmAccentRow.buildLayout`'s stack-level hugging
        // on `trailingAccessory` only stops the OUTER row from stretching
        // this whole stack wider than its own fitting size - it says nothing
        // about how *this* stack distributes width among its own children,
        // which is the actual site of the regression: `reviewButton`
        // stretching to fill the row while `mergeButton` (though genuinely
        // `isHidden = false`) gets squeezed to unusably little space.
        actionsRow.distribution = .fill
        actionsRow.setHuggingPriority(.required, for: .horizontal)
        actionsRow.setClippingResistancePriority(.required, for: .horizontal)
        for b in [reviewButton, mergeButton] {
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // Status pill moved from under the title (`.belowBody`) into the
        // row's own trailing area (`.trailing`) per captain follow-up on
        // #229's icon-only badge: the text pill already carries the status
        // (colour + label, e.g. "Ready to merge"/"No checks"/"Checks
        // running") and duplicating that as a separate icon-only badge next
        // to it added nothing - so #229's `statusBadge` (`IconTileView`) is
        // gone outright rather than kept alongside the pill. `HelmAccentRow`
        // already places a `.trailing` chip immediately before
        // `trailingAccessory` in the same horizontal row (`buildLayout`'s
        // `rowViews` order: text column, chip, trailingAccessory) - which is
        // exactly the "status pill, then Review, then Merge" left-to-right
        // order this task asked for, so no new layout code was needed here.
        accentRow = HelmAccentRow(chipPlacement: .trailing, trailingAccessory: actionsRow, hover: false)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        accentRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentRow)
        NSLayoutConstraint.activate([
            accentRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentRow.topAnchor.constraint(equalTo: topAnchor),
            accentRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Bound once, right after the cell is created (never on every reuse) -
    /// `target` is always the same `ReviewController` instance regardless of
    /// which row this cell currently displays.
    func wireActions(target: AnyObject, reviewAction: Selector, mergeAction: Selector) {
        reviewButton.target = target
        reviewButton.action = reviewAction
        mergeButton.target = target
        mergeButton.action = mergeAction
    }

    /// Identical row content/gating to `fm/grandline-review-page-redesign`
    /// (#221) and `fm/grandline-review-page-merge-checks-fix` (#226) - only
    /// *how* it's rendered changed, not what it shows: `reviewButton` always
    /// shows; `mergeButton` only shows for a PR that is both genuinely ready
    /// (`pr.checks == "green"`, #226's fix) and actually mergeable through
    /// this action (`pr.taskID != nil`) - never revert this back to
    /// `pr.source == "work"` alone.
    func configure(pr: MergedPR, checksVisuals: (String) -> (tint: HelmTint, chipLabel: String), theme: HelmTheme) {
        let visuals = checksVisuals(pr.checks)

        var kickerParts: [String] = []
        if !pr.repo.isEmpty { kickerParts.append(pr.repo) }
        kickerParts.append(pr.number != nil ? "PR #\(pr.number!)" : "PR")
        let heading = pr.title.isEmpty ? (pr.number != nil ? "PR #\(pr.number!)" : "PR") : pr.title

        reviewButton.identifier = NSUserInterfaceItemIdentifier(pr.url)

        if pr.checks == "green", let taskID = pr.taskID {
            mergeButton.isHidden = false
            mergeButton.identifier = NSUserInterfaceItemIdentifier("\(taskID)\u{0}\(pr.url)")
        } else {
            // A hidden arranged subview of an `NSStackView` drops out of that
            // stack's layout entirely (this app's own established gotcha),
            // so a Review-only row correctly renders narrower rather than
            // leaving a gap where Merge would have been.
            mergeButton.isHidden = true
        }

        accentRow.configure(HelmAccentRow.Content(
            tint: visuals.tint,
            kicker: kickerParts.joined(separator: " \u{00B7} "),
            title: heading,
            badgeSymbol: "arrow.triangle.pull",
            chipText: visuals.chipLabel
        ), theme: theme)
    }

    // MARK: Probe / self-test surface

    /// Real, already-laid-out button geometry - see
    /// `ReviewPRListView.debugRowButtonState(at:)`, which is what a self-test
    /// actually calls (this type is `private` to this file).
    var debugReviewButtonFrame: NSRect { reviewButton.frame }
    var debugMergeButtonFrame: NSRect { mergeButton.frame }
    var debugMergeButtonHidden: Bool { mergeButton.isHidden }
}

/// The demand-driven replacement for a plain `NSStackView` of `HelmAccentRow`
/// PR cards - see this file's header for why. One instance per forge card
/// (GitHub / Bitbucket / Other).
final class ReviewPRListView: NSView {

    /// Every row is a fixed height - see this file's header for why
    /// `usesAutomaticRowHeights` isn't needed here the way it is for
    /// `BlockContainerView`'s variable-height rows.
    static let rowHeight: CGFloat = 92
    static let rowSpacing: CGFloat = 8
    static let emptyRowHeight: CGFloat = 140

    let tableView = NSTableView()

    private var prs: [MergedPR] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private let emptyTitle: String
    private let emptyBody: String
    private let checksVisuals: (String) -> (tint: HelmTint, chipLabel: String)
    private weak var actionTarget: AnyObject?
    private let reviewAction: Selector
    private let mergeAction: Selector
    private var tableHeight: NSLayoutConstraint!

    private static let columnID = NSUserInterfaceItemIdentifier("reviewPRListColumn")
    private static let rowViewID = NSUserInterfaceItemIdentifier("reviewPRListRow")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("reviewPRListEmpty")

    init(emptyTitle: String, emptyBody: String,
         actionTarget: AnyObject, reviewAction: Selector, mergeAction: Selector,
         checksVisuals: @escaping (String) -> (tint: HelmTint, chipLabel: String)) {
        self.emptyTitle = emptyTitle
        self.emptyBody = emptyBody
        self.actionTarget = actionTarget
        self.reviewAction = reviewAction
        self.mergeAction = mergeAction
        self.checksVisuals = checksVisuals
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        tableView.rowHeight = Self.rowHeight
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tableView)
        let height = tableView.heightAnchor.constraint(equalToConstant: Self.emptyRowHeight)
        tableHeight = height
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
    }

    /// Replaces `ReviewController.rebuildRows` - new PR data, re-measured
    /// height, reloaded rows. `reloadData()` on a view-based table only
    /// actually reconstructs/re-measures rows currently on screen (plus a
    /// small buffer), never the whole list - the same "cheap at real volume"
    /// property `BlockContainerView.render`'s doc comment already relies on.
    func setPRs(_ prs: [MergedPR], theme: HelmTheme) {
        self.prs = prs
        self.theme = theme
        recomputeHeight()
        tableView.reloadData()
    }

    /// A theme change re-styles already-visible rows; it doesn't change what
    /// PRs are shown, so this only reloads (never recomputes height).
    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }

    private func recomputeHeight() {
        if prs.isEmpty {
            tableHeight.constant = Self.emptyRowHeight
        } else {
            let n = CGFloat(prs.count)
            tableHeight.constant = n * Self.rowHeight + max(0, n - 1) * Self.rowSpacing
        }
    }

    // MARK: Probe / self-test surface

    /// The real PR count currently backing this list (not the table's own
    /// `numberOfRows`, which reports `1` for the empty-state placeholder row).
    var debugRowCount: Int { prs.count }
    var debugTableHeight: CGFloat { tableHeight.constant }

    /// Forces the real, already-dequeued/laid-out cell view at `row` and
    /// returns its two action buttons' real frames plus whether Merge is
    /// hidden - `ReviewPRRowCellView` is `private` to this file, so this is
    /// the seam `ReviewPRRowButtonLayoutSelfTest.swift` uses to check the
    /// row-width/button-visibility contract without that type leaking out.
    /// `makeIfNecessary: true` guarantees a real view even for a row that
    /// hasn't been scrolled into view yet in a headless test window.
    func debugRowButtonState(at row: Int) -> (reviewFrame: NSRect, mergeFrame: NSRect, mergeHidden: Bool)? {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ReviewPRRowCellView else {
            return nil
        }
        return (cell.debugReviewButtonFrame, cell.debugMergeButtonFrame, cell.debugMergeButtonHidden)
    }
}

extension ReviewPRListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { prs.isEmpty ? 1 : prs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !prs.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "checkmark.seal", title: emptyTitle, body: emptyBody,
                                           size: .standard, boxed: true)
                    v.identifier = Self.emptyViewID
                    return v
                }()
            empty.applyTheme(theme)
            return empty
        }

        let cell = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? ReviewPRRowCellView)
            ?? {
                let v = ReviewPRRowCellView()
                v.identifier = Self.rowViewID
                if let actionTarget {
                    v.wireActions(target: actionTarget, reviewAction: reviewAction, mergeAction: mergeAction)
                }
                return v
            }()
        cell.configure(pr: prs[row], checksVisuals: checksVisuals, theme: theme)
        return cell
    }
}
