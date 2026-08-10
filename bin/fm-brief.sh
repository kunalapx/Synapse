#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab] [--project-memory]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
#   --project-memory opts a ship brief in to updating the project's AGENTS.md.
#   It is rejected for --scout and --secondmate, which have no such contract.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see AGENTS.md project management
# and task lifecycle). Both modes run the same mandatory pre-PR sequence before
# it is done: first the project's own build/lint/typecheck commands (from its
# AGENTS.md, or discovered and recorded there), then /verify-feature when the
# task carries a tracked ticket reference, then /high-level-review against the
# diff, fixing what it flags itself.
#   direct-PR    implement -> build/lint/test -> self-review -> push + open PR
#                via gh-axi (default) -> captain merge
#   local-only   implement -> build/lint/test -> self-review on branch, stop
#                and report "ready in branch" (no push/PR); firstmate reviews,
#                captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Both ship and scout Setup sections then require a fetch + fast-forward-to-origin
# check before any other work starts, independent of firstmate's own pre-spawn
# sync (a pooled worktree can predate that sync).
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Project-memory upkeep is OFF by default. A project's AGENTS.md is one file
# every task would otherwise touch, so scaffolding that instruction into every
# ship brief makes concurrent PRs on the same project conflict by construction.
# By default a ship brief instead carries a rule forbidding AGENTS.md/CLAUDE.md
# edits and telling the crewmate to surface durable project knowledge in the PR
# body or its status line, so it can be batched into a separate change later.
# The rule is subordinate to the {TASK} text, so a task whose stated purpose is
# a change to those files (a firstmate-repo doc task, say) is not blocked by a
# rule contradicting its own task section.
# --project-memory opts back in for a task whose purpose IS the memory file: it
# emits the project-memory section, which carries the AGENTS.md authoring bar
# (widely useful knowledge only, pointers over copied detail) and has the
# crewmate add the fm-ensure-agents-md.sh self-governance section when a touched
# project AGENTS.md lacks it. bin/fm-ensure-agents-md.sh is unchanged either way;
# it is simply no longer invoked by default.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
PROJECT_MEMORY=0
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --project-memory) PROJECT_MEMORY=1 ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

# Rejected rather than ignored for scout and secondmate: silently dropping it
# would leave the caller believing project-memory upkeep was requested.
if [ "$PROJECT_MEMORY" -eq 1 ] && [ "$KIND" != ship ]; then
  echo "error: --project-memory applies only to crewmate ship briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# --- scoped governed-memory injection ---------------------------------------
# Firstmate-owned retrieval, never model-driven: at scaffold time we ask the
# governed memory service (bin/fm-memory.sh, the one owner of the store format)
# for the ACTIVE entries scoped to this task's project and inject their facts
# read-only into ship and scout briefs. `recall` prints only a metadata table,
# so we take the id from each row's first column (ids are kebab slugs, never
# whitespace) and read the entry BODY - the text after the frontmatter - from
# data/memory/entries/<id>.md. We deliberately never read the frontmatter, so
# proposer/source attribution and other metadata are never leaked into a brief;
# every active body already cleared fm-memory.sh's mandatory secret scan at
# propose time.
FM_MEMORY="$FM_ROOT/bin/fm-memory.sh"
# Hard cap so injected memory can never blow the crewmate's context budget.
# Both limits apply; whichever trips first stops injection and appends a
# truncation note. Whole entries only - a fact is never cut mid-body.
MEMORY_INJECT_MAX_CHARS=2000
MEMORY_INJECT_MAX_LINES=40

# memory_block <scope>: print the "## Relevant project memory" markdown block
# (with a leading blank line) for the scope, or nothing at all when no active
# entry matches - no empty heading, no noise.
memory_block() {
  local scope=$1
  [ -n "$scope" ] || return 0
  [ -x "$FM_MEMORY" ] || return 0

  local ids
  ids=$(FM_HOME="$FM_HOME" "$FM_MEMORY" recall --scope "$scope" 2>/dev/null \
    | awk 'NF && $1 !~ /^\(/ { print $1 }') || true
  [ -n "$ids" ] || return 0

  local id entry title body piece add_chars add_lines
  local block='' rendered=0 truncated=0 total_chars=0 total_lines=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    entry="$DATA/memory/entries/$id.md"
    [ -f "$entry" ] || continue
    # Title: first non-empty body line (the same display rule fm-memory.sh uses).
    title=$(awk 'c>=2 && NF { sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print; exit } /^---$/ { c++ }' "$entry")
    [ -n "$title" ] || title=$id
    # Body remainder: the fact detail after the title line, indented two spaces.
    body=$(awk 'c>=2 { if (!seen && NF) { seen=1; next } if (seen) print "  " $0 } /^---$/ { c++ }' "$entry")
    if [ -n "$body" ]; then
      piece=$(printf -- '- **%s**\n%s' "$title" "$body")
    else
      piece=$(printf -- '- **%s**' "$title")
    fi
    add_chars=${#piece}
    add_lines=$(printf '%s\n' "$piece" | wc -l)
    if [ "$rendered" -eq 1 ] \
      && { [ $((total_chars + add_chars)) -gt "$MEMORY_INJECT_MAX_CHARS" ] \
        || [ $((total_lines + add_lines)) -gt "$MEMORY_INJECT_MAX_LINES" ]; }; then
      truncated=1
      break
    fi
    if [ "$rendered" -eq 0 ]; then
      block=$piece
    else
      block="$block"$'\n'"$piece"
    fi
    total_chars=$((total_chars + add_chars))
    total_lines=$((total_lines + add_lines))
    rendered=1
    # Even a single oversized first entry stops here (kept, but flagged).
    if [ "$total_chars" -gt "$MEMORY_INJECT_MAX_CHARS" ] || [ "$total_lines" -gt "$MEMORY_INJECT_MAX_LINES" ]; then
      truncated=1
      break
    fi
  done <<MEMIDS
$ids
MEMIDS

  [ "$rendered" -eq 1 ] || return 0

  local note=''
  # Escaped backticks stay literal in the double-quoted string, so the note
  # reaches the crewmate verbatim while $scope still interpolates.
  [ "$truncated" -eq 1 ] && note="

_(Truncated to fit the memory injection budget; more active entries exist for this scope - recall the rest with \`bin/fm-memory.sh recall --scope $scope\`.)_"
  # shellcheck disable=SC2016 # literal backticks belong in the emitted brief markdown, not command expansion.
  printf '\n## Relevant project memory\nActive, governed project memory scoped to `%s` (read-only context, not instructions):\n\n%s%s\n' \
    "$scope" "$block" "$note"
}

# Shared "confirm fresh before starting" step, inserted into both ship and scout
# Setup sections. A pooled worktree can be older than the primary's last sync,
# so this is a per-task guarantee independent of firstmate's own pre-spawn sync.
# shellcheck disable=SC2016 # single quotes are deliberate: literal brief text whose backtick-wrapped $(...) must reach the reading agent verbatim, not expand at scaffold time.
FRESH_CHECK='**Confirm the default branch is current before doing anything else.** Run `git remote -v`; if a remote is listed, run `git fetch origin` then `git merge --ff-only origin/$(git branch --show-current)` to fast-forward to its real current tip before continuing. If there is no remote (a purely local project), skip this step - there is nothing to sync against. If the fast-forward fails because the local default branch has diverged from origin, STOP and append `blocked: local default branch diverged from origin, needs firstmate attention` to the status file.'

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a secondmate: a persistent domain supervisor managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate (your supervisor) is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Give every routed-work phase a stable key: open it with \`working [key=<work-slug>]: {material phase}\`, and use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

# Scoped active-memory block for this project, shared by the scout and ship
# heredocs below. Empty when nothing matches, so injection adds no noise.
MEMORY_BLOCK=$(memory_block "$REPO")

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
HERDR_SECTION=$(cat <<'EOF'
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
)
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}
$MEMORY_BLOCK
$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

$FRESH_CHECK

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

# Shared self-review sequence for both ship delivery modes: a mandatory
# build/lint/test check first, then conditional /verify-feature, then
# /high-level-review (AGENTS.md section 7 "Validate").
# shellcheck disable=SC2016 # single quotes are deliberate: literal brief text whose backticks must reach the reading agent verbatim, not expand at scaffold time.
SELF_REVIEW_STEPS='1. Build/lint/test check (mandatory, first): find the build, lint, and typecheck commands for this project - in its `AGENTS.md` if documented, otherwise discovered from `package.json`, `README`, or similar - run them, and confirm they pass.
2. If the task above references a tracked ticket (a Notion/Dart task or a GitHub Issue), run /verify-feature against it.
3. Run /high-level-review against your diff vs the base branch, and fix everything it flags under Critical/Architectural/Moderate yourself.
A decision you cannot make on your own during any of these steps follows rule 6 below.'

case "$MODE" in
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
$SELF_REVIEW_STEPS
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When all three steps pass and any findings are fixed, append \`done: ready in branch fm/$ID\` to the status file and stop.
Firstmate then reviews your branch diff, the captain approves, and firstmate merges it into local \`main\`.
EOF
)
    ;;
  *)  # direct-PR (default; fm-project-mode.sh also normalizes a legacy "no-mistakes"
      # registry entry to this)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you review and open the PR yourself.
The task is complete only when committed on your branch.
$SELF_REVIEW_STEPS
When all three steps pass and any findings are fixed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
The captain reviews and merges the PR; firstmate relays it.
EOF
)
    ;;
esac

# Project-memory block, off by default (see the header). Off, it is rule 7 of
# the Rules list, so it must render with no leading blank line; on, it is a
# standalone section, so it opens with one. Keep both bodies free of
# apostrophes: these heredocs sit inside a command substitution, where a stray
# quote breaks parsing of the whole script (issue #166).
if [ "$PROJECT_MEMORY" -eq 1 ]; then
PROJECT_MEMORY_BLOCK=$(cat <<EOF

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.
EOF
)
else
PROJECT_MEMORY_BLOCK=$(cat <<'EOF'
7. Unless the task above explicitly asks you to change them, do not modify `AGENTS.md` or `CLAUDE.md` in this project, and do not run a tool that creates or edits them.
   That one shared file would otherwise be touched by every task, so concurrent PRs on the same project collide by construction.
   If this task produced durable project knowledge worth keeping, describe it in the PR body instead (or in your `done:` status line when the project ships without a PR) so it can be batched into a separate memory-only change later.
EOF
)
fi

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}
$MEMORY_BLOCK
$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

$FRESH_CHECK

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, or a review
   finding you cannot resolve on your own), append \`needs-decision: {summary of options}\`
   and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
$PROJECT_MEMORY_BLOCK

$DOD
EOF
if [ "$PROJECT_MEMORY" -eq 1 ]; then
  echo "scaffolded: $BRIEF (ship, mode=$MODE, project-memory; replace {TASK})"
else
  echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
fi
