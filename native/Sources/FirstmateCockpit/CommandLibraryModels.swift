// Manjesh Grand Line - native macOS app.
//
// Phase 1 of the "DevOps Commands" tab inside Shift (fm/grandline-devops-
// command-library) - see AGENTS.md's "Shift" section and the captain-
// approved design doc (data/grandline-devops-command-library/design-
// reference.html) for the full context. This file is the pure data model:
// a personal, parameterized command with `{{token}}` placeholders in its
// template, a fixed set of categories matching the mockup's own category
// rail, and a risk field stored now (Phase 2 owns the destructive-
// confirmation gate that reads it - see the design doc's phasing table) so
// Phase 2 needs no data migration.

import Foundation

// MARK: - Parameters

/// The parameter shapes the original spec calls for. Phase 1's UI only
/// really needs a text field for most of these (`.select` gets a real
/// dropdown, since the mockup shows one) - the model stays complete so a
/// later phase's richer editor doesn't need a migration.
enum CommandParameterKind: String, CaseIterable, Codable {
    case string
    case number
    case boolean
    case select
    case textarea
}

/// One `{{name}}` token inside a command's template.
struct CommandParameter: Identifiable, Equatable {
    var name: String
    var label: String
    var kind: CommandParameterKind
    var required: Bool
    var defaultValue: String?
    /// Literal option list for a `.select` parameter. When `configOptionsKey`
    /// is also set, that key's list from `commands/config.yaml` is preferred
    /// (see `CommandLibraryConfig`) and this is the fallback if the config
    /// key isn't present - so a command still renders sensibly before the
    /// captain has customized `config.yaml`.
    var options: [String]
    /// A key into `commands/config.yaml`'s `select_options` map (e.g.
    /// "namespaces") - lets the captain customize environment/namespace
    /// names without ever hardcoding them into the app itself, per the
    /// original spec's explicit instruction.
    var configOptionsKey: String?
    var placeholder: String?

    var id: String { name }

    init(
        name: String, label: String, kind: CommandParameterKind = .string, required: Bool = true,
        defaultValue: String? = nil, options: [String] = [], configOptionsKey: String? = nil, placeholder: String? = nil
    ) {
        self.name = name
        self.label = label
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.options = options
        self.configOptionsKey = configOptionsKey
        self.placeholder = placeholder
    }
}

// MARK: - Risk

/// Stored now, enforced later - Phase 2 owns the destructive-confirmation
/// gate (see the design doc). Phase 1 only renders the badge.
enum CommandRiskLevel: String, CaseIterable, Equatable {
    case readOnly = "read_only"
    case potentiallyDisruptive = "potentially_disruptive"
    case destructive = "destructive"

    var displayName: String {
        switch self {
        case .readOnly: return "read-only"
        case .potentiallyDisruptive: return "potentially-disruptive"
        case .destructive: return "destructive"
        }
    }

    /// Matches the mockup's severity-tint idiom - the same `HelmTint`
    /// categories every other risk/attention indicator in this app already
    /// uses, not a new color language.
    var tint: HelmTint {
        switch self {
        case .readOnly: return .good
        case .potentiallyDisruptive: return .warn
        case .destructive: return .critical
        }
    }
}

// MARK: - Command

/// A single command in the library. `id` is the stable on-disk identity
/// (the file's own slug, derived from the category/subcategory/filename
/// path) - never regenerated from `name`, so renaming a command doesn't
/// orphan its favorite/backlink state.
struct DevOpsCommand: Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
    var category: String
    var subcategory: String?
    var commandTemplate: String
    var parameters: [CommandParameter]
    var tags: [String]
    var risk: CommandRiskLevel

    init(
        id: String, name: String, description: String, category: String, subcategory: String? = nil,
        commandTemplate: String, parameters: [CommandParameter] = [], tags: [String] = [], risk: CommandRiskLevel = .readOnly
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.subcategory = subcategory
        self.commandTemplate = commandTemplate
        self.parameters = parameters
        self.tags = tags
        self.risk = risk
    }

    /// Every `{{token}}` appearing in `commandTemplate`, in first-appearance
    /// order, de-duplicated - the parameter auto-detection the brief asks
    /// for. A command's own `parameters` array is the source of truth for
    /// label/kind/default/options; this is what lets the UI (and a future
    /// Add/Edit sheet) notice a token with no matching `CommandParameter`
    /// entry, or render a bare token that was never explicitly declared.
    static func detectTokens(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}") else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        var seen = Set<String>()
        var tokens: [String] = []
        regex.enumerateMatches(in: template, range: range) { match, _, _ in
            guard let match, let tokenRange = Range(match.range(at: 1), in: template) else { return }
            let token = String(template[tokenRange])
            if seen.insert(token).inserted { tokens.append(token) }
        }
        return tokens
    }

    /// Declared parameters in template order, followed by any bare token in
    /// the template that has no declared parameter (a plain required string
    /// field with no label beyond the token name) - so the UI always has an
    /// input for every substitutable spot even if a command's YAML never
    /// declared one explicitly.
    var effectiveParameters: [CommandParameter] {
        let declared = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0) })
        return Self.detectTokens(in: commandTemplate).map { token in
            declared[token] ?? CommandParameter(name: token, label: token, required: true)
        }
    }

    /// Substitutes every `{{token}}` with `values[token]` (falling back to
    /// that parameter's own default, then to the bare token text so a
    /// not-yet-filled field is still visible in the preview rather than
    /// vanishing).
    func generatedCommand(values: [String: String]) -> String {
        var result = commandTemplate
        for param in effectiveParameters {
            let replacement = values[param.name]?.isEmpty == false
                ? values[param.name]!
                : (param.defaultValue ?? "{{\(param.name)}}")
            result = result.replacingOccurrences(of: "{{\(param.name)}}", with: replacement)
                .replacingOccurrences(of: "{{ \(param.name) }}", with: replacement)
        }
        return result
    }

    /// Plain substring search across every field the design doc's search
    /// section calls for - name/description/category/subcategory/tags/
    /// command text/parameter names. Fuzzy matching is explicitly Phase 3.
    func matches(query: String) -> Bool {
        let q = query.lowercased()
        if q.isEmpty { return true }
        if name.lowercased().contains(q) { return true }
        if description.lowercased().contains(q) { return true }
        if category.lowercased().contains(q) { return true }
        if let sub = subcategory, sub.lowercased().contains(q) { return true }
        if tags.contains(where: { $0.lowercased().contains(q) }) { return true }
        if commandTemplate.lowercased().contains(q) { return true }
        if parameters.contains(where: { $0.name.lowercased().contains(q) || $0.label.lowercased().contains(q) }) { return true }
        return false
    }
}

// MARK: - Categories

/// The fixed category catalog matching the mockup's own category rail order
/// exactly (Kubernetes, AWS, Linux, Docker, Git, MySQL, Networking, OpenSSL,
/// Terraform, Helm, ArgoCD, Jenkins, General) - each with a stable on-disk
/// folder id, a display name, and an SF Symbol for the category rail.
struct CommandLibraryCategoryInfo {
    let id: String
    let displayName: String
    let symbol: String
}

enum CommandLibraryCategory {
    static let all: [CommandLibraryCategoryInfo] = [
        .init(id: "kubernetes", displayName: "Kubernetes", symbol: "square.stack.3d.up"),
        .init(id: "aws", displayName: "AWS", symbol: "cloud"),
        .init(id: "linux", displayName: "Linux", symbol: "terminal"),
        .init(id: "docker", displayName: "Docker", symbol: "shippingbox"),
        .init(id: "git", displayName: "Git", symbol: "arrow.triangle.branch"),
        .init(id: "mysql", displayName: "MySQL", symbol: "cylinder"),
        .init(id: "networking", displayName: "Networking", symbol: "network"),
        .init(id: "openssl", displayName: "OpenSSL", symbol: "lock.shield"),
        .init(id: "terraform", displayName: "Terraform", symbol: "cube.transparent"),
        .init(id: "helm", displayName: "Helm", symbol: "square.grid.2x2"),
        .init(id: "argocd", displayName: "ArgoCD", symbol: "arrow.triangle.2.circlepath"),
        .init(id: "jenkins", displayName: "Jenkins", symbol: "gearshape.2"),
        .init(id: "general", displayName: "General DevOps", symbol: "wrench.and.screwdriver"),
    ]

    static func info(for id: String) -> CommandLibraryCategoryInfo {
        all.first { $0.id == id } ?? CommandLibraryCategoryInfo(id: id, displayName: id.capitalized, symbol: "folder")
    }
}

// MARK: - Config (captain-configurable select-option lists)

/// `commands/config.yaml` - never hardcode environment/namespace names into
/// the app itself (the original spec's explicit instruction). A
/// `CommandParameter.configOptionsKey` looks itself up here at render time;
/// a key with no entry here falls back to that parameter's own literal
/// `options`.
struct CommandLibraryConfig: Equatable {
    var selectOptions: [String: [String]]

    static let empty = CommandLibraryConfig(selectOptions: [:])

    func options(forKey key: String?, fallback: [String]) -> [String] {
        guard let key, let list = selectOptions[key], !list.isEmpty else { return fallback }
        return list
    }
}
