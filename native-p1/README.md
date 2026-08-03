# Firstmate Cockpit - Native P1

This is **Phase 1** of the native macOS cockpit rebuild: a minimal Swift + SwiftTerm app whose only job is to prove the two things that justify going native at all.

1. **Native terminal feel** - real scrollback, native selection, native trackpad momentum, glyphs rendered by the OS rather than DOM spans in a WKWebView.
2. **The screenshot-paste-into-Claude round trip** - copy an image to the macOS clipboard, press `Cmd-V` in the terminal where Claude Code is running, and Claude reads the image.

It is deliberately tiny. There is one window and one terminal. No tabs, no tmux mirror, no dashboard, no auth, no packaging. Those are later phases (P2-P4) and are gated on this one validating the premise.

The design and the exact API shapes used here come from the native design scout report at `data/cockpit-native-design-scout/report.md` (sections 3, 4.3, 5, and 7). The paste-hardening subclass is section 5.3 verbatim.

## What this app does

A single AppKit window hosting one SwiftTerm terminal that:

- Forks and runs `$SHELL -l` **in-process** (a real login shell with native scrollback), falling back to `bash -i`. This mirrors `backend/shell.py`.
- Sets `TERM=xterm-256color` and a UTF-8 locale (`LANG`/`LC_ALL=en_US.UTF-8`) in the child environment and drops `TMUX`, matching `terminal.py`/`shell.py`. A Finder-launched GUI app inherits no locale, so box-drawing and glyphs would otherwise fail to decode.
- Opens in `$FM_SHELL_CWD` if that is a directory, else `$HOME`.
- Has a proper **Edit menu with a Paste item** (`Cmd-V`) targeting the first responder, so the paste keystroke routes into the terminal. A plain `swift run` executable has no Paste action otherwise - the old WKWebView got it for free from the browser.
- Uses `CockpitTerminalView: LocalProcessTerminalView`, the paste-hardening subclass from the design report. For an image-only clipboard with bracketed paste mode on, it guarantees the empty bracketed-paste signal (`ESC[200~` `ESC[201~`) that Claude Code watches for before reading the clipboard image.
- Runs **non-sandboxed** (SwiftTerm requires it to fork real programs and reach the clipboard). Running via `swift run` is non-sandboxed by default, which is parity with today's py2app app.

## Requirements

- macOS 13 or newer, Apple Silicon.
- Swift 6.x toolchain. **Command Line Tools only is enough** - this uses `swift build` / `swift run`, not Xcode or `xcodebuild`. Verified on Swift 6.3.3, Command Line Tools only.

## Build

```bash
cd native-p1
swift build
```

First build takes ~90s because it compiles SwiftTerm from source. The dependency is pinned in `Package.resolved` to SwiftTerm `1.15.0`.

The product is a `Mach-O arm64` executable at `.build/debug/FirstmateCockpitP1`.

## Run

From the package directory:

```bash
swift run
```

or launch the built binary directly:

```bash
.build/debug/FirstmateCockpitP1
```

A window titled **"Firstmate Cockpit - Native P1"** opens with your login shell running inside it.

> Launching an unbundled executable this way is expected for P1. It gets a Dock icon and menu bar because the app sets a regular activation policy. Signing, notarization, and a real `.app` bundle are P4, not this phase.

## Captain validation checklist

This app **cannot be validated headlessly** - the whole point is runtime behavior on your machine. These are the acceptance tests. They are yours to run; the build being green does **not** mean the feel or the paste flow are confirmed.

**1. Terminal feel (vs the web terminal)**

- [ ] Run a command that produces a lot of output (`ls -la /usr/bin`, or `find /usr -maxdepth 3`) and scroll up with the trackpad / mouse wheel. Scrollback should be present and scrolling should feel native and smooth, not the snappy DOM repaint of the web Shell tab.
- [ ] Click-drag to select text. Selection should feel native.
- [ ] Compare directly against the existing web cockpit's Terminal/Shell tab and judge whether native clearly wins. If it does not, that is the signal to stop before P2 - report it.

**2. Screenshot paste into Claude (the must-keep feature)**

- [ ] In the terminal, run `claude` (Claude Code).
- [ ] Take a screenshot to the clipboard: `Cmd-Ctrl-Shift-4`, then select a region (this copies the image to the clipboard instead of saving a file).
- [ ] With the cockpit window focused, press `Cmd-V` (or Edit > Paste).
- [ ] Confirm Claude Code registers a pasted image (it shows an image attachment indicator), the same way it does in the web cockpit today.

If both pass, the native approach is validated and P2 can begin. If either fails, that is exactly what P1 exists to surface.

## Scope guardrails

- P1 only. No tabs, tmux mirror, dashboard, auth, or packaging.
- Does not touch the existing Python cockpit (`backend/`, `desktop.py`). This lives entirely in `native-p1/`.
