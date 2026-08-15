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
relaunch - there's no form to fill in. To set the password for the first time, run:

```
av save GRANDLINE_APP_PASSWORD
```

in a terminal (Automic Vault will prompt you for the value directly, never through this app), or
use Automic Vault's own native app. This terminal command (or Automic Vault's own app) is the
only real path for that first bootstrap - the app's own Vault tab is **not** a valid option here,
even though it has a "+ Add Secret" flow that looks like it would work: the Vault tab lives inside
Grand Line's main UI, which sits behind this same lock screen, so it isn't reachable until you're
already unlocked.

Once that secret exists, relaunch the app and the real password form appears.

Once you're unlocked, the Vault tab's "+ Add Secret" flow becomes a real option again - use it to
update or rotate the password later, not for the very first setup.

If `av` itself isn't installed yet, the lock screen detects that too and offers an "Install
Automic Vault" button right there, which installs the same Homebrew cask the Updates/Vault pages
use - no terminal needed for that part, though you'll still need the terminal (or Automic Vault's
own app) to set the password itself afterward.
