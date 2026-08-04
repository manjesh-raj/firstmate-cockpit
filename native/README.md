# Firstmate Cockpit - Native (Phase 2)

This is the growing native macOS cockpit: a Swift + SwiftTerm app that replaces the web (xterm.js-in-WKWebView) terminal with a real, native one.

**Phase 2** turns the single Phase 1 terminal into a proper **tabbed console** with both terminal modes and terminal-level polish:

- **Shell** tab - the Phase 1 terminal (`$SHELL -l`), unchanged in behaviour.
- **Mirror** tab - a live view of the first mate's tmux session, attached through a grouped session.
- **Helm** dark/light terminal theming, with a one-key toggle.
- In-terminal **find**, **font zoom**, and **copy**.

It builds directly on the merged Phase 1 code. Phase 1 was a single-window proof of terminal feel and screenshot-paste. That terminal, including the paste-hardening `CockpitTerminalView` subclass, is preserved verbatim as the Shell tab.

## Dynamic tabs (connection-manager foundation)

The console's tabs are now a **flexible collection** (`[TabModel]`), not the old fixed `enum Tab { case shell, mirror }`. This is Phase 0 of turning the native cockpit into a Termius/WezTerm-style connection manager (design doc: `data/cockpit-ssh-manager-research/report.md`, Section A4/A5 and Section D Phase 0). It ships the tab operations every terminal manager needs, and it is the primitive that later phases reuse to open SSH host sessions.

- **New tab** (`⌘T` or the `+` button) - a fresh login shell.
- **Duplicate tab** (`⌘D`, or right-click -> Duplicate) - a new tab running the **same argv** as the current tab. Duplicating the shell gives you a second independent shell; later this is how you open another session to the same host.
- **Rename tab** (double-click a tab, `⌘⇧R`, or right-click -> Rename) - edit the tab's display name inline. The name is per-tab and never touches the underlying process.
- **Close tab** (`⌘W` or the `×` on the tab). Closing the **last** tab does not leave an empty window - it opens a fresh Shell tab in its place.
- **Select tab** (`⌘1`…`⌘9`) - jump to the Nth tab.

Each tab owns its own `CockpitTerminalView` (so screenshot-paste works on every tab) and a `TabLaunch` recipe describing how to (re)start its process. That recipe is what makes duplicate and reconnect one-liners, and adding a `.ssh(...)` case later is how hosts plug in.

The initial set is still **Shell + Mirror**, so nothing from Phase 2 regresses.

### Scrolling and scrollback

Shell tabs scroll **smoothly and content-wise** (line by line, to the exact line) on trackpad and mouse wheel - the WezTerm feel. That comes from the pinned SwiftTerm 1.15's `scrollWheel`, which accumulates precise trackpad deltas and converts them to whole lines 1:1 with no page-jumps (`scrollSensitivity` defaults to a native `1.0`). Every terminal is given a **10,000-line scrollback** (SwiftTerm defaults to only 500) so history that scrolls off the top stays reachable. The **Mirror** tab runs tmux on the alternate screen, so it pages rather than smooth-scrolls - that is inherent to full-screen apps, not something to force.

The design and the exact API shapes used here come from the native design scout report at `data/cockpit-native-design-scout/report.md` (Phase 2 is section 7, terminal attach is 4.3, feature mapping is section 6, the Helm visual language is section 9).

## Hosts: the SSH connection manager (Phase 1)

Phase 1 turns the console into a **Termius-style host manager** on top of the Phase 0 tab model (design doc: `data/cockpit-ssh-manager-research/report.md`, Sections A2/A3, C1, and Section D Phase 1). The window now has a **Hosts sidebar** on the left and the tabbed console on the right.

- **Save hosts.** A host has a Label, Address, Port (default 22), Username, an optional credentials section, and a **per-host icon + accent colour** (A3). Hosts are `Codable` and persisted to `~/Library/Application Support/FirstmateCockpit/hosts.json` (override with `FM_HOSTS_FILE`). This is the native app's first on-disk persistence.
- **Secrets stay off disk.** Phase 1 does **not** ship a secure key store (that is Phase 2's Keychain / Secure Enclave work). The only persisted credential is a *path* to an on-disk private key (`ssh -i`); a typed-in password is held in memory for the session only and never written to the JSON file. With no key set, `ssh` falls back to the system agent / `known_hosts` and prompts interactively on the PTY.
- **Per-host icons.** Each host picks an SF Symbol and a Helm accent colour, shown in the sidebar row and carried onto the connected tab's chip.
- **Quick-connect.** The "Find a host or `ssh user@host`" field matches a saved host (by label, or the single filtered result) or parses an ad-hoc `[user@]host[:port]` and connects it.
- **Connect opens a tab.** Double-clicking a host, the **Connect** button, or quick-connect opens a **new console tab** whose process is `ssh` with the host's argv - the near-drop-in from Section C1. SwiftTerm forks the PTY; `ssh` owns the transport and interactive auth. The tab defaults to the host label (Phase 0 rename still works), and **duplicating** it (⌘D) opens a second session to the same host.

Screenshot-paste into Claude works on ssh tabs too - every tab, including ssh, is a `CockpitTerminalView`.

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
| `main.swift` | App entry, window, main menu (Edit + Tab + View), lifecycle. |
| `ConsoleController.swift` | The tabbed surface: the `[TabModel]` collection, dynamic tab bar, new/duplicate/rename/close, tab switching, theming, zoom, find, copy, reconnect. |
| `TabModel.swift` | One tab: its terminal, display name, and `TabLaunch` (re)start recipe. |
| `TabChipView.swift` | A tab-bar chip: click to select, double-click / right-click to rename, `×` to close. |
| `CockpitTerminalView.swift` | The Phase 1 paste-hardening `LocalProcessTerminalView` subclass, verbatim. Every tab uses it. |
| `TerminalEnvironment.swift` | How a terminal child is spawned (`$SHELL -l`, cwd, UTF-8 env), and the mirror target. |
| `TmuxMirror.swift` | The grouped-session setup/teardown ported from `backend/terminal.py`. |
| `HelmTheme.swift` | The Helm dark/light palettes as SwiftTerm colours (OKLCH tokens pre-converted to sRGB). |
| `Host.swift` | The saved-SSH-host value type, the icon/colour catalogue, and the `ssh` argv builder + quick-connect parser (Phase 1). |
| `HostStore.swift` | Host persistence: a JSON file of profiles under Application Support. Secrets are never written (Phase 2 owns the key store). |
| `HostsSidebarController.swift` | The Termius-style Hosts sidebar: list with per-host icons, quick-connect, add/edit/delete. Hands a `ssh` argv to the console. |
| `HostEditorController.swift` | The add/edit host sheet: Label, Address, Port, Username, credentials, and the icon/colour pickers. |

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
| `⌘T` | New shell tab (also the `+` button) |
| `⌘D` | Duplicate the current tab (same argv) |
| `⌘⇧R` | Rename the current tab (also double-click / right-click -> Rename) |
| `⌘W` | Close the current tab (last tab is replaced by a fresh shell) |
| `⌘1`…`⌘9` | Select the Nth tab |
| `⌘F` | Find in the active terminal |
| `⌘+` / `⌘−` / `⌘0` | Zoom in / out / reset |
| `⌘⌥T` | Toggle Helm light/dark |
| `⌘R` | Reconnect the active tab (re-attach the mirror, or restart the shell) |
| `⌘V` | Paste (drives screenshot-paste into Claude) |
| `⌘C` | Copy selection |
| `⌘N` | New host (opens the host editor) |
| `⌘K` | Focus the quick-connect field |
| `⌘⌃S` | Toggle the Hosts sidebar |

The tab operations are on the **Tab** menu, zoom + theme are on the **View** menu, the host operations are on the **Hosts** menu, and the top bar carries the tab chips, the `+` button, find, zoom, and theme.

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
- [ ] Switching Shell ↔ Mirror by clicking the tab chips (or `⌘1` / `⌘2`) is instant, keeps each tab's state, and focus lands in the shown terminal.

**(c2) Dynamic tabs - the foundation work**
- [ ] `⌘T` (or the `+` button) opens a new Shell tab; run commands in it to confirm it is a live, independent shell.
- [ ] `⌘D` duplicates the current tab - e.g. from a shell, you get a second shell running the same `$SHELL -l`. Both tabs work at the same time (type in one, switch, type in the other).
- [ ] Double-click a tab (or `⌘⇧R`, or right-click -> Rename) and type a new name; `↵` commits, `Esc` cancels. The name changes but the process keeps running (its scrollback/history is intact).
- [ ] `⌘W` closes the current tab. Close down to one tab, then `⌘W` again - the window is **not** left empty; a fresh Shell tab takes its place.
- [ ] Open several tabs and jump between them with `⌘1`…`⌘9`.

**(c3) Smooth, content-wise scrolling (the captain's ask)**
- [ ] In a **Shell** tab, print a lot of output (e.g. `seq 1 500` or `ls -R /usr`), then scroll up with the trackpad/mouse wheel. Scrolling is **smooth and line-by-line to the exact line** (WezTerm feel), not page-at-a-time.
- [ ] Scroll all the way back up - history well past one screen is retained (10,000-line scrollback).
- [ ] Note: the **Mirror** tab (tmux, alt-screen) pages instead of smooth-scrolling. That is expected for a full-screen app.

**(d) Search / zoom / copy work**
- [ ] `⌘F` opens the find bar in the active terminal; typing highlights matches; `↵` / `⇧↵` step through them.
- [ ] `⌘+` / `⌘−` change the terminal font size live on both tabs; `⌘0` resets.
- [ ] Select text and `⌘C`; it lands on the system clipboard (paste it elsewhere to confirm).

**(e) Theming (dark/light) looks right**
- [ ] `⌘⌥T` toggles the terminal (and the top bar) between Helm dark and Helm light. Both should read as the same instrument panel as the web cockpit, with legible text in either mode.

**(f) Paste still works on both tabs**
- [ ] In a tab, run `claude` (Claude Code). Take a screenshot to the clipboard (`⌘⌃⇧4`, then select a region). With the window focused, `⌘V`. Confirm Claude Code registers a pasted image.
- [ ] Repeat on the other tab - both share the same paste wiring.

**(g) Hosts - the SSH connection manager (Phase 1)**
- [ ] The **Hosts** sidebar shows on the left. `⌘N` (or the `+` in the sidebar header) opens the host editor.
- [ ] Add a host: fill Label, Address, Username, pick an **icon** and an **accent colour**, Save. The host appears in the sidebar with that icon tinted in the chosen colour, and it **persists across a relaunch** (quit and reopen - it is still there). Confirm the file at `~/Library/Application Support/FirstmateCockpit/hosts.json` exists and contains **no password** (secrets stay off disk).
- [ ] **Connect over SSH:** double-click the host (or select it and click **Connect**). A **new tab** opens whose process is `ssh` to that host - you land at the remote login/auth prompt. The tab is named after the host label and its chip carries the host's accent colour.
- [ ] **Quick-connect a saved host:** type part of a host's label in the "Find a host…" field; the list filters. Press `↵` to connect the match.
- [ ] **Quick-connect ad-hoc:** type `ssh user@somehost` (or `user@somehost:2222`) in the field and press `↵` - a new ssh tab opens to that destination without saving a host.
- [ ] **Duplicate a host tab** (`⌘D` on a connected ssh tab) opens a **second** independent session to the same host.
- [ ] **Edit** a host (select -> Edit, or right-click -> Edit…): change its icon/colour/fields and Save; the sidebar row updates. **Delete** removes it (with a confirm) and does not disturb any running session.
- [ ] Key path: for a host that needs a key, use **Choose…** to point at an on-disk key (e.g. `~/.ssh/id_ed25519`); Connect passes `ssh -i <path>`. With no key, `ssh` uses your agent / prompts as usual.
- [ ] Screenshot-paste (`⌘V`) still works inside an ssh tab.

If those pass, Phase 1 (hosts) is validated. Phase 2 (the secure Keychain / Secure Enclave key store) is next; Phase 3 is the dashboard surfaces + embedded backend.

## Scope guardrails

- Console + the Hosts sidebar only. No dashboard, backend spawning, auth, or packaging.
- No secure key store yet: secrets stay off disk (Phase 2 adds the Keychain / Secure Enclave key store). Phase 1 references an on-disk key path or uses the system ssh agent.
- Does not touch the existing Python cockpit (`backend/`, `desktop.py`). The native app is a separate, growing surface under `native/`.
