import Foundation

// Local patch on top of vendored YamlSwift (fm/cockpit-tools-yaml-order-perf-fix)
// - see Vendor/YamlSwift/README.md's "Local patch" section for the full writeup.
//
// `Yaml.dictionary` used to wrap a plain Swift `[Yaml: Yaml]`, which has no
// defined iteration order - so the Tools page's YAML Beautify action, which
// serializes a parsed `Yaml` tree back to text, came out with every mapping's
// keys in Swift's internal hash-bucket order instead of the order they
// appeared in the source document. `YamlOrderedMap` replaces that plain
// dictionary as the associated value of `Yaml.dictionary`: it keeps a real
// dictionary for O(1) key lookup, plus a parallel `keys` array recording
// insertion order, so a serializer walking `pairs` reproduces the original
// document's key order at every nesting level.
public struct YamlOrderedMap: Hashable {
  public private(set) var keys: [Yaml] = []
  private var values: [Yaml: Yaml] = [:]

  public init() {}

  public var isEmpty: Bool { keys.isEmpty }
  public var count: Int { keys.count }

  public subscript(key: Yaml) -> Yaml? {
    get { values[key] }
    set {
      guard let newValue = newValue else {
        if values.removeValue(forKey: key) != nil {
          keys.removeAll { $0 == key }
        }
        return
      }
      if values.updateValue(newValue, forKey: key) == nil {
        keys.append(key)
      }
    }
  }

  /// Key/value pairs in insertion (i.e. original document) order.
  public var pairs: [(key: Yaml, value: Yaml)] {
    keys.map { ($0, values[$0]!) }
  }

  public static func == (lhs: YamlOrderedMap, rhs: YamlOrderedMap) -> Bool {
    lhs.values == rhs.values
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(values)
  }
}

extension YamlOrderedMap: Sequence {
  public func makeIterator() -> AnyIterator<(key: Yaml, value: Yaml)> {
    let snapshot = pairs
    var index = 0
    return AnyIterator {
      guard index < snapshot.count else { return nil }
      let pair = snapshot[index]
      index += 1
      return pair
    }
  }
}

extension YamlOrderedMap: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (Yaml, Yaml)...) {
    self.init()
    for (k, v) in elements {
      self[k] = v
    }
  }
}
