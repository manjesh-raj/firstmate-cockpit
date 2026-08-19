// Manjesh Grand Line - native macOS app.
//
// DevOpsCommand <-> Yaml conversions, following `ShiftYaml.swift`'s own
// pattern exactly: the vendored `Yaml` library (Vendor/YamlSwift) for
// parsing, `YamlBeautify.dump` for serialization, every string written
// double-quoted (`.string(_, quoted: .double)`) so a value round-tripped
// through this file inherits YamlBeautify's order- and quote-preservation
// patches automatically - no second YAML layer.

import Foundation
import Yaml

enum CommandLibraryYaml {

    // MARK: Scalar helpers (same shape as ShiftYaml's own)

    private static func str(_ s: String) -> Yaml { .string(s, quoted: .double) }
    private static func strOpt(_ s: String?) -> Yaml { s.map(str) ?? .null }

    private static func optString(_ y: Yaml) -> String? {
        switch y {
        case .null: return nil
        case .string(let s, _): return s.isEmpty ? nil : s
        default: return nil
        }
    }

    private static func reqString(_ y: Yaml) -> String { optString(y) ?? "" }

    // MARK: Parameter

    static func toYaml(_ p: CommandParameter) -> Yaml {
        var m = YamlOrderedMap()
        m[str("name")] = str(p.name)
        m[str("label")] = str(p.label)
        m[str("type")] = str(p.kind.rawValue)
        m[str("required")] = .bool(p.required)
        m[str("default")] = strOpt(p.defaultValue)
        m[str("options")] = .array(p.options.map(str))
        m[str("config_options_key")] = strOpt(p.configOptionsKey)
        m[str("placeholder")] = strOpt(p.placeholder)
        return .dictionary(m)
    }

    static func parameter(from y: Yaml) -> CommandParameter? {
        guard let dict = y.dictionary else { return nil }
        let name = reqString(dict[str("name")] ?? .null)
        guard !name.isEmpty else { return nil }
        return CommandParameter(
            name: name,
            label: optString(dict[str("label")] ?? .null) ?? name,
            kind: CommandParameterKind(rawValue: reqString(dict[str("type")] ?? .null)) ?? .string,
            required: dict[str("required")]?.bool ?? true,
            defaultValue: optString(dict[str("default")] ?? .null),
            options: (dict[str("options")]?.array ?? []).compactMap { optString($0) },
            configOptionsKey: optString(dict[str("config_options_key")] ?? .null),
            placeholder: optString(dict[str("placeholder")] ?? .null)
        )
    }

    // MARK: Command

    static func toYaml(_ c: DevOpsCommand) -> Yaml {
        var m = YamlOrderedMap()
        m[str("id")] = str(c.id)
        m[str("name")] = str(c.name)
        m[str("description")] = str(c.description)
        m[str("category")] = str(c.category)
        m[str("subcategory")] = strOpt(c.subcategory)
        m[str("command")] = str(c.commandTemplate)
        m[str("parameters")] = .array(c.parameters.map(toYaml))
        m[str("tags")] = .array(c.tags.map(str))
        m[str("risk")] = str(c.risk.rawValue)
        return .dictionary(m)
    }

    /// `fallbackID`/`fallbackCategory`/`fallbackSubcategory` come from the
    /// file's own on-disk path (see `CommandLibraryStore.scanCommands`) - the
    /// filename/folder structure is the stable identity, never re-derived
    /// from the human-editable `name` field, so renaming a command in its
    /// YAML never orphans its favorite/backlink state.
    static func command(from y: Yaml, fallbackID: String, fallbackCategory: String, fallbackSubcategory: String?) -> DevOpsCommand? {
        guard let dict = y.dictionary else { return nil }
        let name = reqString(dict[str("name")] ?? .null)
        guard !name.isEmpty else { return nil }
        let paramsYaml = dict[str("parameters")]?.array ?? []
        return DevOpsCommand(
            id: fallbackID,
            name: name,
            description: reqString(dict[str("description")] ?? .null),
            category: optString(dict[str("category")] ?? .null) ?? fallbackCategory,
            subcategory: optString(dict[str("subcategory")] ?? .null) ?? fallbackSubcategory,
            commandTemplate: reqString(dict[str("command")] ?? .null),
            parameters: paramsYaml.compactMap(parameter(from:)),
            tags: (dict[str("tags")]?.array ?? []).compactMap { optString($0) },
            risk: CommandRiskLevel(rawValue: reqString(dict[str("risk")] ?? .null)) ?? .readOnly
        )
    }

    // MARK: Config (commands/config.yaml)

    static func toYaml(_ config: CommandLibraryConfig) -> Yaml {
        var options = YamlOrderedMap()
        for key in config.selectOptions.keys.sorted() {
            options[str(key)] = .array((config.selectOptions[key] ?? []).map(str))
        }
        var m = YamlOrderedMap()
        m[str("select_options")] = .dictionary(options)
        return .dictionary(m)
    }

    static func config(from y: Yaml) -> CommandLibraryConfig {
        guard let dict = y.dictionary, let optionsDict = dict[str("select_options")]?.dictionary else { return .empty }
        var result: [String: [String]] = [:]
        for (key, value) in optionsDict.pairs {
            guard let keyString = optString(key) else { continue }
            result[keyString] = (value.array ?? []).compactMap { optString($0) }
        }
        return CommandLibraryConfig(selectOptions: result)
    }

    // MARK: Whole-document IO (single command file, or the config file)

    static func readCommand(path: String, fallbackID: String, fallbackCategory: String, fallbackSubcategory: String?) -> DevOpsCommand? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return nil }
        guard let doc = try? Yaml.load(text) else { return nil }
        return command(from: doc, fallbackID: fallbackID, fallbackCategory: fallbackCategory, fallbackSubcategory: fallbackSubcategory)
    }

    static func writeCommand(_ command: DevOpsCommand, path: String) throws {
        let text = YamlBeautify.dump([toYaml(command)])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func readConfig(path: String) -> CommandLibraryConfig {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return .empty }
        guard let doc = try? Yaml.load(text) else { return .empty }
        return config(from: doc)
    }

    static func writeConfig(_ config: CommandLibraryConfig, path: String) throws {
        let text = YamlBeautify.dump([toYaml(config)])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Favorites (commands/favorites.yaml - a flat `favorites: [id, ...]` list)

    static func readFavorites(path: String) -> Set<String> {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return [] }
        guard let doc = try? Yaml.load(text) else { return [] }
        let ids = doc.dictionary?[str("favorites")]?.array ?? []
        return Set(ids.compactMap { optString($0) })
    }

    static func writeFavorites(_ ids: Set<String>, path: String) throws {
        var m = YamlOrderedMap()
        m[str("favorites")] = .array(ids.sorted().map(str))
        let text = YamlBeautify.dump([.dictionary(m)])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
