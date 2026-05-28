#!/usr/bin/env bash
# corpus-promote-loop — sweep all status=pending corpus entries and
# attempt to promote them. Extracted from the bash block that was
# being copy-pasted at the end of every grammar slice.
#
# Usage:
#   ./tools/corpus-promote-loop.sh "<reason>"           — promote parsed-pending entries
#   ./tools/corpus-promote-loop.sh --dry-run            — list candidates without mutating
#   ./tools/corpus-promote-loop.sh --include-rejected "<reason>"
#                                                       — also sweep agreed-rejection candidates
#
# The reason string is written into each promoted entry's [[history]] block,
# verbatim. Typical form: "Slice #NN — <feature>".
#
# Exit codes:
#   0 — completed (may have promoted 0 entries)
#   1 — invocation error
set -u

cd "$(dirname "$0")/.."

DRY_RUN=0
INCLUDE_REJECTED=0
REASON=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)          DRY_RUN=1 ;;
    --include-rejected) INCLUDE_REJECTED=1 ;;
    --help|-h)
      sed -n '1,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *)  REASON="$arg" ;;
  esac
done

if [[ $DRY_RUN -eq 0 && -z "$REASON" ]]; then
  echo "usage: $0 \"<reason>\" [--include-rejected]" >&2
  echo "       $0 --dry-run" >&2
  exit 1
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- find candidates ----------------------------------------------------
PARSED_PENDING=$(harness/grammar/run.sh 2>/dev/null \
  | jq -r '.entries[]
           | select(.status == "pending"
                    and (.result == "parsed" or .result == "parsed_match"))
           | .path')

REJECTED_PENDING=""
if [[ $INCLUDE_REJECTED -eq 1 ]]; then
  # Agreed-rejection candidates: pending entries the grammar rejects
  # AND the engine also rejects. These go through the no-expected.term
  # branch of corpus-promote.sh.
  REJECTED_PENDING=$(
    jq -r '.entries[]
           | select(.status == "pending"
                    and .grammar_verdict == "failed"
                    and .engine_verdict == "rejected")
           | .path' harness/differential/last-run.json
  )
fi

candidate_count=0
for p in $PARSED_PENDING $REJECTED_PENDING; do
  candidate_count=$((candidate_count + 1))
done

if [[ $candidate_count -eq 0 ]]; then
  echo "no candidates — corpus is clean"
  exit 0
fi

# ---- dry-run mode ----------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  echo "would promote $candidate_count candidate(s):"
  for qpath in $PARSED_PENDING; do
    echo "  parsed:   $(basename "$(dirname "$qpath")")"
  done
  for qpath in $REJECTED_PENDING; do
    echo "  rejected: $(basename "$(dirname "$qpath")")"
  done
  exit 0
fi

# ---- promote -----------------------------------------------------------
PROMOTED=0
HELD=0

promote_one() {
  local qpath="$1"
  local kind="$2"   # "parsed" or "rejected"
  local entry id
  entry="$(dirname "$qpath")"
  id="$(basename "$entry")"

  if [[ "$kind" == "parsed" ]]; then
    scryer-prolog -g main tools/parse-to-term.pl -- "$qpath" \
      > "$entry/expected.term" 2>/dev/null
  else
    # Agreed-rejection: explicitly remove any stale expected.term so
    # corpus-promote.sh takes the no-expected.term branch.
    rm -f "$entry/expected.term"
  fi

  if tools/corpus-promote.sh "$entry" >/tmp/corpus-promote-loop.log 2>&1; then
    sed -i 's/^status = "pending"$/status = "meaningful"/' "$entry/meta.toml"
    {
      echo
      echo "[[history]]"
      echo "at = \"$TIMESTAMP\""
      echo 'from = "pending"'
      echo 'to = "meaningful"'
      echo 'by = "claude-code"'
      printf 'reason = "%s"\n' "$REASON"
    } >> "$entry/meta.toml"
    echo "  $id → meaningful ($kind)"
    PROMOTED=$((PROMOTED + 1))
  else
    if [[ "$kind" == "parsed" ]]; then
      rm -f "$entry/expected.term"
    fi
    echo "  $id → held ($kind)"
    HELD=$((HELD + 1))
  fi
}

for qpath in $PARSED_PENDING; do
  promote_one "$qpath" parsed
done
for qpath in $REJECTED_PENDING; do
  promote_one "$qpath" rejected
done

echo
echo "promoted: $PROMOTED, held: $HELD"
