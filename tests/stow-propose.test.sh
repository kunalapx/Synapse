#!/usr/bin/env bash
# tests/stow-propose.test.sh - behavior test for /stow's governed-memory write path.
#
# /stow is a prose skill, not a script, so there is no runnable "/stow" seam. The
# honest, scriptable contract this test locks down is the command sequence the
# stow skill now prescribes for a fleet-knowledge finding: propose it to the
# governed store as a CANDIDATE via bin/fm-memory.sh propose, and never append it
# to data/learnings.md.
#
# Covered here:
#   - the documented propose command creates status: candidate, never active;
#   - it records attribution (proposer_identity + source_task);
#   - it does NOT create or write data/learnings.md (the retired write target);
#   - the candidate is not surfaced by active recall (candidate != active read-side);
#   - the stow skill doc routes fleet knowledge to propose and retires learnings.md.
# NOT covered here: the model's prose judgment of which findings to stow and how
# it fills in the propose axes - that lives in the skill text, exercised by the
# doc-contract check below rather than by executing prose.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MEM="$ROOT/bin/fm-memory.sh"
SKILL="$ROOT/.agents/skills/stow/SKILL.md"

# A fresh home with a proposer row allowing the fleet-knowledge classes /stow
# uses (security_rule deliberately absent, exactly as in production). Identity is
# pinned via config/identity so the test never depends on the host git config.
new_home() {
  local home
  home=$(fm_test_tmproot stow-propose)
  mkdir -p "$home/config"
  printf 'human:tester@example.invalid\n' > "$home/config/identity"
  cat > "$home/config/memory-proposers.json" <<'JSON'
[{"proposer_identity":"human:tester@example.invalid","kind":"explicit_action","allowed_classes":["repo_fact","convention","architecture_decision","preference","business_knowledge"]}]
JSON
  printf '%s\n' "$home"
}

mem() { FM_HOME="$HOME_DIR" bash "$MEM" "$@"; }
entry() { printf '%s/data/memory/entries/%s.md' "$HOME_DIR" "$1"; }
field() { fm_field=$(grep -m1 "^$2:" "$(entry "$1")" | sed "s/^$2:[[:space:]]*//"); printf '%s' "$fm_field"; }

# --- the /stow-driven write path creates a CANDIDATE, never active ----------
HOME_DIR=$(new_home)
# The exact command shape the stow skill prescribes for a fleet learning
# (repo_fact class, fleet scope, evidence line + attribution in one call).
mem propose --id lint-runner-fact --type project --class repo_fact --scope fleet \
  --source-task demo-task \
  --body "bin/fm-lint.sh is the single lint owner. Evidence: bin/fm-lint.sh header." >/dev/null \
  || fail "the documented /stow propose command must succeed"
assert_present "$(entry lint-runner-fact)" "propose must create the candidate entry"
[ "$(field lint-runner-fact status)" = candidate ] \
  || fail "a /stow proposal must be status: candidate, never active"
pass "stow propose creates a candidate (never active)"

# attribution is recorded on the entry
[ "$(field lint-runner-fact proposer_identity)" = "human:tester@example.invalid" ] \
  || fail "the proposal must record the resolved proposer identity"
[ "$(field lint-runner-fact source_task)" = "demo-task" ] \
  || fail "the proposal must record its source_task attribution"
pass "stow propose records attribution"

# --- no flat-file duplication: data/learnings.md is never written -----------
assert_absent "$HOME_DIR/data/learnings.md" \
  "/stow must NOT create or append to data/learnings.md for a fleet learning"
pass "stow propose does not append the fact to data/learnings.md"

# --- candidate != active on the read side (no auto-promotion) ---------------
out=$(mem recall --scope fleet 2>&1)
assert_not_contains "$out" "lint-runner-fact" \
  "a candidate must not appear in active recall (recall lists active entries only)"
pass "the proposed candidate is not surfaced as active memory"

# --- doc contract: the skill routes fleet knowledge to propose, retires learnings.md
assert_grep 'bin/fm-memory.sh propose' "$SKILL" \
  "the stow skill must route fleet knowledge to bin/fm-memory.sh propose"
assert_grep 'retired as a write target' "$SKILL" \
  "the stow skill must state that data/learnings.md is retired as a write target"
# shellcheck disable=SC2016 # the backticks are literal skill text to match, not command expansion.
assert_no_grep 'hand-write directly, to `data/captain.md` and `data/learnings.md`' "$SKILL" \
  "the stow skill must no longer route operational facts to data/learnings.md"
pass "stow skill routes fleet knowledge to the governed store, not data/learnings.md"

printf 'all stow-propose tests passed\n'
