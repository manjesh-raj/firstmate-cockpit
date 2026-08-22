# firstmate-cockpit

A native macOS cockpit to **observe and lightly control** a [firstmate](https://github.com/kunchenguid/firstmate) fleet.

You keep talking to your first mate as usual (in tmux); this gives you a live window onto the whole crew - who's working, what needs a decision, PRs ready to merge - plus a real terminal onto the first mate itself.

The app is a Swift + AppKit + SwiftTerm cockpit under `native/`. It has no server component: it reads the firstmate home's files directly and shells out to its `bin/` scripts, the same guarded helpers a human would run (`fm-crew-state.sh`, `fm-pr-merge.sh`, `fm-send.sh`, etc.). **firstmate is never modified** - the cockpit only reads it and calls those helpers.

An earlier version of this project was a Python/FastAPI backend wrapped in a WKWebView shell. That app has been fully retired in favor of the native cockpit; see `native/README.md` for everything about building, running, and using it.

## Build and run

See `native/README.md` for full instructions, including `swift build`/`swift run` for development and `native/build_native_app.sh` to package a double-clickable `dist/Manjesh Grand Line.app`.

The app's version is derived from `git describe`, so a release is cut by tagging (`git tag -a v0.2.0 -m ...`) rather than by editing a constant.

## ⚠️ Never launch a built copy from a worktree

Every build of this app - a `swift run` binary, `.build/debug/FirstmateCockpit`, and the packaged `dist/Manjesh Grand Line.app` - shares one bundle identity (`com.firstmate.cockpit.native`).
There is no OS-level process isolation between them.

So launching a copy you just built in a git worktree can replace, disturb, or be replaced by the instance already running on the machine, and both then write to the same JSON stores and the same Shift git working tree.

When you are working on this codebase in a worktree:

- Verify changes with `swift build` (compile check) plus the self-test suites below.
- Do **not** run `swift run`, and do not open the assembled `.app`.
- If you genuinely need a rendered screenshot, ask for one from the already-running instance rather than starting a second process.

As of the phase-1 stabilisation pass the app also refuses to *be* a second instance (`SingleInstanceGuard` plus `LSMultipleInstancesProhibited`), which turns most of this from silent corruption into a clean "already running" exit - but the rule above still stands, because the guard activates the existing instance rather than giving you a separate one to test against.

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request (GL-07): `swift build`
with a hard failure on any warning in this app's own sources, plus the headless-safe
self-test subset via `./Scripts/run-all-tests.sh --ci`.

`--ci` skips the suites that need a real login session (they create real `NSWindow`s and
drive real AppKit layout) or the machine's own Keychain. That list lives in the script
itself, one entry per line with a reason, so CI and a local run can never disagree about
what "the tests" are - and a locally-passing suite that CI skips shows up as a `SKIP` line
rather than silently disappearing.

CI points every `FM_*` data-location override at a scratch directory, so a run never
attempts a real clone of the private config repo and never depends on what the runner's
home directory happens to contain.

## Testing

There is no XCTest target. The app carries 50+ permanent self-test suites, each gated behind its own environment variable and each exiting the process with 0 or 1 before `NSApplication` is ever touched - so they run headless and are safe to run while the real app is open.

They live in `native/Sources/FirstmateCockpit/SelfTests/` and are compiled into **debug builds only** - `Package.swift` defines `FM_SELFTESTS` for the debug configuration. So `swift build` (and CI, and the runner below) has every suite, while `swift build -c release` - what `native/build_native_app.sh` assembles the shipped `.app` from - contains none of the ~10,500 lines of test code. A release binary silently runs zero suites and exits 0, which looks exactly like a clean run: always test against `.build/debug/FirstmateCockpit`.

Run all of them:

```
cd native
./Scripts/run-all-tests.sh          # builds, then runs every suite
./Scripts/run-all-tests.sh --list   # just show what would run
./Scripts/run-all-tests.sh FM_RUN_SHIFT_STORE_TESTS   # one or more by name
./Scripts/run-all-tests.sh --ci     # what CI runs: skips session/Keychain suites
```

The runner discovers its suite list from `main.swift`, so a newly added suite is picked up automatically.

Run one directly:

```
cd native
swift build && FM_RUN_SHIFT_STORE_TESTS=1 .build/debug/FirstmateCockpit
```

### Writing a new suite

Follow any existing `*SelfTest.swift`. The convention that matters:

- Pure logic and real-file/subprocess behaviour get a **permanent** suite.
- AppKit rendering and geometry get a **temporary**, env-gated probe that is reverted before commit (see AGENTS.md's "Verifying native UI bugs without a real screenshot").
- A suite must be **confirmed to catch a real regression**, not just to pass. Revert the fix, watch the suite fail, restore it.
- Never touch real captain data. Use the `FM_*` overrides in the table below to point every store at a scratch directory.
- Put the file in `SelfTests/` and wrap its contents in `#if FM_SELFTESTS` / `#endif`, so it stays out of the release binary. `FM_RUN_PHASE3_POLISH_TESTS` fails if a file in that directory is missing the guard.
- A suite that greps the app's own sources must resolve its root through `SelfTestSources.appSourceDirectory()`, never from `#filePath`'s own directory - that would now point at `SelfTests/`, and every such guard *skips* when it cannot find its sentinel, so it would keep printing OK while checking nothing.

## Environment variables

Behaviour overrides. Everything here is optional; the app has working defaults for all of it.

### Data locations (point these at scratch paths in tests)

| Variable | What it overrides |
| --- | --- |
| `FM_HOME` / `FIRSTMATE_HOME` | The firstmate home the app reads fleet state from |
| `FM_HOSTS_FILE` | `hosts.json` (saved SSH hosts) |
| `FM_KEYS_FILE` | `keys.json` (SSH key *metadata*; key material is Keychain-only) |
| `FM_SNIPPETS_FILE` | `snippets.json` |
| `FM_SHIFT_DIR` | Shift's data root. Setting it bypasses git sync entirely, and is also the fallback root for the command library |
| `FM_COMMAND_LIBRARY_DIR` | The DevOps command library only |
| `FM_SHIFT_GIT_CLONE_PATH` | Where the `manjesh-config` clone lives |
| `FM_SHIFT_REMOTE_URL` | The remote Shift clones/pulls/pushes (point at a disposable local bare repo for tests) |
| `FM_DICTATION_DIR` | Dictation history + vocabulary |
| `FM_DOCS_DIR` | The synced DevOps Playbook copy |
| `FM_DOCS_RUNBOOKS_DIR` | Runbooks/postmortems (bypasses git) |
| `FM_LOG_ANALYZER_DIR` | Saved Log Analyzer investigations |
| `FM_WHISPER_MODEL_DIR` | Where the local Whisper model is downloaded |
| `FM_INSTANCE_LOCK_FILE` | The single-instance lock file |

### Behaviour

| Variable | Effect |
| --- | --- |
| `FM_SHELL_CWD` | Working directory for new shell tabs (wins over Settings) |
| `FM_MIRROR_TARGET` | The tmux/herdr session the Mirror tab attaches to (wins over Settings) |
| `FM_BACKEND` | Force `tmux` or `herdr` instead of live detection |
| `FM_BLOCK_VIEW_ENABLED` | Enables Block View at all (still needs a per-host opt-in) |
| `FM_APP_LOCK_IDLE_SECONDS` | Idle re-lock threshold (default 1h) - verification only |
| `FM_APP_LOCK_SESSION_SECONDS` | Hard-logout threshold (default 12h) - verification only |
| `FM_APP_LOCK_POLL_SECONDS` | Lock timer poll interval (default 30s) - verification only |
| `FM_WHISPER_METAL_RESOURCES_OVERRIDE` | Where the Metal shader is looked up (used to test the CPU fallback) |
| `FM_WHISPER_TEST_MODEL_PATH` / `FM_WHISPER_TEST_AUDIO_PATH` | Opt a real model + audio file into the Whisper suite |

### Test suites

`FM_RUN_*_TESTS=1` runs one suite and exits, on a **debug** build (see Testing above). Use `./Scripts/run-all-tests.sh --list` for the current, authoritative list rather than duplicating 50-odd names here.

## Layout

```
native/            the cockpit app (Swift, AppKit, SwiftTerm)
native/Sources/FirstmateCockpit/SelfTests/   the self-test suites (debug builds only)
native/Scripts/    the test runner and build-time helper scripts
native/Vendor/     vendored dependencies (SwiftTerm, YamlSwift, whisper.cpp) - no remote SPM packages
assets/            shared app icon source files
```

## Logs and diagnostics

Every subprocess this app runs goes through one runner (`Subprocess.swift`), and every
non-zero exit, launch failure and timeout is logged there. Logging is `os.Logger` under
one subsystem:

```
log stream --predicate 'subsystem == "com.firstmate.cockpit.native"' --level debug
log show  --predicate 'subsystem == "com.firstmate.cockpit.native"' --last 30m
```

Categories: `subprocess`, `poller`, `git-sync`, `keychain`, `store`, `network`, `ai`,
`ui`, `lifecycle`. Nothing leaves the machine - there is no telemetry in this app.

In-app, **Settings > Health** shows last-run and last-error per background service, with
a "Copy diagnostics" button. A service that fails repeatedly raises a Notification Center
entry that links there.

For the architecture, the AppKit gotcha catalogue, and the per-feature history, read `AGENTS.md`.
<!-- fm detect-test: automatic completion detection check -->
