// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-stage0`: the shell-integration hook that makes
// block view possible at all. SwiftTerm is a raw grid terminal emulator with
// no concept of "where a command starts" or "where its output ends" - that
// information only exists inside the shell itself. This hook is a small
// bash/zsh snippet, injected into an SSH host page's tab exactly the way
// `Host.startupSnippetID` already injects text into a freshly-connected tab
// (`ConsoleController.runStartupSnippet`) - same mechanism, not a new one -
// that makes the remote bash/zsh emit OSC 133 "semantic prompt" escape
// sequences (the same convention VS Code's and iTerm2's shell integration
// use) around every prompt cycle.
//
// Protocol actually used here (a deliberately narrowed subset of the full
// OSC 133 spec - see the reasoning below): two markers per prompt cycle,
// emitted once per shell round-trip, not four:
//
//   OSC 133;B BEL   - emitted from PS1, right at the point the prompt text
//                     ends and the cursor is ready for the captain to type.
//                     Marks the terminal-buffer row where the next block's
//                     raw content (the echoed command line, then its output)
//                     begins.
//   OSC 133;D;<exit-code>;<base64 command text>;<is-real 0|1> BEL
//                   - emitted from PROMPT_COMMAND (bash) / precmd_functions
//                     (zsh), i.e. right after a command finishes and before
//                     the next prompt is drawn. Carries the *exact* command
//                     text and exit code of the command that just finished,
//                     plus a fourth field (`fm/cockpit-fix-block-view-
//                     stage0-bugs`) distinguishing a real command close from
//                     a "nothing happened" one - see the `<is-real>` field
//                     note below, and `TerminalBlockTracker.closeBlock`'s doc
//                     comment for what the Swift side does with it.
//
// `<is-real>` and why D always fires, even for an empty Enter: PROMPT_COMMAND
// (bash) / precmd (zsh) run before *every* prompt redraw, including one
// triggered by pressing Enter on a blank line with nothing typed - bash does
// not add an empty line to history, so `history 1` (bash) / `$HISTCMD` (zsh)
// still returns the *previous* real command's text and number in that case.
// Before this field existed, that produced a real, reproduced bug: a
// captain hitting Enter on an empty prompt (a common habit) got a spurious
// extra block in the UI, labeled with the previous command's text, exit code
// preserved from before, and empty output (correctly empty, since nothing
// actually ran between the B and this D) - indistinguishable in the block
// list from a genuine repeat of that command. Each hook now remembers the
// history number/counter it saw at its last D (`$__fm_last_histnum`) and
// reports `<is-real>=0` when it's unchanged since last time - `D` is still
// sent unconditionally (never suppressed) so B/D stay strictly 1:1 and no
// block is ever left permanently stuck "running" because a blank-Enter's B
// had no matching D; `TerminalBlockTracker.closeBlock` discards (rather than
// finalizes) a `0`-flagged close instead of the shell skipping the marker.
//
// Known, deliberate residual gap, not fixed by this: a remote host whose
// dotfiles set `HISTCONTROL=ignoredups`/`ignoreboth` (or a matching
// `HISTIGNORE` pattern) suppresses the *history entry itself* for a command
// typed identically to the one right before it - so a genuine back-to-back
// repeat of the same command on such a host also reports `<is-real>=0` and
// its block is silently discarded, same as a blank Enter. Verified live
// (see this task's PR description for the pty-based repro/fix transcripts):
// with default `HISTCONTROL` (no dedup - what this app's own use of `ssh`
// starts with before any remote `.bashrc` runs, and the common case), a
// real back-to-back repeat still gets its own history number and therefore
// its own correctly-populated block. There is no signal available to
// PROMPT_COMMAND/precmd that distinguishes "the exact same command was
// re-typed and its history entry was deduped" from "nothing was typed at
// all" - both look identical (history unchanged) from here. A full fix
// would need a bash-preexec-style DEBUG-trap marker set *before* a command
// runs (this file's own header above already explains why that path was
// rejected: it mis-fires for a compound `PROMPT_COMMAND` string) - out of
// scope for this fix. Silently dropping the block (this fix's failure mode)
// was judged a smaller, more defensible gap than the always-reproducible
// "misleading empty block" bug it replaces: it fails toward showing nothing
// extra rather than showing something wrong.
//
// Why no separate "command executed" (C) marker, and why command text rides
// on D instead of being screen-scraped: a real preexec hook that fires
// exactly once per top-level command, with no false extra firings, is native
// in zsh (`preexec_functions`) but is a well-known minefield in bash, which
// has no native preexec - only a `trap ... DEBUG` hack. A first attempt at
// that DEBUG-trap version was built and tested live in the original task
// (see PR #79's description) and it mis-fired: bash's DEBUG trap also fires
// for each *sub-statement* of `PROMPT_COMMAND` itself when `PROMPT_COMMAND`
// is a compound `stmt1; stmt2` string (confirmed live: it double-fired on the
// first prompt and, worse, silently reported `false`'s exit code as 0
// instead of 1 once the guard logic got confused). Rather than reimplement
// bash-preexec's considerably more complex state machine just to get a `C`
// marker, this drops `C` entirely: bash's own `history 1` (and zsh's
// `fc -ln -1`) already give the *exact* text of the command that just
// finished, retrieved at PROMPT_COMMAND/precmd time - a strictly more
// reliable source than trying to screen-scrape the typed line back out of
// the terminal buffer. `TerminalBlockTracker` derives the *output* region
// from the buffer rows between a `B` and the following `D` (dropping the
// first captured row, which is the tail of the echoed command line) - see
// its own header comment for that half. This was verified live for both
// shells, including a non-zero exit command, with a scripted PTY session
// (see PR #79's description for the transcripts) before writing any Swift.
//
// Bash-version note: this uses only `PROMPT_COMMAND` + `PS1`, both present in
// even the ancient bash 3.2 macOS ships as `/bin/bash` - confirmed live on
// this machine. No `PS0`/`preexec_functions`-only feature is required. This
// also covers a remote bastion's bash/zsh, since the hook is sent as regular
// keystrokes over the already-established SSH session, not something local
// to this app's own process.
import Foundation

enum ShellIntegration {

    /// The raw hook script - self-detects bash vs. zsh at `source`-time and
    /// installs the matching hook; a shell that is neither (e.g. `sh`,
    /// `fish`, `csh`) silently does nothing, since this whole feature is
    /// explicitly scoped to bash/zsh only (see AGENTS.md's note on this
    /// app's terminal children being bash/zsh already, for SRE Lead's own
    /// `bash -lc` assumption). Deliberately a *single* line with no
    /// embedded newlines - see `installSequence` for why it is no longer
    /// sent to the remote shell as literal typed text.
    private static let script = """
    if [ -n "$BASH_VERSION" ]; then __fm_prompt_cmd() { local ec=$?; local histline; histline=$(HISTTIMEFORMAT= history 1 2>/dev/null); local histnum; histnum=$(printf '%s' "$histline" | sed -e 's/^[ ]*//' -e 's/[ ].*$//'); local real=1; if [ "$histnum" = "$__fm_last_histnum" ]; then real=0; fi; __fm_last_histnum="$histnum"; local cmd; cmd=$(printf '%s' "$histline" | sed -e 's/^[ ]*[0-9]*[ ]*//'); local b64; b64=$(printf '%s' "$cmd" | base64 | tr -d '\\n'); printf '\\033]133;D;%s;%s;%s\\007' "$ec" "$b64" "$real"; }; PROMPT_COMMAND='__fm_prompt_cmd'"${PROMPT_COMMAND:+; $PROMPT_COMMAND}"; PS1="\\[$(printf '\\033]133;B\\007')\\]$PS1"; elif [ -n "$ZSH_VERSION" ]; then __fm_precmd() { local ec=$?; local histnum=$HISTCMD; local real=1; if [ "$histnum" = "$__fm_last_histnum" ]; then real=0; fi; __fm_last_histnum="$histnum"; local cmd b64; cmd=$(fc -ln -1 2>/dev/null); b64=$(printf '%s' "$cmd" | base64 | tr -d '\\n'); printf '\\033]133;D;%s;%s;%s\\007' "$ec" "$b64" "$real"; }; precmd_functions+=(__fm_precmd); PS1="%{$(printf '\\033]133;B\\007')%}$PS1"; fi
    """

    /// The ordered lines to send into an SSH tab once its process starts
    /// (mirrors `ConsoleController.runStartupSnippet`'s injection mechanism
    /// of typing text into the pty as though the captain typed it - each
    /// element already ends in its own `\n`, send them in order).
    ///
    /// `fm/cockpit-fix-block-view-stage0-bugs`, bug 2: the captain's first
    /// real hands-on test of block view showed `script` (above) dumped
    /// verbatim into the visible terminal - a real remote pty echoes every
    /// typed byte back to the display before the shell executes it, so the
    /// whole multi-hundred-character one-liner appeared as ugly, wrapped
    /// literal text right in the middle of a real session. This sequence
    /// suppresses that, in three parts:
    ///
    /// 1. A short leading line that turns off the remote pty's terminal
    ///    echo (`stty -echo`) - and, for zsh specifically, also disables
    ///    ZLE (`unsetopt zle`) first. This line is itself still visible
    ///    (echo hasn't been turned off yet when it's typed) - a small,
    ///    recognizable, one-time artifact, not the full script. Verified
    ///    live (pty-based repro, see this task's PR description) that
    ///    `stty -echo` alone suppresses bash's readline echo, but zsh's
    ///    line editor (ZLE) echoes/redraws input in its own software layer
    ///    regardless of the kernel tty's ECHO flag - `unsetopt zle` is the
    ///    only thing that actually stops it, confirmed the same way.
    /// 2. The real hook script, base64-encoded and split across several
    ///    lines short enough to stay under a real terminal's canonical-mode
    ///    line-length cap (`fpathconf(_:.maxCanon)` measured 1024 bytes on
    ///    this machine's pty - Linux ttys are more generous, but nothing
    ///    guarantees the remote bastion's kernel is), each accumulating into
    ///    a shell variable - never one long line. This split is only
    ///    needed *because* of step 1: with ZLE active (its normal state),
    ///    zsh has no such length limit at all (it manages long lines
    ///    itself), which is exactly how the original, unwrapped one-liner
    ///    worked - just visibly. Disabling ZLE trades that away for a real
    ///    kernel canonical-mode limit, so the payload has to fit under it.
    ///    Verified live that a single ~1.1KB combined line silently hangs
    ///    the shell once ZLE is off (the kernel line discipline never sees
    ///    a terminating newline within its canonical buffer), and that
    ///    chunking at 600 base64 characters per line resolves it with
    ///    comfortable margin under 1024 for every chunk plus its wrapper
    ///    syntax.
    /// 3. A final line that decodes+evals the reassembled script, restores
    ///    echo, and restores ZLE.
    ///
    /// **Known residual risk, specific to zsh, found and left honestly
    /// documented rather than chased to a guaranteed fix**: this whole
    /// sequence was verified clean (bash: always; zsh, including a real
    /// `unsetopt zle`/`stty -echo` pairing against this dev machine's own
    /// real interactive zsh - starship prompt, real dotfiles, not a bare
    /// `-f` shell) across roughly a dozen live end-to-end passes through
    /// the real `ConsoleController` production path. Exactly once, on an
    /// early pass under this same real starship-based zsh, the full base64
    /// payload leaked into the visible buffer instead of just the one
    /// expected leading line - not reproduced again across ~9 further
    /// identical passes (same code, same timing constants) or across a
    /// dozen isolated pty-level probes narrowing which single line was
    /// responsible. That pattern - clean the overwhelming majority of the
    /// time, one confirmed miss under otherwise-identical conditions - points
    /// at a genuine race rather than a deterministic content or length
    /// problem, most plausibly an async prompt segment (starship forks a
    /// background job per prompt for things like git status) completing at
    /// exactly the wrong moment relative to this shell's non-ZLE fallback
    /// line reading while ZLE is off - a mechanism outside this app's
    /// control and not fully eliminable without either not disabling ZLE at
    /// all (reverting to the always-visible original bug) or reaching into
    /// how a specific third-party prompt framework schedules its own async
    /// work, which is out of scope for a fix scoped to bash/zsh in general.
    /// A captain on a zsh setup with an async/background-job prompt
    /// framework (starship, powerlevel10k's async mode, and similar) should
    /// expect this to be reliable but not airtight - rare, not systemic.
    ///
    /// Deliberately not attempted: erasing the one short leading line's
    /// echo from the viewport after the fact (e.g. a cursor-reposition +
    /// clear-to-end-of-screen). Precisely erasing only what this sequence
    /// itself printed - without also risking eating real prior session
    /// content - would need this app to compute exactly how many rows a
    /// remote shell's own prompt+echo rendering consumed at the terminal's
    /// current column width, which the shell's own prompt string (PS1,
    /// unknown to this app) also contributes to; that's a fragile guess,
    /// not a precise erase, so it was not built. The one short `stty
    /// -echo`/`unsetopt zle` line (bullet 1) is the sole remaining visible
    /// footprint of this whole install, on every shell, every time -
    /// documented here rather than silently claimed away.
    static let installSequence: [String] = {
        let chunkSize = 600
        let base64Script = Data(script.utf8).base64EncodedString()
        var chunks: [String] = []
        var index = base64Script.startIndex
        while index < base64Script.endIndex {
            let end = base64Script.index(index, offsetBy: chunkSize, limitedBy: base64Script.endIndex) ?? base64Script.endIndex
            chunks.append(String(base64Script[index..<end]))
            index = end
        }

        var lines: [String] = []
        lines.append(" if [ -n \"$ZSH_VERSION\" ]; then unsetopt zle; fi; stty -echo 2>/dev/null\n")
        for (i, chunk) in chunks.enumerated() {
            let isLast = i == chunks.count - 1
            if isLast {
                lines.append(" __fm_x=\"${__fm_x}\(chunk)\"; eval \"$(printf '%s' \"$__fm_x\" | base64 -d)\"; unset __fm_x; stty echo 2>/dev/null; if [ -n \"$ZSH_VERSION\" ]; then setopt zle; fi\n")
            } else {
                lines.append(" __fm_x=\"${__fm_x}\(chunk)\"\n")
            }
        }
        return lines
    }()
}
