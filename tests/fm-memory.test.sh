#!/usr/bin/env bash
# tests/fm-memory.test.sh - behavior tests for the governed memory service.
#
# Focus: the three structural non-auto-promotion guarantees and the six class
# gates. Each test runs the real bin/fm-memory.sh against a throwaway FM_HOME so
# nothing touches the operator's own data/memory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MEM="$ROOT/bin/fm-memory.sh"

# A fresh home with the single Phase-2 proposer row (security_rule deliberately
# absent from allowed_classes). Identity is pinned via config/identity so the
# test never depends on the host git config.
new_home() {
  local home
  home=$(fm_test_tmproot fm-memory)
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

# --- structural check 1: propose is candidate-only -------------------------
HOME_DIR=$(new_home)
out=$(mem propose --id c1 --type project --class repo_fact --scope fleet --status active --body "x" 2>&1); rc=$?
expect_code 2 "$rc" "propose --status active must be rejected"
assert_contains "$out" "no --status flag" "propose must explain the missing --status flag"
assert_absent "$(entry c1)" "no entry file may be written when propose is rejected"

out=$(mem propose --id c1 --type project --class repo_fact --scope fleet --body "bin/fm-lint.sh exists." 2>&1)
[ "$(field c1 status)" = candidate ] || fail "a proposed entry must be status: candidate"
pass "check 1: propose writes only status: candidate"

# --- structural check 2: promote needs a passing gate; no --force ----------
out=$(mem promote --id c1 2>&1); rc=$?
expect_code 7 "$rc" "promote without a passing validation row must fail"
assert_contains "$out" "no passing" "promote must explain the missing validation row"
[ "$(field c1 status)" = candidate ] || fail "a refused promote must not change status"

out=$(mem promote --id c1 --force 2>&1); rc=$?
expect_code 2 "$rc" "promote --force must be rejected (no such flag)"

mem confirm --id c1 --gate deterministic_recheck >/dev/null
mem promote --id c1 >/dev/null || fail "promote must succeed after a matching validation row"
[ "$(field c1 status)" = active ] || fail "promote must set status: active"
pass "check 2: promote is the only path to active and re-checks the gate"

# edit invalidates a prior pass (content hash changes)
HOME_DIR=$(new_home)
mem propose --id c2 --type project --class architecture_decision --scope fleet --body "Original." >/dev/null
mem confirm --id c2 --gate boss_confirmation >/dev/null
# mutate the body after the pass
sed -i 's/Original\./Edited./' "$(entry c2)"
out=$(mem promote --id c2 2>&1); rc=$?
expect_code 7 "$rc" "an edit after a pass must invalidate that pass"
[ "$(field c2 status)" = candidate ] || fail "promote refused on stale hash must not activate"
pass "check 2b: editing the body invalidates a prior validation pass"

# --- structural check 3: secret scan refuses before writing ----------------
HOME_DIR=$(new_home)
out=$(mem propose --id c3 --type project --class repo_fact --scope fleet \
  --body "leak AKIAIOSFODNN7EXAMPLE here" 2>&1); rc=$?
expect_code 5 "$rc" "propose must refuse content with a secret shape"
assert_absent "$(entry c3)" "no entry file may be written when the secret scan refuses"
pass "check 3: secret scan refuses a candidate before writing"

# --- security_rule can never be proposed (not in allowed_classes) ----------
HOME_DIR=$(new_home)
out=$(mem propose --id sr --type project --class security_rule --scope fleet --body "no plaintext creds" 2>&1); rc=$?
expect_code 4 "$rc" "security_rule must be refused by the proposer registry"
assert_absent "$(entry sr)" "a registry-refused class must not write an entry"
pass "security_rule is structurally un-proposable by the Phase-2 proposer"

# --- corroboration uniqueness + convention gate ----------------------------
HOME_DIR=$(new_home)
mem propose --id conv --type project --class convention --scope fleet --body "Uses tabs." >/dev/null
mem corroborate --id conv --source-task t1 --evidence-kind code_presence --evidence "in a.sh" >/dev/null
out=$(mem corroborate --id conv --source-task t1 --evidence-kind file_reference --evidence "dup" 2>&1); rc=$?
expect_code 6 "$rc" "a duplicate source_task corroboration must be refused"
lines=$(wc -l < "$HOME_DIR/data/memory/corroborations/conv.jsonl")
[ "$lines" = 1 ] || fail "the duplicate corroboration must not be appended (have $lines lines)"

mem confirm --id conv --gate code_corroboration >/dev/null
out=$(mem promote --id conv 2>&1); rc=$?
expect_code 7 "$rc" "convention with only 1 corroboration must not promote"
mem corroborate --id conv --source-task t2 --evidence-kind file_reference --evidence "in b.sh" >/dev/null
mem promote --id conv >/dev/null || fail "convention must promote with 2 distinct corroborations (1 code_presence) + gate"
[ "$(field conv status)" = active ] || fail "convention should be active after gate satisfied"
pass "convention gate: 2 distinct corroborations, >=1 code_presence, plus re-check"

# --- business_knowledge review_by + sweep-stale ----------------------------
HOME_DIR=$(new_home)
mem propose --id bk --type project --class business_knowledge --scope proj --review-by 2000-01-01 --body "Old." >/dev/null
mem confirm --id bk --gate owner_assertion >/dev/null
mem promote --id bk >/dev/null || fail "business_knowledge with review_by must promote"
mem propose --id bk2 --type project --class business_knowledge --scope proj --body "No date." >/dev/null
mem confirm --id bk2 --gate owner_assertion >/dev/null
out=$(mem promote --id bk2 2>&1); rc=$?
expect_code 7 "$rc" "business_knowledge without review_by must not promote"
mem sweep-stale >/dev/null
[ "$(field bk status)" = stale ] || fail "sweep-stale must flip a past-review entry to stale"
pass "business_knowledge requires review_by; sweep-stale flips past-review entries"

# --- supersede + conflict/resolve ------------------------------------------
HOME_DIR=$(new_home)
mem propose --id fact --type project --class preference --scope fleet --body "v1." >/dev/null
mem confirm --id fact --gate owner_assertion >/dev/null
mem promote --id fact >/dev/null
# a same-family candidate opens a conflict rather than auto-superseding
out=$(mem propose --id fact-v2 --type project --class preference --scope fleet --body "v2." 2>&1)
assert_contains "$out" "CONFLICT" "a same-family candidate must open a conflict"
[ "$(field fact-v2 status)" = conflict ] || fail "the overlapping candidate must be status: conflict"
out=$(mem promote --id fact-v2 2>&1); rc=$?
expect_code 2 "$rc" "a conflicted candidate cannot be promoted directly"
mem confirm --id fact-v2 --gate owner_assertion >/dev/null
mem resolve --candidate fact-v2 --resolution candidate_promoted >/dev/null || fail "resolve must promote after the gate passes"
[ "$(field fact status)" = superseded ] || fail "the old active must be superseded"
[ "$(field fact superseded_by)" = fact-v2 ] || fail "superseded_by must point at the new active"
[ "$(field fact-v2 status)" = active ] || fail "the resolved candidate must be active"
# exactly one active for the family
actives=$(grep -l '^status: active' "$HOME_DIR"/data/memory/entries/fact*.md | wc -l)
[ "$actives" = 1 ] || fail "there must be exactly one active entry per fact family (have $actives)"
pass "supersede + conflict/resolve keeps exactly one active per fact family"

# --- MEMORY.md index only lists active entries -----------------------------
grep -q 'entries/fact-v2.md' "$HOME_DIR/data/memory/MEMORY.md" || fail "MEMORY.md must list the active entry"
grep -q 'entries/fact.md)' "$HOME_DIR/data/memory/MEMORY.md" && fail "MEMORY.md must not list a superseded entry"
pass "MEMORY.md indexes active entries only"

# --- identity attribution is recorded on the entry -------------------------
HOME_DIR=$(new_home)
mem propose --id id1 --type project --class repo_fact --scope fleet --body "attributed." >/dev/null
[ "$(field id1 proposer_identity)" = "human:tester@example.invalid" ] \
  || fail "the entry must record the resolved proposer identity"
pass "identity resolves from config/identity and is recorded on the entry"

printf 'all fm-memory tests passed\n'
