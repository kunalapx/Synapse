#!/usr/bin/env bash
# fm-secret-scan.sh - refuse content that carries a plaintext secret.
#
# A small, reusable guard: it scans text for common secret shapes and exits
# non-zero the moment one matches, so a write path can refuse BEFORE persisting
# anything. It never redacts and never rewrites - detection only - so the caller
# decides what to do (fm-memory.sh's propose refuses outright).
#
# It lives in its own script, not buried inside a single caller, so any future
# write path (a proposer, an audit-log sink, an export) can call the identical
# check. Today only bin/fm-memory.sh propose wires it up; wiring the others is
# deliberately out of scope.
#
# Usage:
#   fm-secret-scan.sh --file <path>     scan the file's contents
#   fm-secret-scan.sh < <path>          scan stdin
#   fm-secret-scan.sh --text "<text>"   scan a literal string
#
# Exit status:
#   0  clean - no secret shape matched
#   2  a secret shape matched (the matched kind is printed to stderr)
#   1  usage error
#
# Matched shapes (intentionally broad, favouring false-positive refusal over a
# leaked secret): AWS access key ids, PEM private-key headers, bearer tokens,
# GitHub/Slack token prefixes, and password=/token=/secret=/api_key= bound to a
# long high-entropy-looking value.
set -u

MODE=
INPUT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file) MODE='file'; INPUT=${2:-}; shift 2 ;;
    --text) MODE='text'; INPUT=${2:-}; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'fm-secret-scan.sh: unknown argument: %s\n' "$1" >&2
      exit 1 ;;
  esac
done

# Load the content to scan into a single variable.
content=
case "$MODE" in
  file)
    [ -n "$INPUT" ] && [ -f "$INPUT" ] || { printf 'fm-secret-scan.sh: no such file: %s\n' "$INPUT" >&2; exit 1; }
    content=$(cat "$INPUT") ;;
  text)
    content=$INPUT ;;
  *)
    # No mode given: read stdin.
    content=$(cat) ;;
esac

# Each entry is "kind|extended-regex". grep -E is always available, so the scan
# needs no jq/python. Patterns are deliberately permissive on the value side.
patterns='
aws-access-key-id|(AKIA|ASIA|AIDA|AGPA|AROA)[0-9A-Z]{16}
pem-private-key|-----BEGIN( [A-Z0-9]+)* PRIVATE KEY-----
github-token|(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}
slack-token|xox[baprs]-[A-Za-z0-9-]{10,}
bearer-token|[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}
kv-bound-secret|(password|passwd|pwd|token|secret|api[_-]?key|access[_-]?key|private[_-]?key)s?[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9._+/=~-]{16,}
'

matched=
while IFS='|' read -r kind regex; do
  [ -n "$kind" ] || continue
  if printf '%s' "$content" | grep -Eiq -- "$regex"; then
    matched=$kind
    break
  fi
done <<EOF
$patterns
EOF

if [ -n "$matched" ]; then
  printf 'fm-secret-scan.sh: refused - content matches secret shape: %s\n' "$matched" >&2
  exit 2
fi

exit 0
