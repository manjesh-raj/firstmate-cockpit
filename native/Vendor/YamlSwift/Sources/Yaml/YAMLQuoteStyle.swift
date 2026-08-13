// Local patch on top of vendored YamlSwift (fm/cockpit-tools-yaml-quotes-diff-perf)
// - see Vendor/YamlSwift/README.md's "Local patch" section for the full writeup.
//
// `Yaml.string` used to carry only the decoded text, with no record of
// whether the source scalar was quoted or which quote style it used -
// `"true"`, `'true'`, and a bare `true` (the last of which actually parses
// to `.bool(true)`, not `.string`, but a bare `no`/`yes`/`123`-looking plain
// scalar behaves the same way) all collapsed into the same `.string(String)`
// value once parsed. The Tools page's YAML Beautify action re-serializes a
// parsed `Yaml` tree from scratch, and without this information it had no
// way to know a given string scalar had been quoted in the source at all -
// it fell back to a "does this need quoting to round-trip safely" heuristic
// (`YamlBeautify.quotedIfNeeded`) that silently stripped quotes whenever the
// heuristic judged them unnecessary. That is unsafe in general: a quoted
// `"true"`/`"123"`/`"no"` is a *string* in YAML, while the same text
// unquoted parses as a bool/number/(a string, for `no`/`yes`, under this
// parser's YAML-1.2-core schema) instead - a formatter deciding to drop
// quotes on its own can silently change what a downstream consumer parses
// the value as, not just its cosmetic formatting.
//
// `YamlQuoteStyle` records how a `.string` scalar was actually written in
// the source (`.plain` for an unquoted plain scalar or block/folded
// literal, `.single`/`.double` for `'...'`/`"..."`) as a second associated
// value on `Yaml.string`, set once at parse time (`YAMLParser.swift`'s three
// scalar-string branches) and read back by `YamlBeautify.scalarText` to
// preserve the original quoting exactly rather than deciding whether to add
// or remove it - only a `.plain` scalar's quoting is still decided by the
// existing heuristic, since that scalar was never quoted in the source and
// the heuristic's job (avoid corrupting a value that isn't safe to leave
// bare after this beautifier re-indents/re-flows the document) is
// unaffected by this fix.
public enum YamlQuoteStyle: Hashable {
  case plain
  case single
  case double
}
