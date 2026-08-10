# Manjesh Grand Line - Native

(formerly "Firstmate Cockpit")

This is the growing native macOS cockpit: a Swift + SwiftTerm app that replaces the web (xterm.js-in-WKWebView) terminal with a real, native one.

"Phase N" below refers to the connection-manager phases in the design report (`data/cockpit-ssh-manager-research/report.md`, Section D): Phase 0 the tab collection, Phase 1 hosts, Phase 2 the SSH keychain (this section), Phase 3+ dashboard/backend/packaging.

**The tabbed console** turns a single terminal into a proper tabbed console with both terminal modes and terminal-level polish:

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

The initial set is still **Shell + Mirror**, so nothing from the tabbed console above regresses.

### Scrolling and scrollback

Shell tabs scroll **smoothly and content-wise** (line by line, to the exact line) on trackpad and mouse wheel - the WezTerm feel. That comes from the pinned SwiftTerm 1.15's `scrollWheel`, which accumulates precise trackpad deltas and converts them to whole lines 1:1 with no page-jumps (`scrollSensitivity` defaults to a native `1.0`). Every terminal is given a **10,000-line scrollback** (SwiftTerm defaults to only 500) so history that scrolls off the top stays reachable. The **Mirror** tab runs tmux on the alternate screen, so it pages rather than smooth-scrolls - that is inherent to full-screen apps, not something to force.

The design and the exact API shapes used here come from the native design scout report at `data/cockpit-native-design-scout/report.md` (Phase 2 is section 7, terminal attach is 4.3, feature mapping is section 6, the Helm visual language is section 9).

## Hosts: the SSH connection manager (Phase 1)

Phase 1 turns the console into a **Termius-style host manager** on top of the Phase 0 tab model (design doc: `data/cockpit-ssh-manager-research/report.md`, Sections A2/A3, C1, and Section D Phase 1). The window now has a **Hosts sidebar** on the left and the tabbed console on the right.

- **Save hosts.** A host has a Label, Address, Port (default 22), Username, an optional credentials section, and a **per-host icon + accent colour** (A3). Hosts are `Codable` and persisted to `~/Library/Application Support/FirstmateCockpit/hosts.json` (override with `FM_HOSTS_FILE`). This is the native app's first on-disk persistence.
- **Secrets stay off disk.** A host's credential is either a **saved key** chosen from the Phase 2 Keychain (a `keyID` reference, resolved at connect time - see below) or nothing, in which case `ssh` falls back to the system agent / `known_hosts` and prompts interactively on the PTY. A typed-in password is held in memory for the session only and never written to the JSON file.
- **Per-host icons.** Each host picks an SF Symbol and a Helm accent colour, shown in the sidebar row and carried onto the connected tab's chip.
- **Quick-connect.** The "Find a host or `ssh user@host`" field matches a saved host (by label, or the single filtered result) or parses an ad-hoc `[user@]host[:port]` and connects it.
- **Connect opens a tab.** Double-clicking a host, the **Connect** button, or quick-connect opens a **new console tab** whose process is `ssh` with the host's argv - the near-drop-in from Section C1. SwiftTerm forks the PTY; `ssh` owns the transport and interactive auth. The tab defaults to the host label (Phase 0 rename still works), and **duplicating** it (⌘D) opens a second session to the same host.

Screenshot-paste into Claude works on ssh tabs too - every tab, including ssh, is a `CockpitTerminalView`.

## SSH Keys: the Keychain (Phase 2)

Phase 2 replaces Phase 1's "on-disk key path" credential with a real saved-key store (design doc Sections A1, C3, Section D Phase 2). **Keys menu -> Manage Keys…** (`⌘⇧K`) opens a separate "SSH Keys" window - a source-list screen in the same visual language as the Hosts sidebar - for browsing, adding, editing, and deleting saved keys.

- **New Key** (Keys menu -> New Key…, `⌘⇧N`, or the `+` in the Keys window): Label, then either **Generate** (Ed25519 default, RSA 3072-bit option, optional passphrase) or **Import** (paste into a text box, drag a key file onto the drop zone, or use "Import from Key File…"). PEM and OpenSSH-format private keys are supported; `.ppk` (PuTTY) files are detected and rejected with a clear message pointing at `puttygen ... -O private-openssh` rather than a half-working parse. An optional Certificate can be pasted alongside either path. There is no "paste your public key" field - matching the real Termius flow, the public key is **derived** (via `ssh-keygen`) and shown read-only with a Copy button.
- **Saved-keys list**: each row shows the Label, a type badge ("Ed25519" / "RSA"), and a truncated fingerprint, tinted per-type from the Helm palette.
- **Secure storage.** Private key bytes and any passphrase are written to the **macOS Keychain** (`Security.framework`, `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` in `KeychainKeyStore.swift`) - never to `keys.json`, which holds only non-secret metadata (label, type, the derived public key, fingerprint, certificate). Every Keychain item's `SecAccessControl` requires the device to be unlocked and a fresh **Touch ID** challenge (or the device passcode, where biometry isn't enrolled) to succeed, and is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` - it never syncs to iCloud Keychain. See `KeychainKeyStore.swift`'s header comment for the one known caveat: an **unsigned** `swift build`/`swift run` binary has no stable code-signing identity, so a rebuild can occasionally trigger an extra Keychain-access prompt or, rarely, be unable to re-read an item an earlier build wrote. That resolves once the app is signed (Phase 4 packaging) and is not a flaw in the storage design.
- **No hand-rolled crypto.** Generation and import both shell out to the system `/usr/bin/ssh-keygen` (`SSHKeyGenerator.swift`) rather than reimplementing the OpenSSH private-key format or its bcrypt-pbkdf passphrase KDF in Swift - the same "delegate, don't reimplement" principle the design report applies to host-key trust. All work happens in a private `0700` scratch directory deleted immediately after the bytes are read into memory.
- **Wiring hosts to keys.** The host editor's credential section is a "Choose a key" popup sourced from the saved-keys list (`keyID` on `Host`, replacing Phase 1's raw path field). At connect time, `ConsoleController.connectSSH` resolves the chosen key through `SSHKeyMaterializer`: a Keychain read (the Touch ID prompt happens here) into a private, `0600` temp file under a fresh `0700` scratch directory, passed as `ssh -i <path>` (plus an adjacent `-cert.pub` if the key carries a certificate). That scratch directory is deleted on tab close, on reconnect (before making a new one), on process exit, and on quit - it never outlives the connection that needed it.

## Power features (Phase 3)

Phase 3 (design doc Sections B1, B2, B4, B5, Section D Phase 3) adds the features that make this usable against real infra, on top of the Phase 0-2 tab/host/key model. All of it is either extra `Host` fields or extra `ssh` argv - no new transport code, per the "delegate to `ssh`, don't reimplement" principle already used for keys and host-key trust.

- **Jump hosts / ProxyJump.** The host editor's **Jump via** field takes either another saved host's label or a raw `user@bastion[:port]`. `HostCatalog.proxyJumpChain` resolves it at connect time and, if *that* host also has a `Jump via`, follows it transitively, building a `-J a,b,c` chain (capped at 8 hops against a label cycle).
- **SSH agent forwarding.** A **"Forward SSH agent (-A)"** checkbox on the host editor. The system agent's own keys (via `SSH_AUTH_SOCK`, already inherited into every child's environment by `childEnvironmentDict`) become usable on the remote host without ever putting them in this app's Keychain store.
- **Known-hosts surfacing.** No new UI - verified by inspection rather than reimplemented: `connectSSH` never passes `-o StrictHostKeyChecking=...`, and no output filtering sits between the child's PTY and the terminal on the ssh path (the same `startProcess`/`dataReceived` path the Shell tab already uses). The interactive "authenticity of host" and "REMOTE HOST IDENTIFICATION HAS CHANGED" prompts render and are answerable in the terminal exactly as in Terminal.app, driven entirely by the system `ssh` and `~/.ssh/known_hosts`.
- **Groups + tags.** `Host.group`/`Host.tags` (present since Phase 1 but unused) now drive the sidebar: hosts are grouped into labeled sections (skipped entirely when every visible host shares one group, so a flat list stays flat), and a row of tag chips beneath the search field filters the list to hosts carrying the tapped tag(s) - in addition to the search field already matching tags by text.
- **Port forwarding.** A **"Port Forwarding…"** button on the host editor opens `PortForwardingController` as a nested sheet: add/remove Local (`-L`), Remote (`-R`), and Dynamic/SOCKS (`-D`) rules, each with bind address, listen port, and (for Local/Remote) a destination host/port. Saved per host as `Host.portForwards`.
- **Snippets.** A saved-command library (`SnippetStore`, `snippets.json`), managed from its own **Snippets** window (Snippets menu, `⌘⌥N` / `⌘⌥P`) - Label + command text, and a **Run** that sends the command plus Enter to the console's active tab. A host can also name one as its **Startup snippet**; `ConsoleController.runStartupSnippet` sends it a fixed 1.5s after the ssh process starts - there is no protocol-level "the remote shell is ready" signal to hook, so this is deliberately best-effort, matching the design doc's "best-effort timing is fine for v1."
- **Session logging.** The toolbar's record-circle icon (also `⌘⇧L` / Tab menu -> Toggle Session Logging) toggles a plain-text transcript of the active tab's host output to `~/Library/Application Support/FirstmateCockpit/logs/<tab>-<timestamp>.log`. Implemented as a `dataReceived` override in `CockpitTerminalView` that tees raw bytes to a `FileHandle` before feeding the terminal - not SwiftTerm's own `setHostLogging(directory:)`, which writes one file per read syscall rather than a single chronological transcript. `FM_LOG_SESSIONS_DEFAULT=1` turns logging on for every newly started tab by default.

## What is and is not in this build

**In scope (built here):**

- A two-tab console surface hosting two SwiftTerm terminals.
- The tmux grouped-session lifecycle, **ported to Swift** (`Process`) so the console needs **no Python backend running** (that is Phase 3).
- Helm dark + light palettes applied to the terminal colour set (foreground/background/cursor/selection + a full 16-colour ANSI set).
- Native find bar, font zoom, and copy-to-`NSPasteboard`, all on the top bar and the main menu.
- Jump hosts, agent forwarding, known-hosts surfacing, groups/tags, port forwarding, snippets, and session logging (Phase 3, see above).

**Deliberately out of scope (later phases):** no dashboard / fleet view / PR list, no Python backend spawning or embedding, no auth, no packaging / signing / notarization, no SFTP browser, no split panes, no encrypted cross-device sync (Phase 4). This is the console + connection manager only.

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
| `Host.swift` | The saved-SSH-host value type (`keyID` reference, no path/secret), the icon/colour catalogue, and the `ssh` argv builder + quick-connect parser (Phase 1). |
| `HostStore.swift` | Host persistence: a JSON file of profiles under Application Support. Secrets are never written. |
| `HostsSidebarController.swift` | The Termius-style Hosts sidebar: list with per-host icons, quick-connect, add/edit/delete. Hands a `ssh` argv + `keyID` to the console. |
| `HostEditorController.swift` | The add/edit host sheet: Label, Address, Port, Username, credentials (incl. the "Choose a key" popup), and the icon/colour pickers. |
| `SSHKey.swift` | Non-secret key metadata (label, type, derived public key, fingerprint, certificate) - Phase 2. |
| `SSHKeyStore.swift` | Key metadata persistence: a JSON file under Application Support, mirroring `HostStore`. |
| `KeychainKeyStore.swift` | The secret store: private key bytes + passphrase in the macOS Keychain, gated by a Touch ID / passcode `SecAccessControl`. |
| `SSHKeyGenerator.swift` | Generate (Ed25519/RSA) and inspect (PEM/OpenSSH import validation, fingerprint, type) by shelling out to `ssh-keygen`. |
| `SSHKeyMaterializer.swift` | Resolves a saved key into a private `0600` temp file for `ssh -i` at connect time, and cleans it up after. |
| `KeysSidebarController.swift` | The "SSH Keys" screen: a saved-keys list in its own window, matching the Hosts sidebar's visual language. |
| `KeyEditorController.swift` | The New/Edit Key sheet: Generate vs. Import, drag-and-drop, passphrase, certificate, and the read-only derived public key. |
| `PortForwardingController.swift` | Phase 3: the "Port Forwarding" sheet - add/remove Local/Remote/Dynamic rules for a host. |
| `Snippet.swift` | Phase 3: the saved-command value type (label + command text). |
| `SnippetStore.swift` | Phase 3: snippet persistence, mirroring `HostStore`/`SSHKeyStore`. |
| `SnippetsController.swift` | Phase 3: the "Snippets" screen - list, Run (to the active tab), edit, delete. |
| `SnippetEditorController.swift` | Phase 3: the New/Edit Snippet sheet. |

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

First build takes ~90s because it compiles SwiftTerm from source. SwiftTerm is vendored at `Vendor/SwiftTerm/` (pinned to upstream `1.15.0`, with a small local patch - see `Vendor/SwiftTerm/README.md`), not fetched over SPM, so there's no `Package.resolved` and no network access needed to build. The product is a `Mach-O arm64` executable at `.build/debug/FirstmateCockpit`.

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

A window titled **"Manjesh Grand Line"** opens on the **Shell** tab.

> Launching an unbundled executable this way is expected pre-P4. It gets a Dock icon and menu bar because the app sets a regular activation policy. Signing and notarization for real distribution are still Phase 4 - see "Package as an app" below for a double-clickable local bundle in the meantime.

## Package as an app

`./build_native_app.sh` (run from `native/`) builds a release binary with `swift build -c release` and assembles it into a real, double-clickable bundle at `dist/Manjesh Grand Line.app` - no notarization, no DMG - but it's a proper `Contents/{MacOS,Resources}/Info.plist` bundle, so Finder and Spotlight treat it like any other app.

```bash
cd native
./build_native_app.sh
open "../dist/Manjesh Grand Line.app"
```

This is the one and only app built from this repo (bundle ID `com.firstmate.cockpit.native`, unchanged by the app's rename - see the identifier note in this repo's `AGENTS.md`). An earlier web/WKWebView app used to occupy this same `dist/` path via a root-level `build_app.sh` and py2app - that codebase has been removed, so there's no longer anything to disambiguate from.

### Local signing setup

`build_native_app.sh` codesigns the assembled `.app` with a local, self-signed identity named **"Firstmate Cockpit Local Dev"**, if that identity exists on the machine. This matters for more than tidiness: saved SSH keys live in the macOS Keychain (see "SSH Keys" above), and Keychain's default per-item ACL trusts only the app identity that created the item. An unsigned/ad-hoc build gets a *different* code identity on every single rebuild, so a Keychain item saved by one build becomes unreadable ("the user name or passphrase you entered is not correct") the moment the next rebuild tries to read it. Signing every build with the same fixed identity keeps Keychain trust stable across rebuilds.

If the identity isn't present, the build script prints a warning and continues unsigned rather than failing - this is a one-time, per-machine setup step, not something CI or every contributor needs.

To create the identity once on a fresh machine:

```bash
# 1. Generate a self-signed cert with the codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -keyout /tmp/fmcockpit.key -out /tmp/fmcockpit.crt \
  -days 3650 -nodes -subj "/CN=Firstmate Cockpit Local Dev" \
  -addext "extendedKeyUsage=critical,codeSigning"

# 2. Package it as a .p12. The `-legacy` flag is required: modern OpenSSL 3.x's
#    default PKCS12 encryption isn't readable by macOS's importer without it.
openssl pkcs12 -export -legacy -inkey /tmp/fmcockpit.key -in /tmp/fmcockpit.crt \
  -out /tmp/fmcockpit.p12 -passout pass:temporary

# 3. Import into the login keychain, trusted for codesign specifically.
security import /tmp/fmcockpit.p12 -k ~/Library/Keychains/login.keychain-db \
  -P temporary -T /usr/bin/codesign

# 4. Trust the cert for code signing. Note `-r trustRoot`, not `-r trustAsRoot` -
#    the latter fails with a parameter error on this cert shape.
security add-trusted-cert -d -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db \
  /tmp/fmcockpit.crt

rm -f /tmp/fmcockpit.key /tmp/fmcockpit.crt /tmp/fmcockpit.p12
```

Verify with `security find-identity -v -p codesigning | grep "Firstmate Cockpit Local Dev"` - it should list one valid identity. The next `./build_native_app.sh` run will then sign automatically.

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
| `⌘⇧N` | New key (opens the "SSH Keys" window and its New Key sheet) |
| `⌘⇧K` | Manage Keys… (opens/brings forward the "SSH Keys" window) |
| `⌘⇧L` | Toggle session logging for the active tab |
| `⌘⌥N` | New snippet (opens the "Snippets" window and its New Snippet sheet) |
| `⌘⌥P` | Manage Snippets… (opens/brings forward the "Snippets" window) |

The tab operations are on the **Tab** menu, zoom + theme are on the **View** menu, the host operations are on the **Hosts** menu, snippets are on the **Snippets** menu, and the top bar carries the tab chips, the `+` button, find, zoom, theme, and the session-log toggle.

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
- [ ] Screenshot-paste (`⌘V`) still works inside an ssh tab.

**(h) SSH Keys - the Keychain (Phase 2)**
- [ ] **Keys menu -> Manage Keys…** (`⌘⇧K`) opens the "SSH Keys" window. `⌘⇧N` (or the `+` in that window) opens the New Key sheet.
- [ ] **Generate a key:** Label, leave Generate/Ed25519 selected, optionally set a passphrase, click **Generate**. The derived public key appears read-only with a fingerprint; **Copy** puts it on the clipboard (paste it elsewhere to confirm). Save - the key appears in the list with an "Ed25519" badge.
- [ ] **Generate an RSA key** the same way with the RSA segment selected; confirm the badge reads "RSA".
- [ ] **Import a real PEM file via drag-and-drop:** switch to Import, drag an existing private key file (e.g. `~/.ssh/id_ed25519` or a `.pem`) onto the drop zone. It should auto-verify and show the derived public key; if the key has a passphrase, type it and click **Verify** to see a green "Verified" status. Save - it appears in the saved-keys list.
- [ ] **Import via the file picker** ("Import from Key File…") as an alternative to drag-and-drop, same result.
- [ ] **Import via paste:** paste private key text directly into the "Or paste the private key" box and click Verify.
- [ ] **Reject a `.ppk` file** cleanly: dropping/importing a PuTTY key shows the "convert with `puttygen`" message rather than a confusing failure.
- [ ] **Edit a host to pick a key:** open a host (New Host or Edit), the credentials section now shows a **"Key"** popup listing "None" plus every saved key by label/type; choose one and Save.
- [ ] **Connect using it:** Connect that host. Confirm a **Touch ID (or passcode) prompt** appears at connect time (this is the Keychain read in `SSHKeyMaterializer`), and that `ssh` receives `-i <path>` (e.g. by watching for the identity file being tried, or by using a key you know matches the remote's `authorized_keys`).
- [ ] Confirm `~/Library/Application Support/FirstmateCockpit/keys.json` exists and contains **no private key bytes or passphrase** - only label/type/public key/fingerprint/certificate.
- [ ] **Edit** a key: rename it, add/change a certificate, and optionally set a new passphrase (leaving it blank keeps the existing one) - no Touch ID prompt unless you actually typed a new passphrase. **Delete** a key (with a confirm) and confirm a host that referenced it now shows "None" and falls back to the system agent on connect.
- [ ] **Duplicate/reconnect a connected ssh tab that uses a key** (`⌘D`, `⌘R`) and confirm each resolves the key independently (a fresh Touch ID prompt / temp file per tab-start), not a stale/shared one.

If those pass, all five of the captain's original connection-manager requirements (keychain, hosts, per-host icons, duplicate tabs, rename tabs) are validated end to end.

**(i) Jump hosts (Phase 3)**
- [ ] Add a bastion host (e.g. `bastion`), then add a target host whose **Jump via** field is set to the bastion's label. Connect the target - the `ssh` invocation includes `-J <bastion destination>` (confirm by watching the connection prompt for the bastion, or via a key you know is bastion-only).
- [ ] Set the bastion's own **Jump via** to a second bastion (or a raw `user@other-bastion`) and reconnect the target - the chain is now two hops (`-J a,b`).
- [ ] A raw `user@bastion[:port]` in **Jump via** (no matching saved host) works the same way without needing a saved host.

**(j) Agent forwarding (Phase 3)**
- [ ] With a key loaded in your local `ssh-agent` (`ssh-add -l` shows it) and a host that has **that** key set up in `authorized_keys`, enable **"Forward SSH agent (-A)"** on a *different* host that chains to it, and confirm you can `ssh` onward from the remote shell using the forwarded agent (e.g. `ssh-add -l` on the remote shows the same key).

**(k) Known-hosts prompts (Phase 3)**
- [ ] Connect to a host you have never connected to before (or `ssh-keygen -R <host>` first to force it) - the "authenticity of host … can't be established" prompt appears **inside the tab** and typing `yes` + Return proceeds normally.
- [ ] If a remote host's key ever changes, confirm the loud "REMOTE HOST IDENTIFICATION HAS CHANGED" warning also renders in the tab (safe to test by editing a stale `known_hosts` line's key to a bogus value for a host you control, then reconnecting).

**(l) Groups + tags (Phase 3)**
- [ ] Give two hosts different **Group** values (and leave a third blank) - the sidebar now shows labeled sections (named groups, then "Ungrouped"), sorted alphabetically. With everything in one (or no) group, no headers appear.
- [ ] Add **Tags** (comma-separated) to a couple of hosts - a row of tag chips appears under the search field. Click a chip - the list filters to hosts carrying that tag; click it again to clear.
- [ ] Typing a tag name directly into the search field also filters (this already worked before Phase 3 - confirm it still does).

**(m) Port forwarding (Phase 3)**
- [ ] Open a host's editor, click **"Port Forwarding…"**, add a Local rule (e.g. listen `8080` -> `localhost:80` on the remote), Save both sheets, then Connect. Confirm `curl localhost:8080` on your Mac reaches the remote's port 80.
- [ ] Add a Dynamic rule (e.g. listen `1080`) and confirm a SOCKS-aware client (e.g. `curl --socks5 localhost:1080 ...`) can route through it.
- [ ] The rule count shows on the editor's button (`"Port Forwarding (2)…"`) and rules persist across a relaunch.

**(n) Snippets (Phase 3)**
- [ ] Snippets menu -> **New Snippet…**, give it a Label and a command (e.g. `echo hello`), Save. It appears in the Snippets window's list.
- [ ] With a terminal tab focused, select the snippet and click **Run** (or double-click it) - the command runs in that tab.
- [ ] Set a host's **Startup snippet** to a saved snippet, Connect, and confirm the snippet's command runs automatically in the new ssh tab shortly after the shell prompt appears (best-effort timing - if the connection is unusually slow, it may fire before the prompt; this is a known v1 tradeoff).

**(o) Session logging (Phase 3)**
- [ ] Click the record-circle icon in the toolbar (or `⌘⇧L`) on an active tab - it turns solid red. Run a few commands, toggle it off. Confirm a new file appeared under `~/Library/Application Support/FirstmateCockpit/logs/` named after the tab and a timestamp, containing the raw terminal output.
- [ ] Toggling logging on again on the same tab starts a **new** file rather than appending to the old one.
- [ ] Relaunch with `FM_LOG_SESSIONS_DEFAULT=1` and confirm a fresh log file appears for every tab opened, without touching the toggle.

## Scope guardrails

- Console + the Hosts sidebar + the SSH Keys window + the Snippets window only. No dashboard, backend spawning, auth, or packaging.
- Secrets (private key bytes, passphrases) live only in the macOS Keychain, Touch-ID/passcode gated (`KeychainKeyStore.swift`). Non-secret metadata (hosts, key labels/public keys/fingerprints, port-forward rules, snippets) lives in plain JSON under Application Support. `.ppk` (PuTTY) import is explicitly unsupported, not silently mishandled - see the Keys section above.
- Session logs are plain text under Application Support, not sanitized or redacted - a logged session's transcript can contain anything the remote host printed. Treat the `logs/` directory the same way you would treat terminal scrollback.
- Jump hosts, port forwarding, and agent forwarding are all just extra `ssh` argv - this app does not re-implement any part of the SSH protocol, host-key trust, or the SSH agent protocol.
- Deferred out of this pass: SFTP, split panes, encrypted cross-device sync/vault, broadcast-snippet-to-all-tabs (Phase 4 / nice-to-have).
- This native app is the only cockpit in this repo; the earlier Python/WKWebView cockpit it replaced has been removed.
