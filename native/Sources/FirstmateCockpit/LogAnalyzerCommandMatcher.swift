// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §11: "the analyzer should prefer
// commands from the user's existing Command Library. Do not generate
// arbitrary commands if an equivalent saved command exists."
//
// Resolved **after** the AI answers, not by asking the model to remember the
// library. Two reasons: the library is the captain's own live data (it
// changes whenever they add a command, and it can be large), and a model
// asked to "pick from this list" reliably invents a plausible-looking entry
// that is not in it. Matching a returned command back onto a real saved one
// is a deterministic string problem, so it is solved deterministically here
// and the result is verifiable - `LogSuggestedCommand.libraryCommandID` is
// either a real id in `CommandLibraryStore` or nil.
//
// **Matching is intentionally conservative.** A false positive here is worse
// than a miss: it would relabel a command the model wrote as "from your
// library", which is a lie about provenance. So a match requires the two
// commands to agree on their *executable and subcommand chain* (e.g.
// `kubectl describe pod`) AND to share a meaningful proportion of their
// remaining significant tokens. A saved command's `{{token}}` placeholders
// are treated as wildcards that match anything in that position, which is
// what lets a parameterised library entry match a concrete suggestion.

import Foundation

enum LogAnalyzerCommandMatcher {

    /// Fraction of the suggestion's own significant tokens that must be
    /// accounted for by the library command before it counts as equivalent.
    /// 0.6 was chosen so `kubectl describe pod X -n Y` matches a saved
    /// `kubectl describe pod {{pod}} -n {{namespace}}` (every token accounted
    /// for) while `kubectl get events -n Y --sort-by=...` does not match a
    /// saved `kubectl get pods -n {{namespace}}` (the subcommand chain
    /// already differs, so it never gets this far).
    static let minimumTokenOverlap = 0.6

    /// Tokens that carry no matching signal - dropped from both sides before
    /// the overlap is computed so a flag ordering difference doesn't sink an
    /// otherwise identical command.
    private static let noiseTokens: Set<String> = ["|", "&&", ";", "\\", "-o", "--output", "2>&1", "-n", "--namespace"]

    /// Splits a command into comparable tokens. Placeholders become the
    /// literal wildcard `*`, so a parameterised saved command can match a
    /// concrete one.
    static func tokens(_ command: String) -> [String] {
        let normalized = command
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        var out: [String] = []
        for raw in normalized.split(separator: " ", omittingEmptySubsequences: true) {
            var token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard !token.isEmpty else { continue }
            if token.hasPrefix("{{") && token.hasSuffix("}}") { token = "*" }
            // A `--flag={{value}}` or `--flag=concrete` compares on the flag
            // name only - the value is exactly the part that legitimately
            // differs between a saved template and a concrete suggestion.
            if token.hasPrefix("-"), let eq = token.firstIndex(of: "=") {
                token = String(token[token.startIndex..<eq])
            }
            out.append(token)
        }
        return out
    }

    /// The executable plus any leading non-flag words - `kubectl describe
    /// pod`, `aws logs tail`, `systemctl status`. This is the part that must
    /// match exactly (modulo wildcards) for two commands to be "the same
    /// thing".
    static func subcommandChain(_ tokens: [String]) -> [String] {
        var chain: [String] = []
        for token in tokens {
            if token.hasPrefix("-") { break }
            // A wildcard or an obviously concrete argument (a path, a name
            // with a dot/slash) ends the chain - it's an operand, not part
            // of the verb.
            if token == "*" || token.contains("/") || token.contains(".") { break }
            chain.append(token.lowercased())
            if chain.count == 4 { break }
        }
        return chain
    }

    /// Whether two chains describe the same operation. Requires the same
    /// executable, and one chain must be a prefix of the other (so
    /// `kubectl logs` matches `kubectl logs` but not `kubectl get`), with at
    /// least two matching segments when both have them - a bare `kubectl`
    /// vs `kubectl` is not a match on its own.
    static func chainsMatch(_ a: [String], _ b: [String]) -> Bool {
        guard let first = a.first, let other = b.first, first == other else { return false }
        let shared = zip(a, b).prefix { $0 == $1 }.count
        guard shared == min(a.count, b.count) else { return false }
        if a.count >= 2 && b.count >= 2 { return shared >= 2 }
        // Single-word commands (`dig`, `curl`, `ping`) legitimately have no
        // subcommand - matching on the executable alone is correct there.
        return a.count == 1 && b.count == 1
    }

    /// 0-1: how much of `suggestion`'s signal the `library` command covers.
    static func overlap(suggestion: [String], library: [String]) -> Double {
        let suggestionSet = suggestion.filter { !noiseTokens.contains($0) && $0 != "*" }
        guard !suggestionSet.isEmpty else { return library.isEmpty ? 1 : 0 }
        // A `*` in the library command matches any one suggestion token, so
        // count wildcards as free credits rather than as literals to find.
        let wildcards = library.filter { $0 == "*" }.count
        let literals = Set(library.filter { !noiseTokens.contains($0) && $0 != "*" }.map { $0.lowercased() })
        var matched = 0
        var unmatched = 0
        for token in suggestionSet {
            if literals.contains(token.lowercased()) { matched += 1 } else { unmatched += 1 }
        }
        matched += min(wildcards, unmatched)
        return Double(matched) / Double(suggestionSet.count)
    }

    /// Finds the best equivalent saved command, or nil.
    static func bestMatch(for suggestion: String, in commands: [DevOpsCommand]) -> DevOpsCommand? {
        let suggestionTokens = tokens(suggestion)
        guard !suggestionTokens.isEmpty else { return nil }
        let suggestionChain = subcommandChain(suggestionTokens)
        guard !suggestionChain.isEmpty else { return nil }

        var best: (command: DevOpsCommand, score: Double)?
        for command in commands {
            let libraryTokens = tokens(command.commandTemplate)
            guard chainsMatch(suggestionChain, subcommandChain(libraryTokens)) else { continue }
            let score = overlap(suggestion: suggestionTokens, library: libraryTokens)
            guard score >= minimumTokenOverlap else { continue }
            if best == nil || score > best!.score { best = (command, score) }
        }
        return best?.command
    }

    /// Re-points every suggestion at a saved command where one exists, and
    /// **replaces the suggestion's own text with the library command's
    /// template** when it does - that is the actual point of spec §11: the
    /// captain runs their own vetted, parameterised command, not a
    /// near-identical one a model retyped.
    static func resolve(_ suggestions: [LogSuggestedCommand], against commands: [DevOpsCommand]) -> [LogSuggestedCommand] {
        guard !commands.isEmpty else { return suggestions }
        return suggestions.map { suggestion in
            guard let match = bestMatch(for: suggestion.command, in: commands) else { return suggestion }
            var resolved = suggestion
            resolved.libraryCommandID = match.id
            resolved.libraryCommandName = match.name
            resolved.command = match.commandTemplate
            if resolved.rationale.isEmpty { resolved.rationale = match.description }
            return resolved
        }
    }

    /// Library commands worth offering even though the model didn't suggest
    /// them - the saved commands whose category matches the detected source.
    /// Appended after the resolved suggestions so the captain's own
    /// investigation commands for this kind of output are one click away
    /// even when the AI layer is unavailable entirely.
    static func libraryFallback(for kind: LogSourceKind, in commands: [DevOpsCommand], limit: Int = 4) -> [LogSuggestedCommand] {
        let category: String
        switch kind {
        case .kubernetes: category = "kubernetes"
        case .dockerCompose: category = "docker"
        case .systemd, .applicationLog: category = "linux"
        case .nginx, .httpNetwork: category = "networking"
        case .tls: category = "openssl"
        case .cloudWatch: category = "aws"
        case .terraform: category = "terraform"
        case .stackTrace, .jsonError, .genericText: category = "general"
        }

        return commands
            .filter { $0.category == category && $0.risk == .readOnly }
            .prefix(limit)
            .enumerated()
            .map { index, command in
                LogSuggestedCommand(
                    order: 1000 + index,
                    title: command.name,
                    command: command.commandTemplate,
                    rationale: command.description,
                    libraryCommandID: command.id,
                    libraryCommandName: command.name
                )
            }
    }
}
