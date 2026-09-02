#!/usr/bin/env bash
# fm-memory.sh - Synapse's governed, harness-agnostic memory service (flat files).
#
# Memory is GOVERNED, not a shared notes folder: no caller ever writes straight
# to trusted (active) memory. An agent proposes a candidate with evidence and
# attribution; a class-specific validation gate must pass; only then can it be
# promoted to active. A candidate that overlaps an existing active entry for the
# same fact opens a conflict for human resolution rather than auto-superseding.
#
# Storage (all under $FM_HOME/data/memory, gitignored with the rest of data/):
#   entries/<id>.md            one entry, YAML frontmatter + prose body
#   corroborations/<id>.jsonl  append-only evidence lines (unique per source_task)
#   validations/<id>.jsonl     append-only gate-run lines (pass/fail + content_hash)
#   conflicts/<id>.md          one open/resolved conflict per candidate
#   MEMORY.md                  active-only recall index, regenerated on state change
# Proposer registry: $FM_HOME/config/memory-proposers.json (gitignored).
#
# Two orthogonal axes per entry:
#   type            recall taxonomy: user|feedback|project|reference
#   validation_class what it must clear to become authoritative (six classes ->
#                    six gates; see the table under `promote`).
# They correlate but neither determines the other.
#
# Structural non-auto-promotion (enforced in code, not just policy):
#   1. propose has NO --status flag; it can only ever write status: candidate.
#   2. promote is the ONLY verb that writes status: active, has no
#      --force/--skip, re-derives the class gate, and refuses unless a matching
#      passing validation row exists for the entry's CURRENT content hash.
#   3. propose runs a mandatory secret-pattern scan (bin/fm-secret-scan.sh)
#      BEFORE writing anything; a match refuses the write outright.
#
# Portability: this environment may lack jq. The script prefers python3, then
# jq, then a pure grep/sed/awk fallback for the one JSON file it must read
# (the proposer registry). Everything else is line-oriented JSON the script
# both writes and reads, so grep/awk suffice. sha256 uses sha256sum, then
# shasum, then python3.
#
# Verbs (see `fm-memory.sh <verb> --help` style usage in each handler):
#   propose corroborate confirm promote conflicts resolve recall sweep-stale retire
#
# retire removes trust from a single entry that is no longer the system of
# record (a duplicate, a moved-home fact, or a fact that is no longer true):
# it flips status to retired so recall and MEMORY.md drop it, records the
# reason and a retire attribution, and preserves the file for audit. It is a
# REMOVAL of trust, so unlike promote it runs no validation gate; it stays
# deliberate by acting on exactly one given id, never a wildcard.
#
# Usage: fm-memory.sh <verb> [options]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

MEM="$DATA/memory"
ENTRIES="$MEM/entries"
CORROB="$MEM/corroborations"
VALID="$MEM/validations"
CONFLICTS="$MEM/conflicts"
MEMINDEX="$MEM/MEMORY.md"
PROPOSERS="$CONFIG/memory-proposers.json"

SECRET_SCAN="$SCRIPT_DIR/fm-secret-scan.sh"

VALID_TYPES="user feedback project reference"
VALID_CLASSES="repo_fact convention architecture_decision security_rule preference business_knowledge"
VALID_EVIDENCE="code_presence file_reference repro command_output"

die() { printf 'fm-memory: %s\n' "$1" >&2; exit "${2:-1}"; }

today() { date +%F; }

# --- identity ---------------------------------------------------------------
# Resolve config/identity -> git config user.email -> fail loud. The one human
# principal is human:<git-email>; the grammar is <kind>:<id> with kind in
# human|agent|system. A config/identity value that already carries a kind prefix
# is used verbatim; a bare value is treated as an email (human:<value>).
fm_identity() {
  local raw email
  if [ -f "$CONFIG/identity" ]; then
    raw=$(grep -v '^[[:space:]]*#' "$CONFIG/identity" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')
    if [ -n "$raw" ]; then
      case "$raw" in
        human:*|agent:*|system:*) printf '%s\n' "$raw"; return 0 ;;
        *) printf 'human:%s\n' "$raw"; return 0 ;;
      esac
    fi
  fi
  email=$(git config user.email 2>/dev/null || true)
  if [ -n "$email" ]; then
    printf 'human:%s\n' "$email"
    return 0
  fi
  die "cannot resolve identity: no config/identity and no git user.email" 3
}

# --- hashing ----------------------------------------------------------------
fm_hash() { # hash stdin, print hex digest only
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,hashlib;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    die "no sha256 tool available (need sha256sum, shasum, or python3)"
  fi
}

# --- frontmatter helpers ----------------------------------------------------
fm_fm_get() { # <file> <key> -> value (empty if absent)
  awk -v k="$2" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm {
      idx=index($0,":")
      if (idx>0) {
        fk=substr($0,1,idx-1); gsub(/^[ \t]+|[ \t]+$/,"",fk)
        if (fk==k) { v=substr($0,idx+1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit }
      }
    }' "$1"
}

fm_fm_body() { # <file> -> body bytes (everything after the closing ---)
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { infm=0; started=1; next }
    started { print }' "$1"
}

fm_body_hash() { fm_fm_body "$1" | fm_hash; }

fm_fm_set() { # <file> <key> <value> : rewrite one frontmatter field in place
  local file=$1 key=$2 val=$3 tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$val" '
    NR==1 && $0=="---" { infm=1; print; next }
    infm && $0=="---" { infm=0; print; next }
    infm && !done {
      idx=index($0,":")
      if (idx>0) {
        fk=substr($0,1,idx-1); gsub(/^[ \t]+|[ \t]+$/,"",fk)
        if (fk==k) { print k ": " v; done=1; next }
      }
    }
    { print }' "$file" > "$tmp" && mv "$tmp" "$file"
}

fm_fm_upsert() { # <file> <key> <value> : set a frontmatter field, inserting it before the closing --- when absent
  local file=$1 key=$2 val=$3 tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$val" '
    NR==1 && $0=="---" { infm=1; print; next }
    infm && $0=="---" {
      if (!done) { print k ": " v; done=1 }
      infm=0; print; next
    }
    infm && !done {
      idx=index($0,":")
      if (idx>0) {
        fk=substr($0,1,idx-1); gsub(/^[ \t]+|[ \t]+$/,"",fk)
        if (fk==k) { print k ": " v; done=1; next }
      }
    }
    { print }' "$file" > "$tmp" && mv "$tmp" "$file"
}

fm_title_of() { # <file> -> a display title (first non-empty body line, trimmed)
  fm_fm_body "$1" | grep -m1 -v '^[[:space:]]*$' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-80
}

# --- json helpers -----------------------------------------------------------
fm_json_escape() { # <string> -> escaped inner value (no surrounding quotes)
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t\r' '   '
}

# --- validation membership --------------------------------------------------
in_list() { # <needle> <space-separated-list>
  local n=$1 l
  for l in $2; do [ "$l" = "$n" ] && return 0; done
  return 1
}

# --- slug family (for supersede detection) ----------------------------------
# Two entries are the same fact family iff same scope AND same family slug. The
# family slug is the id with a trailing version-like segment (-v2, -r3, -2)
# removed, so `login-fix-v2` supersedes active `login-fix` while distinct
# descriptive slugs never collide.
fm_slug_family() { printf '%s' "$1" | sed -E 's/-(v[0-9]+|r[0-9]+|[0-9]+)$//'; }

fm_find_active_same_family() { # <scope> <family> [exclude-id] -> ids (one per line)
  local scope=$1 family=$2 exclude=${3:-} f eid escope estatus efam
  [ -d "$ENTRIES" ] || return 0
  for f in "$ENTRIES"/*.md; do
    [ -e "$f" ] || continue
    estatus=$(fm_fm_get "$f" status)
    [ "$estatus" = active ] || continue
    escope=$(fm_fm_get "$f" scope)
    [ "$escope" = "$scope" ] || continue
    eid=$(fm_fm_get "$f" id)
    [ -n "$exclude" ] && [ "$eid" = "$exclude" ] && continue
    efam=$(fm_slug_family "$eid")
    [ "$efam" = "$family" ] && printf '%s\n' "$eid"
  done
}

# --- proposer registry predicate --------------------------------------------
# 0 if <identity> is registered and its allowed_classes includes <class>.
fm_proposer_allows() {
  local identity=$1 class=$2
  [ -f "$PROPOSERS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PROPOSERS" "$identity" "$class" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
ident, cls = sys.argv[2], sys.argv[3]
for r in rows:
    if r.get("proposer_identity") == ident and cls in (r.get("allowed_classes") or []):
        sys.exit(0)
sys.exit(1)
PY
    return $?
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg id "$identity" --arg c "$class" \
      'any(.[]; .proposer_identity==$id and ((.allowed_classes // []) | index($c)))' \
      "$PROPOSERS" >/dev/null 2>&1
    return $?
  fi
  # Pure-shell fallback: split the JSON into per-object records on the closing
  # brace, then require the requested class token to appear inside the SAME
  # record as the matching proposer_identity. security_rule is never listed in
  # any allowed_classes, so this correctly refuses it.
  awk -v id="$identity" -v cls="$class" '
    BEGIN { RS="}" ; found=0 }
    index($0, "\"proposer_identity\"") && index($0, "\"" id "\"") {
      if (index($0, "\"" cls "\"")) found=1
    }
    END { exit(found?0:1) }' "$PROPOSERS"
}

# --- validation-row lookup --------------------------------------------------
fm_has_passing_validation() { # <entry-id> <gate> <content_hash> <require_human:0|1>
  local id=$1 gate=$2 hash=$3 human=$4 file="$VALID/$1.jsonl"
  [ -f "$file" ] || return 1
  awk -v g="$gate" -v h="$hash" -v hum="$human" '
    index($0, "\"gate\":\"" g "\"") \
      && index($0, "\"verdict\":\"pass\"") \
      && index($0, "\"content_hash\":\"" h "\"") {
        if (hum=="1") { if (index($0, "\"checker_identity\":\"human:")) found=1 }
        else found=1
      }
    END { exit(found?0:1) }' "$file"
}

# --- corroboration stats ----------------------------------------------------
fm_corrob_stats() { # <entry-id> -> "<distinct_source_tasks> <code_presence_count>"
  local file="$CORROB/$1.jsonl"
  [ -f "$file" ] || { echo "0 0"; return; }
  awk '
    {
      st=""; ek=""
      if (match($0, /"source_task":"[^"]*"/)) { st=substr($0,RSTART,RLENGTH); sub(/"source_task":"/,"",st); sub(/"$/,"",st) }
      if (match($0, /"evidence_kind":"[^"]*"/)) { ek=substr($0,RSTART,RLENGTH); sub(/"evidence_kind":"/,"",ek); sub(/"$/,"",ek) }
      if (st!="") seen[st]=1
      if (ek=="code_presence") cp++
    }
    END { n=0; for (k in seen) n++; print n, cp+0 }' "$file"
}

# --- class -> gate ----------------------------------------------------------
gate_for_class() {
  case "$1" in
    repo_fact) echo deterministic_recheck ;;
    convention) echo code_corroboration ;;
    architecture_decision) echo boss_confirmation ;;
    security_rule) echo human_signoff ;;
    preference|business_knowledge) echo owner_assertion ;;
    *) return 1 ;;
  esac
}

# --- MEMORY.md regeneration -------------------------------------------------
fm_regen_index() {
  local f id title tmp
  tmp=$(mktemp)
  {
    printf '# Synapse memory index\n\n'
    printf 'Active, promoted entries only. Regenerated by bin/fm-memory.sh on every\n'
    printf 'promote/resolve/sweep-stale/retire. Do not hand-edit.\n\n'
  } > "$tmp"
  if [ -d "$ENTRIES" ]; then
    for f in "$ENTRIES"/*.md; do
      [ -e "$f" ] || continue
      [ "$(fm_fm_get "$f" status)" = active ] || continue
      id=$(fm_fm_get "$f" id)
      title=$(fm_title_of "$f")
      printf -- '- [%s](entries/%s.md) — %s\n' "$id" "$id" "$title" >> "$tmp"
    done
  fi
  mv "$tmp" "$MEMINDEX"
}

ensure_dirs() { mkdir -p "$ENTRIES" "$CORROB" "$VALID" "$CONFLICTS"; }

# =========================================================================
# propose
# =========================================================================
cmd_propose() {
  local id='' type='' class='' scope='' source_task=null source_agent=null review_by=null body='' bodyfile=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --type) type=${2:-}; shift 2 ;;
      --class) class=${2:-}; shift 2 ;;
      --scope) scope=${2:-}; shift 2 ;;
      --source-task) source_task=${2:-}; shift 2 ;;
      --source-agent) source_agent=${2:-}; shift 2 ;;
      --review-by) review_by=${2:-}; shift 2 ;;
      --body) body=${2:-}; shift 2 ;;
      --body-file) bodyfile=${2:-}; shift 2 ;;
      --status) die "propose has no --status flag: a proposed entry is ALWAYS a candidate (structural non-auto-promotion check 1)" 2 ;;
      *) die "propose: unknown argument: $1" 2 ;;
    esac
  done

  [ -n "$id" ] || die "propose: --id required" 2
  [ -n "$type" ] || die "propose: --type required" 2
  [ -n "$class" ] || die "propose: --class required" 2
  [ -n "$scope" ] || die "propose: --scope required" 2
  in_list "$type" "$VALID_TYPES" || die "propose: invalid --type '$type' (one of: $VALID_TYPES)" 2
  in_list "$class" "$VALID_CLASSES" || die "propose: invalid --class '$class' (one of: $VALID_CLASSES)" 2
  case "$id" in *[!a-z0-9-]*|"") die "propose: --id must be a kebab slug (a-z0-9-): '$id'" 2 ;; esac

  ensure_dirs
  local file="$ENTRIES/$id.md"
  [ -e "$file" ] && die "propose: entry already exists: $id (propose is create-only)" 2

  # Resolve body from --body-file or --body.
  if [ -n "$bodyfile" ]; then
    [ -f "$bodyfile" ] || die "propose: --body-file not found: $bodyfile" 2
    body=$(cat "$bodyfile")
  fi
  [ -n "$body" ] || die "propose: body required (--body or --body-file)" 2

  # Registry check: the proposer must be allowed to propose this class. This is
  # how security_rule can never be auto-extracted: no registry row lists it.
  local identity
  identity=$(fm_identity) || exit $?
  if ! fm_proposer_allows "$identity" "$class"; then
    die "propose: proposer '$identity' is not permitted to propose class '$class' per $PROPOSERS (nothing written)" 4
  fi

  # Mandatory secret scan BEFORE writing anything.
  if [ -x "$SECRET_SCAN" ]; then
    if ! printf '%s' "$body" | "$SECRET_SCAN"; then
      die "propose: content refused by secret scan (nothing written)" 5
    fi
  else
    die "propose: secret scanner missing or not executable: $SECRET_SCAN" 5
  fi

  # business_knowledge should carry a review_by; warn if absent (promote enforces).
  local created; created=$(today)

  # Write the candidate with a placeholder hash, then set the real body hash so
  # write-time and promote-time hashing use the identical body representation.
  {
    printf -- '---\n'
    printf 'id: %s\n' "$id"
    printf 'type: %s\n' "$type"
    printf 'validation_class: %s\n' "$class"
    printf 'scope: %s\n' "$scope"
    printf 'status: candidate\n'
    printf 'proposer_identity: %s\n' "$identity"
    printf 'source_task: %s\n' "$source_task"
    printf 'source_agent: %s\n' "$source_agent"
    printf 'superseded_by: null\n'
    printf 'review_by: %s\n' "$review_by"
    printf 'last_corroborated_at: null\n'
    printf 'content_hash: PENDING\n'
    printf 'created_at: %s\n' "$created"
    printf -- '---\n'
    printf '%s\n' "$body"
  } > "$file"

  local h; h=$(fm_body_hash "$file")
  fm_fm_set "$file" content_hash "$h"

  # If an active entry already covers this fact family, open a conflict so it is
  # resolved rather than silently superseded. The entry stays a candidate.
  local family conflicting
  family=$(fm_slug_family "$id")
  conflicting=$(fm_find_active_same_family "$scope" "$family" "$id")
  if [ -n "$conflicting" ]; then
    local active_id; active_id=$(printf '%s\n' "$conflicting" | head -1)
    {
      printf -- '---\n'
      printf 'candidate_id: %s\n' "$id"
      printf 'active_id: %s\n' "$active_id"
      printf 'opened_at: %s\n' "$created"
      printf 'resolution: null\n'
      printf 'resolved_at: null\n'
      printf -- '---\n'
      printf 'Candidate %s overlaps active %s for the same fact family (%s, scope %s).\n' "$id" "$active_id" "$family" "$scope"
      printf 'Resolve with: fm-memory.sh resolve --candidate %s --resolution candidate_promoted|candidate_rejected\n' "$id"
    } > "$CONFLICTS/$id.md"
    fm_fm_set "$file" status conflict
    printf 'proposed %s as CONFLICT against active %s: %s\n' "$id" "$active_id" "$file"
    printf 'resolve it via: fm-memory.sh resolve --candidate %s --resolution ...\n' "$id"
    return 0
  fi

  printf 'proposed candidate %s (%s / %s, scope %s): %s\n' "$id" "$type" "$class" "$scope" "$file"
}

# =========================================================================
# corroborate
# =========================================================================
cmd_corroborate() {
  local id='' source_task='' kind='' evidence=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --source-task) source_task=${2:-}; shift 2 ;;
      --evidence-kind) kind=${2:-}; shift 2 ;;
      --evidence) evidence=${2:-}; shift 2 ;;
      *) die "corroborate: unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$id" ] || die "corroborate: --id required" 2
  [ -n "$source_task" ] || die "corroborate: --source-task required" 2
  [ -n "$kind" ] || die "corroborate: --evidence-kind required" 2
  [ -n "$evidence" ] || die "corroborate: --evidence required" 2
  in_list "$kind" "$VALID_EVIDENCE" || die "corroborate: invalid --evidence-kind '$kind' (one of: $VALID_EVIDENCE)" 2
  local file="$ENTRIES/$id.md"
  [ -f "$file" ] || die "corroborate: no such entry: $id" 2

  ensure_dirs
  local cfile="$CORROB/$id.jsonl"
  # Reject a duplicate source_task for this entry (flat-file UNIQUE(entry,source_task)).
  if [ -f "$cfile" ] && grep -Fq "\"source_task\":\"$source_task\"" "$cfile"; then
    die "corroborate: source_task '$source_task' already corroborated entry '$id' (duplicate refused, nothing appended)" 6
  fi

  printf '{"source_task":"%s","evidence_kind":"%s","evidence":"%s","ts":"%s"}\n' \
    "$(fm_json_escape "$source_task")" "$kind" "$(fm_json_escape "$evidence")" "$(today)" >> "$cfile"
  fm_fm_set "$file" last_corroborated_at "$(today)"
  printf 'corroborated %s from %s (%s)\n' "$id" "$source_task" "$kind"
}

# =========================================================================
# confirm - record a validation gate run (pass/fail) for an entry.
# =========================================================================
cmd_confirm() {
  local id='' gate='' verdict=pass
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --gate) gate=${2:-}; shift 2 ;;
      --verdict) verdict=${2:-}; shift 2 ;;
      *) die "confirm: unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$id" ] || die "confirm: --id required" 2
  local file="$ENTRIES/$id.md"
  [ -f "$file" ] || die "confirm: no such entry: $id" 2
  case "$verdict" in pass|fail) ;; *) die "confirm: --verdict must be pass or fail" 2 ;; esac

  # Default the gate to the entry's class gate when not given.
  if [ -z "$gate" ]; then
    local class; class=$(fm_fm_get "$file" validation_class)
    gate=$(gate_for_class "$class") || die "confirm: cannot derive gate for class '$class'" 2
  fi
  case "$gate" in
    deterministic_recheck|code_corroboration|boss_confirmation|human_signoff|owner_assertion) ;;
    *) die "confirm: invalid --gate '$gate'" 2 ;;
  esac

  ensure_dirs
  local identity h
  identity=$(fm_identity) || exit $?
  h=$(fm_body_hash "$file")
  printf '{"gate":"%s","verdict":"%s","checker_identity":"%s","content_hash":"%s","ran_at":"%s"}\n' \
    "$gate" "$verdict" "$(fm_json_escape "$identity")" "$h" "$(today)" >> "$VALID/$id.jsonl"
  printf 'recorded %s validation for %s: gate=%s by %s (hash %s)\n' "$verdict" "$id" "$gate" "$identity" "${h:0:12}"
}

# =========================================================================
# _gate_ok <file> - shared gate check used by promote and resolve.
# Prints nothing; returns 0 if the entry's class gate is satisfied for its
# CURRENT content hash, else prints the reason and returns 1.
# =========================================================================
_gate_ok() {
  local file=$1 id class gate hash human=0
  id=$(fm_fm_get "$file" id)
  class=$(fm_fm_get "$file" validation_class)
  gate=$(gate_for_class "$class") || { echo "unknown class '$class'"; return 1; }
  hash=$(fm_body_hash "$file")

  case "$class" in
    architecture_decision|security_rule|preference|business_knowledge) human=1 ;;
    *) human=0 ;;
  esac

  if ! fm_has_passing_validation "$id" "$gate" "$hash" "$human"; then
    local hint=
    [ "$human" = 1 ] && hint=" (human checker required)"
    echo "no passing '$gate' validation row for current content hash$hint"
    return 1
  fi

  if [ "$class" = convention ]; then
    local stats n cp
    stats=$(fm_corrob_stats "$id"); n=${stats% *}; cp=${stats#* }
    if [ "$n" -lt 2 ]; then echo "convention needs >=2 corroborations from distinct source_task (have $n)"; return 1; fi
    if [ "$cp" -lt 1 ]; then echo "convention needs >=1 corroboration with evidence_kind code_presence (have $cp)"; return 1; fi
  fi

  if [ "$class" = business_knowledge ]; then
    local rb; rb=$(fm_fm_get "$file" review_by)
    if [ -z "$rb" ] || [ "$rb" = null ]; then echo "business_knowledge requires review_by to be set"; return 1; fi
  fi
  return 0
}

# _supersede <candidate-id> <scope> - flip any active same-family entry to
# superseded, atomically pointing it at the candidate. Called only from the
# promote path, after the gate check has passed.
_supersede() {
  local cand=$1 scope=$2 family others oid
  family=$(fm_slug_family "$cand")
  others=$(fm_find_active_same_family "$scope" "$family" "$cand")
  [ -n "$others" ] || return 0
  while IFS= read -r oid; do
    [ -n "$oid" ] || continue
    fm_fm_set "$ENTRIES/$oid.md" superseded_by "$cand"
    fm_fm_set "$ENTRIES/$oid.md" status superseded
    printf 'superseded active %s -> %s\n' "$oid" "$cand"
  done <<EOF
$others
EOF
}

# =========================================================================
# promote - the ONLY path to status: active.
# =========================================================================
cmd_promote() {
  local id=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --force|--skip) die "promote has no $1 flag: promotion always re-checks the gate (structural non-auto-promotion check 2)" 2 ;;
      *) die "promote: unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$id" ] || die "promote: --id required" 2
  local file="$ENTRIES/$id.md"
  [ -f "$file" ] || die "promote: no such entry: $id" 2

  local status; status=$(fm_fm_get "$file" status)
  case "$status" in
    candidate) ;;
    conflict) die "promote: $id has an open conflict; resolve it with 'fm-memory.sh resolve --candidate $id --resolution ...' (never auto-supersede)" 2 ;;
    active) die "promote: $id is already active" 2 ;;
    *) die "promote: $id has status '$status'; only a candidate can be promoted" 2 ;;
  esac

  local reason
  if ! reason=$(_gate_ok "$file"); then
    die "promote: refused - $reason (nothing written)" 7
  fi

  local scope; scope=$(fm_fm_get "$file" scope)
  _supersede "$id" "$scope"
  fm_fm_set "$file" status active
  fm_regen_index
  printf 'promoted %s to active\n' "$id"
}

# =========================================================================
# conflicts - list open conflicts.
# =========================================================================
cmd_conflicts() {
  ensure_dirs
  local f any=0 res
  for f in "$CONFLICTS"/*.md; do
    [ -e "$f" ] || continue
    res=$(fm_fm_get "$f" resolution)
    if [ -z "$res" ] || [ "$res" = null ]; then
      any=1
      printf 'OPEN  candidate=%s active=%s opened=%s\n' \
        "$(fm_fm_get "$f" candidate_id)" "$(fm_fm_get "$f" active_id)" "$(fm_fm_get "$f" opened_at)"
    fi
  done
  [ "$any" = 0 ] && printf '(no open conflicts)\n'
  return 0
}

# =========================================================================
# resolve - resolve an open conflict (promote the candidate or reject it).
# =========================================================================
cmd_resolve() {
  local cand='' resolution=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --candidate) cand=${2:-}; shift 2 ;;
      --resolution) resolution=${2:-}; shift 2 ;;
      *) die "resolve: unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$cand" ] || die "resolve: --candidate required" 2
  case "$resolution" in candidate_promoted|candidate_rejected) ;; *) die "resolve: --resolution must be candidate_promoted or candidate_rejected" 2 ;; esac
  local cfile="$CONFLICTS/$cand.md" efile="$ENTRIES/$cand.md"
  [ -f "$cfile" ] || die "resolve: no conflict for candidate: $cand" 2
  [ -f "$efile" ] || die "resolve: candidate entry missing: $cand" 2
  local res; res=$(fm_fm_get "$cfile" resolution)
  if [ -n "$res" ] && [ "$res" != null ]; then die "resolve: conflict for $cand already resolved ($res)" 2; fi

  if [ "$resolution" = candidate_promoted ]; then
    local reason
    if ! reason=$(_gate_ok "$efile"); then
      die "resolve: cannot promote $cand - $reason (nothing written)" 7
    fi
    local scope; scope=$(fm_fm_get "$efile" scope)
    _supersede "$cand" "$scope"
    fm_fm_set "$efile" status active
  else
    fm_fm_set "$efile" status rejected
  fi
  fm_fm_set "$cfile" resolution "$resolution"
  fm_fm_set "$cfile" resolved_at "$(today)"
  fm_regen_index
  printf 'resolved conflict for %s: %s\n' "$cand" "$resolution"
}

# =========================================================================
# recall - read active memory (optionally filtered).
# =========================================================================
cmd_recall() {
  local scope='' type='' class='' query=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scope) scope=${2:-}; shift 2 ;;
      --type) type=${2:-}; shift 2 ;;
      --class) class=${2:-}; shift 2 ;;
      *) query=$1; shift ;;
    esac
  done
  [ -d "$ENTRIES" ] || { printf '(no memory)\n'; return 0; }
  local f any=0 eid etype eclass escope
  for f in "$ENTRIES"/*.md; do
    [ -e "$f" ] || continue
    [ "$(fm_fm_get "$f" status)" = active ] || continue
    eid=$(fm_fm_get "$f" id); etype=$(fm_fm_get "$f" type)
    eclass=$(fm_fm_get "$f" validation_class); escope=$(fm_fm_get "$f" scope)
    [ -n "$scope" ] && [ "$escope" != "$scope" ] && continue
    [ -n "$type" ] && [ "$etype" != "$type" ] && continue
    [ -n "$class" ] && [ "$eclass" != "$class" ] && continue
    if [ -n "$query" ]; then grep -iqF -- "$query" "$f" || continue; fi
    any=1
    printf '%-40s %-9s %-22s %-12s %s\n' "$eid" "$etype" "$eclass" "$escope" "$(fm_title_of "$f")"
  done
  [ "$any" = 0 ] && printf '(no matching active entries)\n'
  return 0
}

# =========================================================================
# sweep-stale - flip past-review business_knowledge entries to stale.
# =========================================================================
cmd_sweep_stale() {
  [ -d "$ENTRIES" ] || { printf '(no memory)\n'; return 0; }
  local f any=0 eid eclass rb now
  now=$(today)
  for f in "$ENTRIES"/*.md; do
    [ -e "$f" ] || continue
    [ "$(fm_fm_get "$f" status)" = active ] || continue
    eclass=$(fm_fm_get "$f" validation_class)
    [ "$eclass" = business_knowledge ] || continue
    rb=$(fm_fm_get "$f" review_by)
    { [ -z "$rb" ] || [ "$rb" = null ]; } && continue
    # String date compare works for YYYY-MM-DD.
    if [ "$rb" \< "$now" ]; then
      eid=$(fm_fm_get "$f" id)
      fm_fm_set "$f" status stale
      any=1
      printf 'stale: %s (review_by %s < %s)\n' "$eid" "$rb" "$now"
    fi
  done
  fm_regen_index
  [ "$any" = 0 ] && printf '(nothing to sweep)\n'
  return 0
}

# =========================================================================
# retire - remove trust from ONE entry (duplicate, moved-home, or no-longer-true).
# Flips status to retired so recall and MEMORY.md drop it, records the reason
# and a retire attribution, and preserves the file for audit. No validation
# gate (retiring is a removal of trust, not a grant); acts on exactly one id.
# =========================================================================
cmd_retire() {
  local id='' reason=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:-}; shift 2 ;;
      -*) die "retire: unknown argument: $1" 2 ;;
      *)
        [ -z "$id" ] || die "retire: only one id may be given (no wildcard mass-retire)" 2
        id=$1; shift ;;
    esac
  done
  [ -n "$id" ] || die "retire: <id> required (retire acts on exactly one entry)" 2
  local file="$ENTRIES/$id.md"
  [ -f "$file" ] || die "retire: no such entry: $id" 2

  local status; status=$(fm_fm_get "$file" status)
  if [ "$status" = retired ]; then
    printf 'retire: %s is already retired (no-op)\n' "$id"
    return 0
  fi

  local identity rtext
  identity=$(fm_identity) || exit $?
  rtext=$(printf '%s' "$reason" | tr '\n\t\r' '   ')
  [ -n "$rtext" ] || rtext=null

  fm_fm_set "$file" status retired
  fm_fm_upsert "$file" retired_by "$identity"
  fm_fm_upsert "$file" retired_at "$(today)"
  fm_fm_upsert "$file" retire_reason "$rtext"
  fm_regen_index

  if [ "$rtext" = null ]; then
    printf 'retired %s\n' "$id"
  else
    printf 'retired %s (%s)\n' "$id" "$rtext"
  fi
}

# =========================================================================
main() {
  local verb=${1:-}
  [ -n "$verb" ] || die "usage: fm-memory.sh <propose|corroborate|confirm|promote|conflicts|resolve|recall|sweep-stale|retire> [options]" 2
  shift
  case "$verb" in
    propose) cmd_propose "$@" ;;
    corroborate) cmd_corroborate "$@" ;;
    confirm) cmd_confirm "$@" ;;
    promote) cmd_promote "$@" ;;
    conflicts) cmd_conflicts "$@" ;;
    resolve) cmd_resolve "$@" ;;
    recall) cmd_recall "$@" ;;
    sweep-stale) cmd_sweep_stale "$@" ;;
    retire) cmd_retire "$@" ;;
    -h|--help|help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown verb: $verb" 2 ;;
  esac
}

main "$@"
