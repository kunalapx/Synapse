#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
#
# Ship delivery modes are direct-PR (default) and local-only; both self-review
# via /verify-feature (when ticketed) + /high-level-review before shipping
# (AGENTS.md section 7 "Validate"). A legacy "no-mistakes" registry entry is
# normalized to direct-PR by fm-project-mode.sh, so fm-brief.sh itself never
# sees that mode name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

MEM="$ROOT/bin/fm-memory.sh"

# seed_memory_home <home>: install the identity + proposer registry the governed
# memory service needs, allowing the repo_fact class (its deterministic_recheck
# gate needs only a single confirm, so it is the cheapest class to promote in a
# test). Mirrors tests/fm-memory.test.sh's fixture so nothing touches the real
# data/memory/.
seed_memory_home() {
  local home=$1
  mkdir -p "$home/config"
  printf 'human:tester@example.invalid\n' > "$home/config/identity"
  cat > "$home/config/memory-proposers.json" <<'JSON'
[{"proposer_identity":"human:tester@example.invalid","kind":"explicit_action","allowed_classes":["repo_fact"]}]
JSON
}

# promote_active_entry <home> <id> <scope> <body>: propose, confirm, and promote
# one repo_fact entry to active in <home>'s store.
promote_active_entry() {
  local home=$1 id=$2 scope=$3 body=$4
  FM_HOME="$home" bash "$MEM" propose --id "$id" --type project --class repo_fact --scope "$scope" --body "$body" >/dev/null
  FM_HOME="$home" bash "$MEM" confirm --id "$id" --gate deterministic_recheck >/dev/null
  FM_HOME="$home" bash "$MEM" promote --id "$id" >/dev/null
}

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in either of the two DOD heredoc bodies
# (direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to direct-PR.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-defaultmode-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: direct-PR/local-only briefs generate cleanly"
}

# The default (direct-PR) and local-only DODs must both carry the full
# pre-ship contract - mandatory build/lint/test check first, then conditional
# /verify-feature, then /high-level-review - with no dangling apostrophe
# artifact (issue #166 regression shape) and no leftover no-mistakes gate
# mechanics.
test_self_review_dod_wording() {
  local home brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  printf '%s\n' '- local-wording-proj [local-only] - fixture (added 2026-07-01)' > "$home/data/projects.md"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-wording-b1 some-proj >/dev/null 2>&1
  brief="$home/data/brief-wording-b1/brief.md"
  assert_present "$brief" "direct-PR brief was not scaffolded"
  assert_grep "Build/lint/test check (mandatory, first)" "$brief" \
    "direct-PR DOD lost the mandatory build/lint/test check step"
  assert_grep "If the task above references a tracked ticket" "$brief" \
    "direct-PR DOD lost the conditional /verify-feature instruction"
  assert_grep "Run /high-level-review against your diff vs the base branch" "$brief" \
    "direct-PR DOD lost the /high-level-review instruction"
  assert_no_grep "no-mistakes" "$brief" \
    "direct-PR DOD retained a no-mistakes gate reference"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-wording-b2 local-wording-proj >/dev/null 2>&1
  brief="$home/data/brief-wording-b2/brief.md"
  assert_present "$brief" "local-only brief was not scaffolded"
  assert_grep "Build/lint/test check (mandatory, first)" "$brief" \
    "local-only DOD lost the mandatory build/lint/test check step"
  assert_grep "If the task above references a tracked ticket" "$brief" \
    "local-only DOD lost the conditional /verify-feature instruction"
  assert_grep "Run /high-level-review against your diff vs the base branch" "$brief" \
    "local-only DOD lost the /high-level-review instruction"
  assert_no_grep "no-mistakes" "$brief" \
    "local-only DOD retained a no-mistakes gate reference"

  pass "fm-brief.sh: direct-PR/local-only DODs carry the full pre-ship contract cleanly"
}

# Project-memory upkeep is OFF by default: a project's AGENTS.md is one shared
# file, so scaffolding an edit instruction into every ship brief makes
# concurrent PRs on the same project conflict by construction. The default
# brief must instead forbid the edit and route the knowledge to the PR body.
test_ship_project_memory_is_off_by_default() {
  local home id brief
  home="$TMP_ROOT/project-memory-default-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_no_grep "# Project memory" "$brief" \
    "default ship brief still emits the project-memory section"
  assert_no_grep "fm-ensure-agents-md.sh" "$brief" \
    "default ship brief still tells the crewmate to run fm-ensure-agents-md.sh"
  assert_grep "Do not modify \`AGENTS.md\` or \`CLAUDE.md\` in this project" "$brief" \
    "default ship brief lost the do-not-modify constraint"
  assert_grep "describe it in the PR body instead" "$brief" \
    "default ship brief lost the surface-knowledge-in-the-PR-body instruction"
  # The DOD must not send the crewmate back to a section that no longer exists.
  assert_no_grep "per Project memory above" "$brief" \
    "default ship DOD kept a dangling pointer to the project-memory section"
  assert_no_grep "recorded into \`AGENTS.md\`" "$brief" \
    "default ship DOD still instructs recording build commands into AGENTS.md"
  pass "fm-brief.sh: ship briefs omit project-memory upkeep by default and forbid the edit"
}

# --project-memory restores the section verbatim for a task whose purpose IS
# the project's memory file, and the do-not-modify rule steps aside for it.
test_ship_project_memory_opt_in() {
  local home id brief
  home="$TMP_ROOT/project-memory-optin-home"
  mkdir -p "$home/data"
  id="brief-memory-c2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --project-memory >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "opt-in brief was not scaffolded"
  assert_grep "# Project memory" "$brief" \
    "--project-memory did not restore the project-memory section"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  assert_grep "$ROOT/bin/fm-ensure-agents-md.sh ." "$brief" \
    "project-memory contract lost the absolute fm-ensure-agents-md.sh invocation"
  assert_no_grep "Do not modify \`AGENTS.md\` or \`CLAUDE.md\` in this project" "$brief" \
    "opt-in brief kept the contradictory do-not-modify constraint"
  pass "fm-brief.sh: --project-memory restores the AGENTS.md upkeep contract"
}

# Scout and secondmate scaffolds have no project-memory contract at all, so the
# flag is rejected rather than ignored - a silent drop would leave the caller
# believing upkeep was requested.
test_project_memory_flag_is_ship_only() {
  local home status
  home="$TMP_ROOT/project-memory-kind-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pm-scout some-proj --scout >/dev/null 2>&1
  assert_no_grep "# Project memory" "$home/data/pm-scout/brief.md" \
    "scout brief emitted a project-memory section"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pm-scout-rej some-proj --scout --project-memory >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "scout --project-memory must be rejected"
  assert_absent "$home/data/pm-scout-rej/brief.md" "rejected scout --project-memory still wrote a brief"

  status=0
  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" pm-sm --secondmate alpha --project-memory >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --project-memory must be rejected"
  assert_absent "$home/data/pm-sm/brief.md" "rejected secondmate --project-memory still wrote a brief"

  pass "fm-brief.sh: --project-memory is ship-only and rejected elsewhere"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

# Scoped active memory is injected under the delimited "## Relevant project
# memory" heading of both ship and scout briefs, and only entries whose scope
# matches the resolved project appear.
test_memory_injection_matches_are_scoped() {
  local home brief
  home="$TMP_ROOT/mem-match-home"
  mkdir -p "$home/data"
  seed_memory_home "$home"
  promote_active_entry "$home" build-cmd memproj "Build with make all; the fast path is in AGENTS.md."
  promote_active_entry "$home" test-runner memproj "Tests run via bash under tests/."
  promote_active_entry "$home" other-scope otherproj "OTHER-SCOPE-ONLY-FACT should never leak."

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" mem-ship memproj >/dev/null 2>&1
  brief="$home/data/mem-ship/brief.md"
  assert_present "$brief" "ship brief not scaffolded"
  assert_grep "## Relevant project memory" "$brief" "ship brief missing the memory heading for a matching scope"
  assert_grep "Build with make all" "$brief" "ship brief did not inject a matching active fact"
  assert_grep "Tests run via bash under tests/." "$brief" "ship brief did not inject the second matching active fact"
  assert_no_grep "OTHER-SCOPE-ONLY-FACT" "$brief" "ship brief leaked an out-of-scope memory entry"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" mem-scout memproj --scout >/dev/null 2>&1
  brief="$home/data/mem-scout/brief.md"
  assert_present "$brief" "scout brief not scaffolded"
  assert_grep "## Relevant project memory" "$brief" "scout brief missing the memory heading for a matching scope"
  assert_grep "Build with make all" "$brief" "scout brief did not inject a matching active fact"
  assert_no_grep "OTHER-SCOPE-ONLY-FACT" "$brief" "scout brief leaked an out-of-scope memory entry"

  pass "fm-brief.sh: ship and scout briefs inject scoped active memory under the delimited heading"
}

# A scope with no matching active entry injects nothing at all: no empty heading,
# no noise - whether the store has only out-of-scope entries or does not exist.
test_memory_injection_no_match_is_silent() {
  local home brief home2 brief2
  home="$TMP_ROOT/mem-nomatch-home"
  mkdir -p "$home/data"
  seed_memory_home "$home"
  promote_active_entry "$home" elsewhere someotherproj "Only relevant to another project."

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" mem-empty targetproj >/dev/null 2>&1
  brief="$home/data/mem-empty/brief.md"
  assert_present "$brief" "brief not scaffolded"
  assert_no_grep "## Relevant project memory" "$brief" "brief injected an empty memory heading when nothing matched the scope"
  assert_no_grep "Only relevant to another project" "$brief" "brief leaked an out-of-scope entry"

  home2="$TMP_ROOT/mem-nostore-home"
  mkdir -p "$home2/data"
  FM_HOME="$home2" "$ROOT/bin/fm-brief.sh" mem-nostore anyproj >/dev/null 2>&1
  brief2="$home2/data/mem-nostore/brief.md"
  assert_present "$brief2" "no-store brief not scaffolded"
  assert_no_grep "## Relevant project memory" "$brief2" "brief injected a memory heading with no store present"

  pass "fm-brief.sh: a scope with no matching active memory injects nothing (no heading, no noise)"
}

# The injection is hard-capped: when the scoped active entries exceed the
# character budget, the block truncates on whole entries and says so, rather
# than blowing the crewmate's context.
test_memory_injection_respects_cap() {
  local home brief block_chars n big
  home="$TMP_ROOT/mem-cap-home"
  mkdir -p "$home/data"
  seed_memory_home "$home"
  # Distinct fact families (a numeric-only suffix would collapse to one family
  # and open conflicts instead of promoting), each large enough that they
  # cannot all fit under the ~2000-char budget.
  big=$(printf 'x%.0s' $(seq 1 700))
  for n in alpha bravo charlie delta echo foxtrot; do
    promote_active_entry "$home" "cap-$n" capproj "marker-$n $big"
  done

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" mem-cap capproj >/dev/null 2>&1
  brief="$home/data/mem-cap/brief.md"
  assert_present "$brief" "cap brief not scaffolded"
  assert_grep "## Relevant project memory" "$brief" "cap brief lost the memory heading"
  assert_grep "Truncated to fit the memory injection budget" "$brief" "cap brief did not flag truncation when entries exceeded the budget"
  assert_grep "marker-alpha" "$brief" "cap brief dropped even the first entry"
  assert_no_grep "marker-foxtrot" "$brief" "cap brief injected past the budget instead of truncating"

  # The injected block itself stays bounded: all six entries (~4300 chars) never
  # fit, so a block well under that proves the cap actually stopped injection.
  block_chars=$(awk '/^## Relevant project memory$/{f=1} /^# Herdr/{f=0} f' "$brief" | wc -c)
  [ "$block_chars" -le 2500 ] || fail "injected memory block exceeded the budget ($block_chars chars)"

  pass "fm-brief.sh: memory injection stops at the size cap and flags the truncation"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_self_review_dod_wording
test_ship_project_memory_is_off_by_default
test_ship_project_memory_opt_in
test_project_memory_flag_is_ship_only
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_memory_injection_matches_are_scoped
test_memory_injection_no_match_is_silent
test_memory_injection_respects_cap
