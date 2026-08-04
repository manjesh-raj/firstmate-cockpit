# firstmate-cockpit

A native macOS cockpit to **observe and lightly control** a [firstmate](https://github.com/kunchenguid/firstmate) fleet.

You keep talking to your first mate as usual (in tmux); this gives you a live window onto the whole crew - who's working, what needs a decision, PRs ready to merge - plus a real terminal onto the first mate itself.

The app is a Swift + AppKit + SwiftTerm cockpit under `native/`. It has no server component: it reads the firstmate home's files directly and shells out to its `bin/` scripts, the same guarded helpers a human would run (`fm-crew-state.sh`, `fm-pr-merge.sh`, `fm-send.sh`, etc.). **firstmate is never modified** - the cockpit only reads it and calls those helpers.

An earlier version of this project was a Python/FastAPI backend wrapped in a WKWebView shell. That app has been fully retired in favor of the native cockpit; see `native/README.md` for everything about building, running, and using it.

## Build and run

See `native/README.md` for full instructions, including `swift build`/`swift run` for development and `native/build_native_app.sh` to package a double-clickable `dist/Firstmate.app`.

## Layout

```
native/    the cockpit app (Swift, AppKit, SwiftTerm)
assets/    shared app icon source files
```
