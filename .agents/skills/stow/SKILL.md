---
name: stow
description: Sweep the current session for uncaptured durable knowledge and file it to disk before a context reset. Use when the boss invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the Synapse-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge that only exists in conversation right now, and write it to the disk locations Synapse already prints in the next session-start context digest.
The goal is a session that is safe to reset or destroy because everything durable has already been captured.

## What it does

1. **Sweep the session for uncaptured durable knowledge.**
   Read back over this conversation and look for:
   - Operational learnings: agent-pool-local facts and gotchas discovered while operating Synapse (a script's sharp edge, a harness quirk, a recurring false alarm and its real cause).
   - Boss preferences expressed in passing: a working-style or approval preference the boss stated conversationally rather than through `data/captain.md` directly.
   - Project-intrinsic facts discovered: build, test, release, or architecture facts about a project that belong in that project's own `AGENTS.md`.
   - Decisions made: a standing choice the boss made this session that should outlive it.
   - Undone next steps: anything left open that has not yet been filed as backlog work.

2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md (section 6, "Knowledge routing") is the single source of truth for where each kind of knowledge belongs.
   Read that table and route each finding there instead of re-deriving the mapping here.

3. **Write within Synapse's existing write boundaries.**
   This skill does not grant any new write permission; it only prompts Synapse to use the boundaries that already exist (AGENTS.md section 1):
   - Boss preferences and working style: hand-write directly to `data/captain.md`, using inspect-then-update every time.
     Before writing, inspect the destination, find the existing bullet or section the finding duplicates or supersedes, and rewrite it in place rather than adding a new trailing entry.
     Boss preferences are the one class that stays a flat hand-written file; they are never proposed into the governed memory store, so this fact lives in exactly one home.
   - Fleet learnings, gotchas, conventions, repo facts, architecture decisions, and business facts: propose each to the governed memory store with `bin/fm-memory.sh propose` as a CANDIDATE, carrying evidence and attribution.
     Do NOT hand-append these to `data/learnings.md`; that file is retired as a write target (the session digest already surfaces the store's active entries), so `/stow` never writes to it.
     `propose` can only ever write `status: candidate`; promotion behind the class gate is a separate governed step that `/stow` does not perform, so no `/stow` write can reach trusted `active` memory.
     Compose each proposal like this, choosing the axes from the fact:
     - `--id <kebab-slug>` a short descriptive slug for the fact.
     - `--class <repo_fact|convention|architecture_decision|business_knowledge>` the validation class matching the fact: a learning or gotcha or plain repo fact is `repo_fact`, a code/style convention is `convention`, a standing design decision is `architecture_decision`, a business fact is `business_knowledge`.
       Never propose `preference` (boss preferences go to `data/captain.md` above) and never propose `security_rule` (it is deliberately un-proposable - escalate a security-relevant fact to the boss instead).
     - `--type <user|feedback|project|reference>` the recall taxonomy; most fleet facts are `project`, a pointer to an external resource is `reference`.
     - `--scope <fleet|PROJECT-NAME>` use `fleet` for fleet-wide facts, or the project name when the fact is scoped to one project so `bin/fm-brief.sh` injects it into that project's briefs.
     - `--source-task <id>` and `--source-agent <name>` for attribution when the finding came from a specific task or agent (the proposer identity is recorded automatically).
     - `--body "<the fact>. Evidence: <the file, command output, or repro that proves it>."` state the fact, then a short evidence line; never paste raw secrets - the store's secret scan will refuse the write.
     Before proposing, `bin/fm-memory.sh recall --scope <scope>` first: if an active entry already covers the fact, skip it, and if the finding supersedes an existing active entry, propose a new-version slug (e.g. `<slug>-v2`) which the store opens as a governed conflict rather than a silent duplicate.
   - Project-intrinsic knowledge: never hand-write a project's `AGENTS.md`.
     Route it through a dedicated execution task scaffolded with `bin/fm-brief.sh --project-memory` - never a routine task that is also doing other work - so an agent records it via `bin/fm-ensure-agents-md.sh` and commits it through that project's delivery pipeline, exactly as section 6 describes.
     If the agent pool is live, delegate this to an agent rather than doing it inline.
   - Knowledge generalizable to every Synapse user: this repo's own `AGENTS.md` (or other shared, tracked material), shipped through the normal branch -> self-review -> PR -> boss-merge flow for this repo (section 1), never hand-committed straight to `main`.
   - Task-scoped notes: inspect the relevant backlog item with `tasks-axi show <id> --full`, judge whether the new note is new, duplicate, superseding, or obsolete, then write a considered replacement body with `tasks-axi update <id> --body-file <path>`.
     When the replacement intentionally supersedes prior state that should remain recoverable, add `--archive-body` to that update command so the prior body stays recoverable without copying it into the replacement.
     Never append.
     If hand-editing `data/backlog.md` per the active backend, make the same inspect-then-update edit in place.
   - Undone next steps: file each as a queued backlog item (section 10), with `blocked-by` recorded if it genuinely depends on something else.

4. **Curate with inspect-then-update.**
   Every write starts by reading the current destination and deciding how the finding changes what is already there.
   Use this checklist before writing:
   - Which existing bullet, section, task body, or active memory entry does this supersede?
   - Can this be a one-sentence rewrite instead of a new entry?
   - Should an older bullet or note be deleted, retired, or archived because it is now obsolete?
   For a flat hand-written destination (`data/captain.md`, a task body), rewrite or prune the existing entry in place instead of piling on a new one.
   For the governed store, `recall` first and let the store's own governance handle overlap: a superseding fact becomes a new-version candidate that the store opens as a conflict, never a hand-edit of an existing entry.
   Graduation moves are limited to exactly four: propose a fleet-knowledge fact to the governed store as a candidate, fold a boss preference into `data/captain.md`, promote a generalizable learning to the shared `AGENTS.md` via PR, or delete/retire a stale flat-file entry.
   Do not invent other graduation paths.

5. **Report to the boss.**
   Summarize, in plain outcome language (section 9): what was stowed and where, what was filed to the backlog, and whether the session is now safe to reset or destroy - i.e. whether every durable finding from this sweep now lives on disk rather than only in this conversation.
   If something could not be captured yet (for example, project-intrinsic knowledge waiting on an agent to land it), say so explicitly rather than reporting the session fully safe.

## Scope exclusion: no skill storage

`/stow` must **never** store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
This is a deliberate, standing exclusion, not an oversight: even with the two-tier skill layout, a stow sweep is a memory-routing operation, not a way to author or mutate skills.
Writing learnings into either `.agents/skills/` or public `skills/` would still risk mixing agent-pool-local material with shared Synapse behavior or standalone installer-facing behavior.
Until a human deliberately scopes a skill change as Synapse repo work, route generalizable knowledge to the shared `AGENTS.md` (or other shared, tracked material) via the pipeline, and agent-pool-local knowledge to `data/`, never to a skill.
