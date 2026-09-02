---
name: updatefirstmate
description: >-
  Self-update a running Synapse and its domain agents to the latest from origin.
  Use when the boss invokes /updatefirstmate (e.g. "/updatefirstmate", "update Synapse", "pull the latest Synapse").
  Fast-forwards this Synapse repo's default branch and every local or remote domain agent through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and nudges each updated domain agent to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update Synapse in place.
Synapse is its own repo, shipping its own tracked-material changes like any `direct-PR` project it manages, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running Synapse pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running Synapse instruction surface; public `skills/` is installer-facing and is not loaded by Synapse.
This skill performs that pull for the running main Synapse and every domain agent, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the agent pool sync Synapse already runs.
For a remote route, it updates the configured Synapse code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a domain agent's in-flight work is never disrupted.
This touches only the Synapse repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this Synapse repo's default branch from origin, then updates every registered local or remote domain agent home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live domain agent.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that domain agent picks up its new instructions too:
   ```sh
   FM_HOME=<this-synapse-home> bin/fm-send.sh <id> 'Synapse was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-synapse-home>` unless `FM_HOME` is already set to the active Synapse home.
   This is a gentle steer, not an interruption: the domain agent already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A domain agent that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the boss in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without Synapse's internal vocabulary: which parts of the agent pool are now on the latest, and which were left as-is and why.
   For example: "Boss, Synapse and both domain supervisors are now on the latest."
   Surface any skipped target whose reason needs the boss's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the Synapse repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the agent pool sync.
- **Domain agents are never disrupted.**
  A local or remote domain agent gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
