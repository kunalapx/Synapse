#!/usr/bin/env bash
# Static contract tests for AGENTS.md's "Validate" section: the agent, not
# Synapse, owns the self-review cycle - a mandatory build/lint/test check,
# then conditional /verify-feature, then /high-level-review - before a change
# ships.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

validate_contract() {
  awk '
    /^### Validate$/ { found = 1; next }
    found && /^### / { exit }
    found { print }
  ' "$ROOT/AGENTS.md"
}

test_agent_owns_build_lint_test_check() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" "then run the project's own build, lint, and typecheck commands and confirm they pass" \
    "Validate contract does not require the mandatory build/lint/test check"
  assert_contains "$contract" "mandatory, explicitly named step that runs before review" \
    "Validate contract does not require the build/lint/test check to be explicit and first"
  pass "Validate contract requires a mandatory, explicit build/lint/test check before review"
}

test_agent_owns_self_review() {
  local contract
  contract=$(validate_contract)

  # shellcheck disable=SC2016 # Literal backticks are the needle text, not an expansion.
  assert_contains "$contract" 'run `/verify-feature` when the task carries a tracked Notion/Dart/GitHub-Issue reference' \
    "Validate contract does not require conditional /verify-feature before review"
  # shellcheck disable=SC2016 # Literal backticks are the needle text, not an expansion.
  assert_contains "$contract" 'then `/high-level-review` against the diff vs the base branch, fixing what it flags under Critical/Architectural/Moderate itself' \
    "Validate contract does not assign self-review and self-fix to the agent"
  pass "Validate contract assigns the complete self-review cycle to the agent"
}

test_synapse_does_not_drive_validation() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" 'Synapse does not trigger or drive it' \
    "Validate contract still implies a Synapse-initiated validation step"
  pass "Validate contract confirms Synapse never drives the agent's self-review"
}

test_agent_owns_build_lint_test_check
test_agent_owns_self_review
test_synapse_does_not_drive_validation
