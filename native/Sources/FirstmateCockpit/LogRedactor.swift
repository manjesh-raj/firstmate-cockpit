// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §14 ("this is extremely
// important"): every piece of text the Log Analyzer touches passes through
// here *first*, before it is stored on this type's own model, before it is
// rendered, and - the part that actually matters - before any of it reaches
// a `claude -p` process.
//
// The ordering guarantee, and where it is enforced: `LogAnalyzerController`
// calls `LogRedactor.redact` at the single moment a piece of evidence is
// created (paste, drop, clipboard, or the terminal bridge) and stores only
// the redacted string on `LogEvidenceItem.text`. Nothing downstream ever
// sees the raw text again - it is a local `let` in that one call and is
// never written to the model, to disk, or to a pasteboard. So the AI layer
// (`LogAnalyzerAI`) cannot leak a secret even if it were called wrongly:
// there is no unredacted copy left for it to read. `LogAnalyzerSelfTest`
// asserts this the only way that is actually meaningful - by grepping the
// literal bytes of a built prompt and a saved investigation file for the
// planted secret values, rather than by reasoning about call order.
//
// What a `Redaction` deliberately does NOT carry: the secret. `preview` is
// the *masked* result line, and `matchedText` is a fingerprint - the first
// and last two characters with the middle replaced - never the value. Spec
// §14's "never automatically store detected secrets" is therefore true by
// construction of this struct, not by a policy someone has to remember: the
// full secret exists only inside `redact`'s own local scope and in the
// caller's transient raw string, and is gone the moment both return.
//
// Detection strategy: a fixed list of ordered rules, each a real
// `NSRegularExpression` with one capture group naming the part to mask. The
// ordering matters (a `postgres://user:pw@host` connection string is matched
// before the bare "password=" rule, so the URL rule's tighter replacement
// wins), and every rule is anchored on a real, named credential shape rather
// than on entropy heuristics - an entropy scanner over kubectl output
// produces constant false positives on base64 blobs, resource IDs, and hashes,
// which trains the captain to click straight past the review step, which is
// worse than a narrower list. When in doubt this errs toward *not* claiming
// something is a secret, and the review step (spec §14) is what covers the
// gap: the captain sees the full redacted text before it is sent, so an
// undetected secret is still visible to a human before it leaves.

import Foundation

/// One thing that was masked. Carries no secret material - see the header.
struct LogRedaction: Identifiable, Equatable {
    var id: String { "\(lineNumber)#\(kind)#\(fingerprint)" }
    /// Human-facing name of what matched ("Bearer token", "AWS access key").
    var kind: String
    /// 1-based line number in the input.
    var lineNumber: Int
    /// The line *after* masking - safe to show and safe to store.
    var maskedLine: String
    /// A non-reversible hint so the captain can recognise which secret this
    /// was without the value being reproduced: first 2 and last 2 characters
    /// of the matched value, with the middle collapsed. A value shorter than
    /// 8 characters is fingerprinted as its length alone.
    var fingerprint: String
}

struct LogRedactionResult: Equatable {
    var text: String
    var redactions: [LogRedaction]

    var count: Int { redactions.count }
    var isEmpty: Bool { redactions.isEmpty }
}

enum LogRedactor {

    /// The literal placeholder spec §14 shows.
    static let placeholder = "[REDACTED]"

    /// One detection rule. `pattern` must contain exactly one capture group;
    /// that group's range is what gets replaced with `placeholder`, so the
    /// surrounding context ("Authorization: Bearer ", "postgres://user:")
    /// survives and the captain can still read what the line was about.
    private struct Rule {
        let kind: String
        let pattern: String
        let options: NSRegularExpression.Options
    }

    /// Ordered - earlier rules win on overlapping matches (see the header).
    /// Every pattern was written against the shapes spec §14 lists:
    /// API keys, AWS credentials, tokens, passwords, Authorization headers,
    /// Bearer tokens, private keys, connection strings, database passwords,
    /// and generic secret values.
    private static let rules: [Rule] = [
        // Private key blocks - matched as a whole body so a multi-line PEM
        // collapses to one redaction rather than dozens of "random base64"
        // hits. `.dotMatchesLineSeparators` is why this one must run first.
        Rule(kind: "Private key",
             pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----([\\s\\S]*?)-----END [A-Z ]*PRIVATE KEY-----",
             options: []),

        // Authorization / Proxy-Authorization headers, any scheme.
        Rule(kind: "Authorization header",
             pattern: "(?:Proxy-)?Authorization\\s*[:=]\\s*(?:Bearer|Basic|Token|ApiKey)?\\s*([A-Za-z0-9._~+/=-]{8,})",
             options: [.caseInsensitive]),

        // A bare bearer/JWT token anywhere (a JWT's three dot-separated
        // base64url segments is a distinctive enough shape to match on its
        // own, without needing the header context above).
        Rule(kind: "JWT",
             pattern: "\\b(eyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{4,})\\b",
             options: []),

        // AWS access key id / secret access key.
        Rule(kind: "AWS access key ID",
             pattern: "\\b((?:AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ABIA|ACCA)[A-Z0-9]{12,})\\b",
             options: []),
        Rule(kind: "AWS secret access key",
             pattern: "(?:aws_secret_access_key|aws-secret-access-key|secretAccessKey)\\s*[:=]\\s*\"?([A-Za-z0-9/+=]{30,})\"?",
             options: [.caseInsensitive]),
        Rule(kind: "AWS session token",
             pattern: "(?:aws_session_token|aws-session-token|sessionToken)\\s*[:=]\\s*\"?([A-Za-z0-9/+=_-]{40,})\"?",
             options: [.caseInsensitive]),

        // Provider-shaped API keys with a recognisable prefix.
        Rule(kind: "API key",
             pattern: "\\b((?:sk|pk|rk|api|key)[-_](?:live|test|prod|dev)?[-_]?[A-Za-z0-9]{12,})\\b",
             options: []),
        Rule(kind: "GitHub token",
             pattern: "\\b((?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{16,})\\b",
             options: []),
        Rule(kind: "Slack token",
             pattern: "\\b(xox[abposr]-[A-Za-z0-9-]{10,})\\b",
             options: []),

        // A connection string's password segment (scheme://user:PASSWORD@host).
        // Runs before the generic password rule so the tighter, structural
        // match wins - the reason `rules` is ordered at all.
        Rule(kind: "Connection string password",
             pattern: "[a-zA-Z][a-zA-Z0-9+.-]*://[^\\s:/@]+:([^\\s@/]{1,})@",
             options: []),

        // Named credential assignments - `password=`, `PGPASSWORD: x`,
        // `--password x`, `secret: x`, `token=`, `api_key:`, etc. The value
        // is deliberately required to be non-trivial (4+ non-space chars)
        // and not itself a placeholder, so `password=` with an empty value
        // or an already-masked one isn't reported as a find.
        Rule(kind: "Password",
             pattern: "(?:^|[\\s\"'{,(&?-])(?:[A-Za-z_]*password|passwd|pwd)\\s*[:=]\\s*\"?([^\\s\"',}&]{4,})\"?",
             options: [.caseInsensitive]),
        Rule(kind: "Secret value",
             pattern: "(?:^|[\\s\"'{,(&?-])(?:[A-Za-z_]*secret|client_secret|private_token)\\s*[:=]\\s*\"?([^\\s\"',}&]{6,})\"?",
             options: [.caseInsensitive]),
        Rule(kind: "Token",
             pattern: "(?:^|[\\s\"'{,(&?-])(?:[A-Za-z_]*token|access_token|refresh_token|id_token)\\s*[:=]\\s*\"?([A-Za-z0-9._~+/=-]{12,})\"?",
             options: [.caseInsensitive]),
        Rule(kind: "API key",
             pattern: "(?:^|[\\s\"'{,(&?-])(?:api[_-]?key|apikey|x-api-key|x-internal-api-key|subscription-key)\\s*[:=]\\s*\"?([^\\s\"',}&]{8,})\"?",
             options: [.caseInsensitive]),

        // Kubernetes Secret data values - `data:` blocks in a `kubectl get
        // secret -o yaml` are base64 and are, by definition, secrets.
        Rule(kind: "Kubernetes secret data",
             pattern: "^\\s{2,}[A-Za-z0-9._-]+:\\s+([A-Za-z0-9+/]{20,}={0,2})\\s*$",
             options: [.anchorsMatchLines]),
    ]

    private static let compiled: [(kind: String, regex: NSRegularExpression)] = {
        rules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                assertionFailure("LogRedactor: rule '\(rule.kind)' failed to compile")
                return nil
            }
            return (rule.kind, regex)
        }
    }()

    /// Values that already look masked, so a second pass over
    /// already-redacted text (a re-analysis, or a captain pasting output
    /// that was redacted elsewhere) doesn't report them as fresh finds.
    private static let alreadyMasked: Set<String> = [
        placeholder.lowercased(), "redacted", "***", "****", "*****", "<redacted>",
        "xxxx", "xxxxx", "hidden", "masked", "null", "none", "empty",
    ]

    /// Masks every match and returns both the safe text and the (secret-free)
    /// list of what was masked.
    ///
    /// One pass over the whole document rather than line by line, because
    /// the private-key rule genuinely spans lines. Match ranges are
    /// collected first, then applied back-to-front so earlier offsets stay
    /// valid, and overlapping ranges from a later (looser) rule are dropped
    /// so a value is never masked twice or half-masked.
    static func redact(_ input: String) -> LogRedactionResult {
        guard !input.isEmpty else { return LogRedactionResult(text: input, redactions: []) }

        let ns = input as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct Hit {
            let kind: String
            let range: NSRange
            let value: String
        }
        var hits: [Hit] = []

        for (kind, regex) in compiled {
            regex.enumerateMatches(in: input, options: [], range: full) { match, _, _ in
                guard let match, match.numberOfRanges >= 2 else { return }
                let valueRange = match.range(at: 1)
                guard valueRange.location != NSNotFound, valueRange.length > 0 else { return }
                let value = ns.substring(with: valueRange)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !alreadyMasked.contains(trimmed.lowercased()) else { return }
                // An already-placeholdered value ("Bearer [REDACTED]") must
                // not count as a new find on a re-run.
                guard !trimmed.contains(placeholder) else { return }
                hits.append(Hit(kind: kind, range: valueRange, value: value))
            }
        }

        guard !hits.isEmpty else { return LogRedactionResult(text: input, redactions: []) }

        // Earliest first, longest first on a tie - then drop anything
        // overlapping an already-accepted range, so the first (higher
        // priority, per `rules` order) or widest match wins.
        hits.sort { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            return a.range.length > b.range.length
        }
        var accepted: [Hit] = []
        for hit in hits {
            let overlaps = accepted.contains { NSIntersectionRange($0.range, hit.range).length > 0 }
            if !overlaps { accepted.append(hit) }
        }

        // Apply back-to-front so each replacement leaves earlier offsets valid.
        let result = NSMutableString(string: input)
        var redactions: [LogRedaction] = []
        for hit in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: hit.range, with: placeholder)
        }
        let masked = result as String

        // Line numbers/masked lines are computed against the *masked* text,
        // by locating the same line index the original hit fell on. Both
        // strings have the same number of newlines (the placeholder contains
        // none, and a multi-line private key body collapses to one line -
        // handled by clamping below).
        let maskedLines = masked.components(separatedBy: "\n")
        for hit in accepted.sorted(by: { $0.range.location < $1.range.location }) {
            let lineIndex = ns.substring(to: hit.range.location).components(separatedBy: "\n").count - 1
            let clamped = min(max(lineIndex, 0), max(maskedLines.count - 1, 0))
            let line = maskedLines.isEmpty ? "" : maskedLines[clamped]
            redactions.append(LogRedaction(
                kind: hit.kind,
                lineNumber: clamped + 1,
                maskedLine: line.trimmingCharacters(in: .whitespaces),
                fingerprint: fingerprint(hit.value)
            ))
        }

        return LogRedactionResult(text: masked, redactions: redactions)
    }

    /// Non-reversible hint - see `LogRedaction.fingerprint`.
    static func fingerprint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return "\(trimmed.count) chars" }
        let head = trimmed.prefix(2)
        let tail = trimmed.suffix(2)
        return "\(head)…\(tail) (\(trimmed.count) chars)"
    }

    /// A quick "does this text still look like it contains a credential"
    /// check, used only to decide whether the review step needs to warn
    /// harder. Cheap on already-redacted text since every rule's value group
    /// now reads `[REDACTED]`, which every rule skips.
    static func containsLikelySecret(_ text: String) -> Bool {
        !redact(text).isEmpty
    }
}
