# Setup guide

Getting a local build of Manjesh Grand Line running, from a clean checkout to an open app.

## Build

From the repo root:

```
cd native
./build_native_app.sh
```

This runs `swift build -c release` and assembles the result into a real, double-clickable
`.app` bundle. It also codesigns the bundle with a local dev identity when one exists on the
machine, which keeps saved SSH keys readable across rebuilds - see `native/README.md`'s "Local
signing setup" section if you haven't set that identity up yet, and for day-to-day `swift build`/
`swift run` development instructions.

## Launch

The build lands at `dist/Manjesh Grand Line.app`, one level up from `native/`:

```
open "../dist/Manjesh Grand Line.app"
```

(or just double-click it in Finder).

## App-lock password

The app is gated by a password lock screen shown before any content is visible. **There is no
default password, and this is intentional** - a fresh build/install always starts with no
`GRANDLINE_APP_PASSWORD` secret configured, rather than shipping with a default credential that
would be trivially discoverable and defeat the whole point of the lock.

Until that secret is set, the lock screen shows a message telling you to configure it and
relaunch - there's no form to fill in. To set the password, run:

```
av save GRANDLINE_APP_PASSWORD
```

in a terminal (Automic Vault will prompt you for the value directly, never through this app), or
use the app's own Vault tab: "+ Add Secret" opens the same "Save a new secret" flow, which reads
the value in a real terminal tab rather than through any field in this app.

Once that secret exists, relaunch the app and the real password form appears.
