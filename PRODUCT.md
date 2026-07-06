# Product

## Register

product

## Users

Manjesh - an SRE/DevOps engineer who runs a firstmate fleet. He is the "captain": he delegates work to a first mate agent, which spawns crewmates. He checks this cockpit in quick bursts through the workday (on a wide monitor, in a bright office, and during late-night deploys) mainly to answer one question: *does the crew need me right now?*

## Product Purpose

A glanceable companion to a firstmate fleet. It observes fleet state (who's working, what's parked on a decision, which PRs are ready) and lets the captain act on the common cases - message the first mate, merge a PR, peek a pane - without leaving for the terminal. Success = the captain can tell in under two seconds whether anything needs them, and act in one click when it does.

## Brand Personality

Calm, precise, nautical. It's an instrument panel, not a marketing page: confident and quiet when idle, unmistakable when something needs attention. Three words: composed, legible, shipshape.

## Anti-references

- SaaS-dashboard cliché: gradient hero metric, identical icon+heading+text card grids, purple-on-white.
- Navy-and-gold "fintech nautical" reflex - avoid the obvious sea theme.
- Noisy, over-animated ops dashboards where everything pulses for attention.

## Design Principles

- **Glanceable first.** Status legible from across the room; the one thing that needs the captain must dominate.
- **Quiet until it matters.** Idle is calm and low-contrast; a needed decision is loud.
- **Honest state.** Show real fleet state from firstmate's own source of truth; never fake liveness.
- **One click to act.** Common actions (merge, answer, message) are reachable without the terminal.

## Accessibility & Inclusion

WCAG AA contrast in both themes (body ≥4.5:1). Status never encoded by color alone - always paired with a label. Full light and dark themes. All motion has a `prefers-reduced-motion` fallback.
