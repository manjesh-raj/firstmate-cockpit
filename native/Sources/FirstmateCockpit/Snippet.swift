// Firstmate Cockpit - native macOS app.
//
// The saved-command library (design report Section B2 + B5, Section D Phase
// 3): "a reusable library of shell snippets you run in the active tab" - and,
// per-host, an optional startup snippet auto-run once a saved host's session
// looks ready. There is nothing secret here, so - unlike `SSHKey` - this model
// is fully `Codable` and lives entirely in `SnippetStore`'s plain JSON file.

import Foundation

/// A saved command: a label to find it by, and the literal text sent to a
/// terminal (plus a trailing Enter) when it is run.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var command: String

    var subtitle: String {
        let short = command.count > 60 ? String(command.prefix(60)) + "\u{2026}" : command
        return short.replacingOccurrences(of: "\n", with: " \u{23ce} ")
    }
}
