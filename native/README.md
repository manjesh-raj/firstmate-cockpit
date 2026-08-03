# Firstmate Cockpit - Native (Phase 2)

This is the growing native macOS cockpit: a Swift + SwiftTerm app that replaces the web (xterm.js-in-WKWebView) terminal with a real, native one.

**Phase 2** turns the single Phase 1 terminal into a proper **tabbed console** with both terminal modes and terminal-level polish:

- **Shell** tab - the Phase 1 terminal (`$SHELL -l`), unchanged in behaviour.
- **Mirror** tab - a live view of the first mate's tmux session, attached through a grouped session.
- **Helm** dark/light terminal theming, with a one-key toggle.
- In-terminal **find**, **font zoom**, and **copy**.

It builds directly on the merged Phase 1 code. Phase 1 was a single-window proof of terminal feel and screenshot-paste. That terminal, including the paste-hardening `CockpitTerminalView` subclass, is preserved verbatim as the Shell tab.

The design and the exact API shapes used here come from the native design scout report at `data/cockpit-native-design-scout/report.md` (Phase 2 is section 7, terminal attach is 4.3, feature mapping is section 6, the Helm visual language is section 9).

## What is and is not in Phase 2

**In scope (built here):**

- A two-tab console surface hosting two SwiftTerm terminals.
- The tmux grouped-session lifecycle, **ported to Swift** (`Process`) so Phase 2 needs **no Python backend running** (that is Phase 3).
- Helm dark + light palettes applied to the terminal colour set (foreground/background/cursor/selection + a full 16-colour ANSI set).
- Native find bar, font zoom, and copy-to-`NSPasteboard`, all on the top bar and the main menu.

**Deliberately out of scope (later phases):** no dashboard / fleet view / PR list (P3), no Python backend spawning or embedding (P3), no auth (P3), no packaging / signing / notarization (P4). This is the console only.

## Architecture

One AppKit window whose content is a `ConsoleController`. All terminal behaviour lives in the console and its helpers; `main.swift` owns only the window, the main menu, and app lifecycle.

| File | Responsibility |
|---|---|
| `main.swift` | App entry, window, main menu (Edit + View), lifecycle. |
| `ConsoleController.swift` | The tabbed surface: two terminals, tab switching, theming, zoom, find, copy, reconnect. |
| `CockpitTerminalView.swift` | The Phase 1 paste-hardening `LocalProcessTerminalView` subclass, verbatim. Both tabs use it. |
| `TerminalEnvironment.swift` | How a terminal child is spawned (`$SHELL -l`, cwd, UTF-8 env), and the mirror target. |
| `TmuxMirror.swift` | The grouped-session setup/teardown ported from `backend/terminal.py`. |
| `HelmTheme.swift` | The Helm dark/light palettes as SwiftTerm colours (OKLCH tokens pre-converted to sRGB). |

### How the terminals attach

Both tabs fork their child **in-process** via SwiftTerm's `LocalProcessTerminalView.startProcess`, so keystrokes never make a localhost round trip (the web app did, on every character).

- **Shell:** `startProcess($SHELL, ["-l"])`. A real login shell with native scrollback.
- **Mirror:** first `TmuxMirror.setUp` creates a *grouped* session mirroring the first mate's target (`tmux new-session -d -s <group> -t <session>`, `select-window`, `set-option window-size latest`, `status off`), then `startProcess(tmux, ["attach-session", "-t", <group>])`. A grouped session shares the real session's windows but keeps its own size and active window, so the cockpit view never resizes the captain's real terminal. The group is torn down on reconnect and on quit.

### Mirror target

The Mirror tab attaches to the tmux target in `FM_MIRROR_TARGET` (e.g. `firstmate` or `firstmate:1`), defaulting to the **`firstmate`** session. If that session does not exist, the Mirror tab shows a clear message instead of failing - set `FM_MIRROR_TARGET` and press `⌘R` to reconnect. Full target-detection UI is Phase 3.

## Requirements

- macOS 13 or newer, Apple Silicon.
- Swift 6.x toolchain. **Command Line Tools only is enough** - this uses `swift build` / `swift run`, not Xcode or `xcodebuild`. Verified on Swift 6.3.3.
- `tmux` on `PATH` (or in a standard Homebrew/usr location) for the Mirror tab.

## Build

```bash
cd native
swift build
```

First build takes ~90s because it compiles SwiftTerm from source. The dependency is pinned in `Package.resolved` to SwiftTerm `1.15.0`. The product is a `Mach-O arm64` executable at `.build/debug/FirstmateCockpit`.

## Run

From the package directory:

```bash
swift run
```

or launch the built binary directly:

```bash
.build/debug/FirstmateCockpit
```

To mirror a different tmux session:

```bash
FM_MIRROR_TARGET=firstmate:1 swift run
```

A window titled **"Firstmate Cockpit"** opens on the **Shell** tab.

> Launching an unbundled executable this way is expected pre-P4. It gets a Dock icon and menu bar because the app sets a regular activation policy. Signing, notarization, and a real `.app` bundle are Phase 4.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘1` / `⌘2` | Shell tab / Mirror tab |
| `⌘F` | Find in the active terminal |
| `⌘+` / `⌘−` / `⌘0` | Zoom in / out / reset |
| `⌘⌥T` | Toggle Helm light/dark |
| `⌘R` | Reconnect the active tab (re-attach the mirror, or restart the shell) |
| `⌘V` | Paste (drives screenshot-paste into Claude) |
| `⌘C` | Copy selection |

The same actions are on the top bar of the console and in the **View** menu.

## Captain validation checklist

This app **cannot be validated headlessly** - the whole point is runtime behaviour and feel on your machine. The build being green (it is: `swift build` compiles and links a `Mach-O arm64` executable, and the app survives launch with no crash) does **not** prove any of the following. These are yours to run.

**(a) Both tabs work**
- [ ] The **Shell** tab opens on a live login shell; typing and running commands works.
- [ ] `⌘2` switches to the **Mirror** tab.

**(b) The Mirror tab shows the live first mate**
- [ ] With a `firstmate` tmux session running, the Mirror tab shows the first mate's live pane (its output updates in real time, no status bar).
- [ ] Confirm your **real** terminal did not get resized by the cockpit attaching (that is what the grouped session prevents).
- [ ] If you mirror a different session, launch with `FM_MIRROR_TARGET=<target>`.

**(c) Tab switching is clean**
- [ ] Switching Shell ↔ Mirror with `⌘1` / `⌘2` (or the top-bar tabs) is instant, keeps each tab's state, and focus lands in the shown terminal.

**(d) Search / zoom / copy work**
- [ ] `⌘F` opens the find bar in the active terminal; typing highlights matches; `↵` / `⇧↵` step through them.
- [ ] `⌘+` / `⌘−` change the terminal font size live on both tabs; `⌘0` resets.
- [ ] Select text and `⌘C`; it lands on the system clipboard (paste it elsewhere to confirm).

**(e) Theming (dark/light) looks right**
- [ ] `⌘⌥T` toggles the terminal (and the top bar) between Helm dark and Helm light. Both should read as the same instrument panel as the web cockpit, with legible text in either mode.

**(f) Paste still works on both tabs**
- [ ] In a tab, run `claude` (Claude Code). Take a screenshot to the clipboard (`⌘⌃⇧4`, then select a region). With the window focused, `⌘V`. Confirm Claude Code registers a pasted image.
- [ ] Repeat on the other tab - both share the same paste wiring.

If those pass, Phase 2 is validated and Phase 3 (the dashboard surfaces + embedded backend) can begin.

## Scope guardrails

- Console only. No dashboard, backend spawning, auth, or packaging.
- Does not touch the existing Python cockpit (`backend/`, `desktop.py`). The native app is a separate, growing surface under `native/`.
