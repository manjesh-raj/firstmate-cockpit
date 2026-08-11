// Manjesh Grand Line - native macOS app.
//
// Turns an SRE Lead reply's raw markdown text into a small tree of
// `SRELeadMarkdownBlock`s that `SRELeadChatView` renders as real AppKit
// views (bold, inline code, bullet lists, fenced code blocks, and two
// specially-styled callout blocks) instead of one flat, unstyled label -
// see that file's header and the AGENTS.md "SRE Lead" bullet for why.
//
// Block/list structure and inline emphasis/code-span detection both come
// from Foundation's own `AttributedString(markdown:)` parser
// (`interpretedSyntax: .full`), not a hand-rolled markdown parser - it
// already understands paragraphs, unordered lists, and fenced code blocks,
// and tags every run with a `presentationIntent` (block structure) and
// `inlinePresentationIntent` (bold/code) we can read back directly.
// Bridging that straight to `NSAttributedString` (as SwiftUI's `Text` does
// internally) was tried first and rejected: the bridge only carries the
// semantic `NSInlinePresentationIntent` key, with no concrete font/color -
// AppKit has no built-in "render this intent" step the way SwiftUI does, so
// `SRELeadChatView` still has to map bold/code intents to concrete
// fonts/colors itself either way. What *is* hand-rolled here, because it is
// app-specific and no generic markdown parser could know about it, is
// grouping runs into blocks by their `presentationIntent` identity, and
// recognizing the two labeled callout paragraphs `SRELead.persona` asks the
// model for.
//
// The marker convention (must stay in sync with `SRELead.persona`): a
// callout is a paragraph whose very first inline run is bold text reading
// exactly "Finding:" or "Recommended next action:" - i.e. the model writes
// `**Finding:** ...` / `**Recommended next action:** ...` as the first
// paragraph of that block, with no blank line between the label and the
// rest of the sentence. Any other bold text is just inline emphasis, not a
// callout.

import Foundation

enum SRELeadCalloutKind: Equatable {
    case finding
    case recommendation

    var label: String {
        switch self {
        case .finding: return "Finding"
        case .recommendation: return "Recommended next action"
        }
    }
}

/// One inline run of text within a paragraph/list-item/callout body - at
/// most one of `bold`/`code` is meaningful at a time (the model's markdown
/// doesn't nest emphasis inside code spans in practice, and neither
/// `SRELead.persona` nor this parser needs to support that).
struct SRELeadInlineRun {
    let text: String
    let bold: Bool
    let code: Bool
}

enum SRELeadMarkdownBlock {
    case paragraph([SRELeadInlineRun])
    case bulletList([[SRELeadInlineRun]])
    case codeBlock(String)
    case callout(SRELeadCalloutKind, [SRELeadInlineRun])
}

enum SRELeadMarkdown {

    /// The exact bold-label prefixes `SRELead.persona` is instructed to use.
    /// Keep these in sync with the persona text - the whole point of a fixed
    /// convention is that this parser and that prompt agree on it.
    private static let findingLabel = "Finding:"
    private static let recommendationLabel = "Recommended next action:"

    private typealias RawRun = (text: String, bold: Bool, code: Bool)

    /// Which block a run belongs to. Consecutive runs sharing the same key
    /// are the same block; a change in key closes the previous block and
    /// opens a new one. List runs are keyed by the *list's* identity (not
    /// the item's) so multiple items stay in one `.bulletList` block - the
    /// item identity is tracked separately in `Group.itemRuns` so the block
    /// can be split back into per-item runs afterward.
    private enum GroupKey: Equatable {
        case paragraph(Int)
        case list(Int)
        case codeBlock(Int)
        case ungrouped
    }

    private final class Group {
        let key: GroupKey
        var runs: [RawRun] = []
        var itemOrder: [Int] = []
        var itemRuns: [Int: [RawRun]] = [:]
        init(key: GroupKey) { self.key = key }
    }

    static func parse(_ text: String) -> [SRELeadMarkdownBlock] {
        guard let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) else {
            return [.paragraph([SRELeadInlineRun(text: text, bold: false, code: false)])]
        }

        var groups: [Group] = []

        func appendRun(_ run: RawRun, key: GroupKey, itemIdentity: Int? = nil) {
            if groups.last?.key != key {
                groups.append(Group(key: key))
            }
            let group = groups[groups.count - 1]
            group.runs.append(run)
            if let itemIdentity {
                if group.itemRuns[itemIdentity] == nil {
                    group.itemOrder.append(itemIdentity)
                    group.itemRuns[itemIdentity] = []
                }
                group.itemRuns[itemIdentity]?.append(run)
            }
        }

        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            let bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
            let code = run.inlinePresentationIntent?.contains(.code) ?? false
            let value: RawRun = (text: piece, bold: bold, code: code)

            guard let intent = run.presentationIntent else {
                appendRun(value, key: .ungrouped)
                continue
            }

            var codeBlockIdentity: Int?
            var listIdentity: Int?
            var listItemIdentity: Int?
            var paragraphIdentity: Int?
            for component in intent.components {
                switch component.kind {
                case .codeBlock: codeBlockIdentity = component.identity
                case .unorderedList, .orderedList: listIdentity = component.identity
                case .listItem: listItemIdentity = component.identity
                case .paragraph: paragraphIdentity = component.identity
                default: break
                }
            }

            if let codeBlockIdentity {
                appendRun(value, key: .codeBlock(codeBlockIdentity))
            } else if let listIdentity {
                appendRun(value, key: .list(listIdentity), itemIdentity: listItemIdentity ?? 0)
            } else if let paragraphIdentity {
                appendRun(value, key: .paragraph(paragraphIdentity))
            } else {
                appendRun(value, key: .ungrouped)
            }
        }

        return groups.map { group in
            switch group.key {
            case .codeBlock:
                let text = group.runs.map(\.text).joined()
                return .codeBlock(text.trimmingCharacters(in: .newlines))
            case .list:
                let items = group.itemOrder.map { id in
                    (group.itemRuns[id] ?? []).map { SRELeadInlineRun(text: $0.text, bold: $0.bold, code: $0.code) }
                }
                return .bulletList(items)
            case .paragraph, .ungrouped:
                let runs = group.runs.map { SRELeadInlineRun(text: $0.text, bold: $0.bold, code: $0.code) }
                if let callout = calloutBlock(from: runs) {
                    return callout
                }
                return .paragraph(runs)
            }
        }
    }

    /// Recognizes a callout paragraph: its first run must be bold text
    /// matching one of the two labels exactly (see the file header's
    /// convention). Strips the label from the returned body runs, plus a
    /// single leading space on the next run if there is one (the model
    /// writes `**Finding:** the rest...`, so the space after the label lands
    /// as the start of the following plain-text run).
    private static func calloutBlock(from runs: [SRELeadInlineRun]) -> SRELeadMarkdownBlock? {
        guard let first = runs.first, first.bold, !first.code else { return nil }
        let trimmedLabel = first.text.trimmingCharacters(in: .whitespaces)
        let kind: SRELeadCalloutKind
        if trimmedLabel == findingLabel {
            kind = .finding
        } else if trimmedLabel == recommendationLabel {
            kind = .recommendation
        } else {
            return nil
        }

        var body = Array(runs.dropFirst())
        if let firstBody = body.first, !firstBody.bold, !firstBody.code, firstBody.text.hasPrefix(" ") {
            body[0] = SRELeadInlineRun(text: String(firstBody.text.dropFirst()), bold: false, code: false)
        }
        return .callout(kind, body)
    }
}
