#!/usr/bin/env bash
# Run every self-test suite in the app (GL-19).
#
# This project has no XCTest target - it has ~44 permanent self-test suites,
# each gated behind its own `FM_RUN_<NAME>_TESTS=1` environment variable and
# each exiting the process with 0/1 (see any `*SelfTest.swift` header, or
# AGENTS.md's "Verifying native UI bugs" section, for why that convention
# exists). Until this script existed, running "the tests" meant 44 manual
# invocations, which in practice meant nobody ran the ones they had not
# personally written.
#
# The suite list is discovered from `main.swift` rather than hardcoded here, so
# adding a new suite makes it part of this run automatically and this script
# cannot silently drift out of date.
#
# Usage:
#   ./Scripts/run-all-tests.sh              # build, then run every suite
#   ./Scripts/run-all-tests.sh --no-build   # skip `swift build`
#   ./Scripts/run-all-tests.sh --list       # print the discovered suites and exit
#   ./Scripts/run-all-tests.sh --ci         # skip suites that need a real login
#                                           # session (see NEEDS_SESSION below)
#   ./Scripts/run-all-tests.sh FM_RUN_SHIFT_STORE_TESTS FM_RUN_BACKUP_TESTS
#                                           # run only the named suites
#
# SAFETY: this runs the app's own binary, which is safe *because* every one of
# these flags is handled before `NSApplication.shared` is ever touched - the
# process runs headless and exits. Do NOT extend this script to launch the app
# itself: every build of this app shares one bundle identity, so a launched
# copy from a worktree can disturb the captain's real running instance. See the
# README's "Never launch a built copy from a worktree" note.

set -uo pipefail
cd "$(dirname "$0")/.."

BUILD=1
LIST_ONLY=0
CI_MODE=0
REQUESTED=()

for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --list) LIST_ONLY=1 ;;
    --ci) CI_MODE=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    FM_RUN_*) REQUESTED+=("$arg") ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
  esac
done

BIN=".build/debug/FirstmateCockpit"
MAIN="Sources/FirstmateCockpit/main.swift"

# Suites that need something this script cannot provide, with the reason. They
# are reported as SKIP rather than silently dropped - a skipped suite is a real
# coverage gap and should be visible in the output.
#
# Keep this list honest and short: a suite added here because it is *flaky* is a
# bug to fix, not a suite to skip.
SKIP_FLAGS=(
  # Needs a real ~547MB Whisper model on disk plus FM_WHISPER_TEST_MODEL_PATH /
  # FM_WHISPER_TEST_AUDIO_PATH pointing at it. FM_RUN_WHISPER_ENGINE_TESTS
  # covers the model-free half and does run below.
  "FM_RUN_WHISPER_METAL_FALLBACK_ONLY_TEST"
)

# Suites that need something a CI runner does not have. Skipped only with
# --ci - locally they run and should pass, and a suite listed here is a real
# coverage gap in CI, not a suite anyone should stop caring about.
#
# The distinction that matters is a real *login session*: these suites create
# real NSWindows and drive real AppKit layout, which needs a window server.
# A GitHub-hosted macOS runner does have one for the primary user, but a
# self-hosted or headless runner may not, and a suite that hangs waiting for
# one is worse in CI than a suite that is honestly skipped.
NEEDS_SESSION=(
  "FM_RUN_APP_SHELL_BODY_WIDTH_TESTS"
  "FM_RUN_BLOCK_VIEW_HIERARCHY_TESTS"
  "FM_RUN_BLOCK_VIEW_RESTART_TESTS"
  "FM_RUN_BLOCK_VIEW_VOLUME_TESTS"
  "FM_RUN_REVIEW_LOADING_STATE_TESTS"
  "FM_RUN_REVIEW_PR_LIST_VOLUME_TESTS"
  "FM_RUN_REVIEW_PR_ROW_BUTTON_LAYOUT_TESTS"
  "FM_RUN_SRE_LEAD_PER_TAB_TESTS"
  "FM_RUN_NOTIFICATION_CENTER_SRE_LEAD_TESTS"
  "FM_RUN_MIRROR_RESOLVE_RACE_TESTS"
  "FM_RUN_SHIFT_ATTACHMENT_WELL_TESTS"
  "FM_RUN_TERMINAL_WRAP_REDRAW_TESTS"
  "FM_RUN_CONTRAST_TESTS"
  # Reads and writes the machine's real Keychain (and can prompt), which a
  # runner has no unlocked login keychain for.
  "FM_RUN_VAULT_DATA_TESTS"
)

if [ "$CI_MODE" -eq 1 ]; then
  SKIP_FLAGS=("${SKIP_FLAGS[@]}" "${NEEDS_SESSION[@]}")
fi

if [ ! -f "$MAIN" ]; then
  echo "error: $MAIN not found - run this from the repo's native/ directory (or via its own path)." >&2
  exit 1
fi

# Every flag main.swift actually dispatches on, in source order.
# `while read` rather than `mapfile`: macOS ships bash 3.2, which has no
# `mapfile`, and CI runners are not guaranteed a newer one on PATH.
ALL_FLAGS=()
while IFS= read -r flag; do
  ALL_FLAGS=("${ALL_FLAGS[@]}" "$flag")
done < <(grep -oE 'FM_RUN_[A-Z0-9_]+' "$MAIN" | awk '!seen[$0]++')

if [ ${#ALL_FLAGS[@]} -eq 0 ]; then
  echo "error: found no FM_RUN_* flags in $MAIN - has the convention changed?" >&2
  exit 1
fi

if [ ${#REQUESTED[@]} -gt 0 ]; then
  FLAGS=("${REQUESTED[@]}")
else
  FLAGS=("${ALL_FLAGS[@]}")
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "${FLAGS[@]}"
  echo ""
  echo "${#FLAGS[@]} suite(s) discovered in $MAIN."
  exit 0
fi

if [ "$BUILD" -eq 1 ]; then
  echo "==> swift build"
  if ! swift build; then
    echo "BUILD FAILED - not running any suite." >&2
    exit 1
  fi
  echo ""
fi

if [ ! -x "$BIN" ]; then
  echo "error: $BIN not found. Run without --no-build, or `swift build` first." >&2
  exit 1
fi

PASSED=()
FAILED=()
SKIPPED=()

for flag in "${FLAGS[@]}"; do
  skip=0
  for s in "${SKIP_FLAGS[@]}"; do
    [ "$flag" = "$s" ] && skip=1
  done
  if [ "$skip" -eq 1 ]; then
    printf 'SKIP  %s\n' "$flag"
    SKIPPED+=("$flag")
    continue
  fi

  # Each suite's own stdout is captured and only shown on failure - a passing
  # run of 43 suites is thousands of lines otherwise, and the point of this
  # script is a single verdict you will actually read.
  output=$(env "$flag=1" "$BIN" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    printf 'PASS  %s\n' "$flag"
    PASSED+=("$flag")
  else
    printf 'FAIL  %s (exit %s)\n' "$flag" "$status"
    FAILED+=("$flag")
    echo "$output" | sed 's/^/      | /'
  fi
done

echo ""
echo "======================================================"
printf '%d passed, %d failed, %d skipped (of %d)\n' \
  "${#PASSED[@]}" "${#FAILED[@]}" "${#SKIPPED[@]}" "${#FLAGS[@]}"
if [ ${#SKIPPED[@]} -gt 0 ]; then
  printf 'skipped: %s\n' "${SKIPPED[*]}"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
  printf 'failed:  %s\n' "${FAILED[*]}"
  exit 1
fi
echo "all good"
