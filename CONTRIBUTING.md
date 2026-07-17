# Contributing

Thanks for wanting to contribute.
This repo is a personal fork of firstmate, and changes ship as ordinary pull requests to `main`.

## Workflow

1. Fork the repo and clone it, or clone this repo directly if you already have push access.
2. Create a branch off `main` and make your changes.
3. Self-review before you push: run the repo's checks (see "Development" below), and for substantive changes run the `high-level-review` skill against your diff and fix what it flags.
4. Commit your changes and push your branch.
5. Open a pull request against `main` with `gh-axi`.
6. `ci.yml` runs the ShellCheck lint and the behavior tests on your PR; keep pushing fixes until both jobs are green.
7. The maintainer reviews the PR and merges it.

## Repo conventions

- This repo is a template for running a Synapse orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled Synapse skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live Synapse home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no Synapse dependency (see the README's "Two-tier skill layout").
  Everything personal to one boss's agent pool (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations, with the compatibility definition owned by [`docs/configuration.md`](docs/configuration.md) ("Backlog backend").
  A local `config/backlog-backend=manual` opt-out forces Synapse's routine backlog updates to hand-editing and stays gitignored; validated domain agent handoffs still delegate through `tasks-axi mv`.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`, while `codex-app` is documented only in `docs/codex-app-backend.md`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass: it is the single owner of the lint definition (the shellcheck file set, config, and pinned shellcheck version), and CI runs it, so local and CI can never diverge.
  It pins one exact shellcheck version and refuses to run under any other; print it with `bin/fm-lint.sh --required-version` and install that build locally.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) need empirical adapter notes in the relevant backend guide: `docs/tmux-backend.md`, `docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, `docs/cmux-backend.md`, or `docs/codex-app-backend.md` for blocked Codex App transport work.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to Synapse itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship on a feature branch through the same `direct-PR` flow Synapse uses for any project it manages (AGENTS.md section 7) and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is Synapse itself, so Synapse adds this skill's load line to Synapse-repo task specs by hand.
An agent picking up such a task spec should load the skill even if the task spec predates this instruction.
When supervising live agents, keep Synapse's own long validation or build commands in the background so supervisor wakes can still be handled.
Agent validation first runs the toolbelt checks below and confirms they pass, then `/verify-feature` when the task carries a tracked ticket reference, then `/high-level-review` against the diff vs the base branch, fixing what it flags itself before pushing and opening the PR (AGENTS.md section 7 "Validate").
Synapse's wrapper still matters: a genuine product or scope decision the agent cannot resolve on its own routes to the boss through Synapse via `needs-decision:`/`resolved:`, exactly as `ask-user` findings did under the retired no-mistakes gate.
Every PR to `main`, whether opened by Synapse or by a human, is validated by `ci.yml` (the ShellCheck lint and behavior-test jobs); the maintainer merges once it is green.

Check and test the toolbelt before pushing:

```sh
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done   # syntax-check the toolbelt
bin/fm-lint.sh   # lint the toolbelt and behavior tests; the single owner CI runs it too
for test_script in tests/*.test.sh; do bash "$test_script"; done   # behavior tests, matching CI
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # supervisor re-arm smoke test (prints arm status, then an actionable signal)
```

Discover tests by listing `tests/*.test.sh`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so run one directly to focus on a subject.
Tests that need a real optional backend or an explicit opt-in (real herdr/zellij/cmux smoke tests, the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the run-all loop above is always safe.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
