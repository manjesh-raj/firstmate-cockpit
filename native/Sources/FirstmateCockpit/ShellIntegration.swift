// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-ssh-only`: the shell-integration hook that makes
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
//   OSC 133;D;<exit-code>;<base64 command text> BEL
//                   - emitted from PROMPT_COMMAND (bash) / precmd_functions
//                     (zsh), i.e. right after a command finishes and before
//                     the next prompt is drawn. Carries the *exact* command
//                     text and exit code of the command that just finished.
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
enum ShellIntegration {

    /// The literal shell text sent into an SSH tab once its process starts
    /// (mirrors `ConsoleController.runStartupSnippet`'s injection mechanism).
    /// Self-detects bash vs. zsh at `source`-time and installs the matching
    /// hook; a shell that is neither (e.g. `sh`, `fish`, `csh`) silently does
    /// nothing, since this whole feature is explicitly scoped to bash/zsh
    /// only (see AGENTS.md's note on this app's terminal children being
    /// bash/zsh already, for SRE Lead's own `bash -lc` assumption).
    ///
    /// Deliberately a *single* line with no embedded newlines, so it reads
    /// into the shell as one command the same way a startup snippet does.
    static let installCommand: String = {
        let script = """
        if [ -n "$BASH_VERSION" ]; then __fm_prompt_cmd() { local ec=$?; local cmd; cmd=$(HISTTIMEFORMAT= history 1 2>/dev/null | sed -e 's/^[ ]*[0-9]*[ ]*//'); local b64; b64=$(printf '%s' "$cmd" | base64 | tr -d '\\n'); printf '\\033]133;D;%s;%s\\007' "$ec" "$b64"; }; PROMPT_COMMAND='__fm_prompt_cmd'"${PROMPT_COMMAND:+; $PROMPT_COMMAND}"; PS1="\\[$(printf '\\033]133;B\\007')\\]$PS1"; elif [ -n "$ZSH_VERSION" ]; then __fm_precmd() { local ec=$?; local cmd b64; cmd=$(fc -ln -1 2>/dev/null); b64=$(printf '%s' "$cmd" | base64 | tr -d '\\n'); printf '\\033]133;D;%s;%s\\007' "$ec" "$b64"; }; precmd_functions+=(__fm_precmd); PS1="%{$(printf '\\033]133;B\\007')%}$PS1"; fi
        """
        return script + "\n"
    }()
}
