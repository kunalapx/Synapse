<h1 align="center">Synapse</h1>
<h3 align="center">Talk to one agent. Ship with a crew.</h3>
<img width="1672" height="941" alt="image" src="https://github.com/user-attachments/assets/78a15990-8d3e-446a-831b-6b94fffd844e" />

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

Synapse flips the model.
You talk to a single agent - Synapse - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger agent pools, you can opt in to persistent domain agents: domain supervisors that are still ordinary direct reports, but run from their own isolated Synapse homes on this machine or another SSH-reachable host.

Synapse is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
Synapse is an agent distro for running a crew of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled Synapse skills, and helper scripts that any terminal coding agent can follow.
Launching a supported harness inside it instantiates your Synapse - and makes you the boss.

Synapse began as a fork of [firstmate](https://github.com/kunchenguid/firstmate), built on the same core principle - one agent you talk to, a crew of autonomous agents doing the work - and has since grown into its own independent project with its own direction.

## Features

- **One liaison** - you talk only to Synapse; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every agent works in its own tmux window, experimental herdr/zellij tab, cmux workspace, or Orca terminal you can watch or type into; Synapse reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, or an Orca-managed worktree when `backend=orca`, so parallel work on one repo never collides.
- **Two task shapes** - execution tasks deliver a change; research tasks investigate, plan, reproduce, or audit and leave a report.
- **Explicit project modes** - each project ships via `direct-PR` or `local-only`, with an optional `+yolo` merge-autonomy flag.
- **Optional domain agents** - opt in to persistent domain supervisors that run from isolated Synapse homes with their own `FM_HOME`, state, projects, and session lock, either locally or as a whole home on an SSH-reachable host, supervising project clones or a project-less Synapse-repo domain, kept on the primary Synapse version by guarded fast-forward updates and by recovery that never turns an unavailable remote route into a local replacement, and checked for live agent processes at session start.
- **Event-driven, zero-token supervision** - a bash supervisor sleeps on the agent pool and wakes Synapse only when something needs you; verified primary harnesses also get a turn-end backstop that blocks or follows up on a blind stop when work is in flight and supervision is not live.
- **Optional Relay** - opt in with one local `.env` pairing token so Synapse can answer your public mentions on X and Discord alike, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-Relay behavior; a final reply promised in a thread becomes durable state reconciled from disk, so a restart or a compacted conversation cannot lose it; dry-run preview records would-be replies and dismissals locally before go-live.
- **Guarded by construction** - Synapse is read-only over your projects apart from the narrow guarded and boss-approved write exceptions enumerated in [`AGENTS.md`](AGENTS.md)'s first prime directive, including agent pool sync's guarded safe branch pruning; agents make every other project change behind your merge approval.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected); kill the session anytime and the next one reconciles, including confirmed-dead domain agents, and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

### Requirements

- A verified primary agent harness: Claude Code, Grok, Pi, `pi-signed`, Codex, OpenCode, or Cursor Agent CLI.
- Node.js, which every `npm install -g` step in the rest of the toolchain depends on.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- tmux and [treehouse](https://github.com/kunchenguid/treehouse), for the reference session backend and its disposable worktrees, plus the CLI and dependencies for any other runtime backend you select.

That list is not exhaustive: [docs/configuration.md](docs/configuration.md) owns the complete required toolchain in its "Toolchain" section.
Synapse detects and offers to install the rest after you approve.
Backend-specific setup is linked in [Documentation](#documentation).

### Recommended harnesses

**Claude Code, Grok, and Pi are equal co-primary recommendations** for running the primary Synapse session, with `pi-signed` supported as Pi's distinct signed-wrapper identity.
Claude Code uses a tracked Stop hook for tokenless supervisor re-arm and rewake, Grok uses background-notify wake cycles, and Pi uses its tracked primary supervisor extension.
All three have verified turn-end guard paths when launched with their documented setup.
Pick whichever one matches your subscription and workflow.

Codex and OpenCode are also verified and supported as primary harnesses; Codex uses bounded foreground checkpoints, and OpenCode uses a TUI plugin, so both carry more harness-specific supervision tradeoffs than the three co-primaries.
Cursor Agent CLI is verified as a primary too, using a tracked project-scope `.cursor/hooks.json` whose `stop` hook parks on the supervisor between turns, closest in shape to Claude Code's.
Launch it with `--trust`, or none of its project hooks load; it also has no turn-end hook in headless `cursor-agent -p`, so run the primary session interactively.

### Install and launch

```sh
gh auth login
git clone git@github.com:kunalapx/Synapse.git
cd Synapse
```

Then launch one of the co-primary harnesses; AGENTS.md takes over from there:

**Claude Code**

```sh
claude
```

**Grok**

```sh
grok --trust
```

**Pi**

```sh
pi
# or, when the signed wrapper is installed
FM_PI_HARNESS=pi-signed pi-signed
```

For Grok, `--trust` is needed once per clone so project hooks and the turn-end guard load; `/hooks-trust` inside Grok works too.
For Pi, approve the project trust prompt once per clone on first launch so the tracked `.pi/extensions/*.ts` files auto-load.
Pi's `/calm` toggle hides supported transcript chrome, including canonically classified Synapse operational rows, and uses a Calm-only animated working indicator during active runs while preserving all model context and session data; [docs/calm.md](docs/calm.md) owns its current behavior and supported limits.
Pi's `/supervision-model` command pins a cheaper model and a shallower reasoning effort for the supervision branch alone, and with no pin that branch normally follows your own conversation's model and effort; see [docs/pi-supervision-branch.md](docs/pi-supervision-branch.md).

### Talk to it

```sh
> hey, look at my github project xyz, then fix the flaky login test and add dark mode

# Synapse checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two agents in the active backend
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review, boss: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

### More backends

Setup guides for tmux (the default) and every other supported backend (herdr, zellij, Orca, cmux) are linked in [Documentation](#documentation) below.

## How It Works

```
            you (the boss)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────────┐
 │ Synapse              (this repo)        │
 │ reads projects/ + Synapse routes        │
 │ writes guarded backlog/task specs/state │
 └──┬──────────────┬───────────────┬───────┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   tmux windows, herdr/zellij tabs, cmux workspaces, or Orca terminals
 │ agent  │   │ agent  │      │ agent  │   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree, Orca worktree, or isolated domain agent home
     │
     ├─ execution task: project mode ► PR/local merge ► teardown
     │
     └─ research task: report at data/<id>/report.md ► open-decision inventory ► relay findings ► teardown
```

You chat with Synapse.
It routes each request to an agent in its own session endpoint and git worktree, supervises the agent pool with a zero-token event-driven supervisor, and brings you finished PRs, approved local merges, or investigation reports.
Optional domain agents extend this to persistent local or whole-home remote domain supervisors, dispatch profiles let you steer which harness handles which task, and opt-in Relay lets the same agent pool answer public mentions.
`codex-app` is not a runtime backend yet; [docs/codex-app-backend.md](docs/codex-app-backend.md) owns the Codex App boundary.

Full architecture - the supervision engine, worktree isolation, domain agents, dispatch profiles, project modes, optional Relay, agent pool sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Synapse ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine wakes in bash, escalates boss-relevant events and bounded declared-external-wait rechecks as batched digests, and actively alerts if delivery wedges while you step away |
| `/ahoy`            | Recap visible session events since the prior real boss message plus visibly unanswered boss decisions, then guide you through any open decisions one at a time in agent-judged impact order; fall back to Bearings when invoked as the session's first real boss message |
| `/bearings`        | Generate a concise four-section chat digest from bounded agent pool state, including registered remote-home ledgers; use `/bearings file` to also replace today's dated report in `data/`, and add `include PRs` for live GitHub enrichment |
| `/updatefirstmate` | Self-update the running Synapse and its domain agents to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge domain agents |
| `/stow`            | Sweep the session for uncaptured durable knowledge, persist the open work records this session knows are unfiled or now wrong, curate tiered startup memory with decay and cold archival, enforce each home's budget or surface the required decision, cascade to registered domain agents, and report what is safe to reset |

Bearings invocation examples:

- `/bearings` returns the fresh four-section digest in chat only.
- `/bearings include PRs` keeps chat-only mode and opts into live PR enrichment.
- `/bearings file` replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch and links it from the four-section chat digest.
- `/bearings file include PRs` combines the dated report with live PR enrichment.

Agent-only reference skills live under `.agents/skills/` and are loaded by Synapse at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Synapse's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus Synapse's agent-only reference skills). Every one of these assumes a live Synapse home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how Synapse itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of Synapse.
  Each one is a self-contained skill with no dependency on Synapse's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback, and curates tiered entries through decay, local archival, and user-approved on-demand offload proposals.
  It intentionally shares no code with the Synapse-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the crew, supervision, worktrees, domain agents, and project modes work.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional Relay and its X and Discord setup steps, trusted external process-event adapter setup, the files you set, and harness support.
- [docs/extension-bindings.md](docs/extension-bindings.md) - the narrow trusted external `process-event-adapter/1` package, binding, handshake, and evidence boundary.
- [docs/remote-secondmates.md](docs/remote-secondmates.md) - setup, routing, transfer, recovery, and safety behavior for whole-home remote domain agents.
- [docs/calm.md](docs/calm.md) - current Pi `/calm` behavior and supported presentation limits.
- [docs/pi-supervision-branch.md](docs/pi-supervision-branch.md) - the Pi supervision branch and its model and effort pins.
- [docs/voice-relay.md](docs/voice-relay.md) - the optional spoken interface: setup on both machines, measured round-trip cost, what a spoken answer may read, and what this build does not do yet.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that wedges.
- [docs/tmux-backend.md](docs/tmux-backend.md) - setup and limits for the tmux reference backend: prerequisites, attaching, and watching crew windows.
- [docs/herdr-backend.md](docs/herdr-backend.md) - setup, safety boundaries, and limits for the experimental herdr backend.
- [docs/zellij-backend.md](docs/zellij-backend.md) - setup and limits for the experimental zellij backend.
- [docs/orca-backend.md](docs/orca-backend.md) - setup and limits for the experimental Orca backend.
- [docs/cmux-backend.md](docs/cmux-backend.md) - setup, socket security, and limits for the experimental cmux backend.
- [docs/codex-app-backend.md](docs/codex-app-backend.md) - the current blocked Codex App backend boundary and rollout contract.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's structural "no turn ends blind" backstop: verified per-harness hook mechanisms, scoping, loop safety, and fail-open tradeoffs.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered primary-harness supervisor protocols for Claude, Codex, OpenCode, Pi and `pi-signed`, Grok, Cursor, and unknown harness fallback.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active empirical evidence for runtime backend guarantees.
- [docs/verification/supervision.md](docs/verification/supervision.md) - active empirical evidence for session-start, guard, continuity, and wedge integrations.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.
- [`AGENTS.md`](AGENTS.md) - the distro's always-loaded operating contract and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
