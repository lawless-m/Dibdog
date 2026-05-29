#!/usr/bin/env bash
# Railroad equivalence gate driver.
#
# Runs the three equivalence checks against the extracted EBNF:
#   1. corpus replay        (DCG vs EBNF agree on every corpus query)
#   2. DCG->EBNF curated     (every curated sentence parses under the EBNF)
#   3. over-perm negatives   (malformed strings rejected by both)
#
# The EBNF interpreter backtracks, so a single process over the whole
# corpus grows heap past the box's memory. We therefore run corpus replay
# as bounded short-lived BATCHES (memory freed each time) and the curated
# + negative self-test as one process, then aggregate the verdict here.
#
# Run the extractor first so grammar.ebnf.pl is current:
#   scryer-prolog -g main railroad/extractor.pl
#
# Requires: scryer-prolog on PATH (or $SCRYER).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RAILROAD="$(cd "$HERE/.." && pwd)"
PROJECT="$(cd "$RAILROAD/.." && pwd)"
REPO="$(cd "$PROJECT/.." && pwd)"
SCRYER="${SCRYER:-scryer-prolog}"
BATCH="${BATCH:-12}"

if ! command -v "$SCRYER" >/dev/null 2>&1; then
  echo "gate: scryer-prolog not found on PATH" >&2
  exit 2
fi
if [[ ! -f "$RAILROAD/grammar.ebnf.pl" ]]; then
  echo "gate: grammar.ebnf.pl missing — run the extractor first" >&2
  exit 2
fi

echo "== railroad equivalence gate =="

# --- 2 + 3: curated differential and negatives (one process) ---
echo SELFTEST | "$SCRYER" -g main "$HERE/gate.pl"
selftest_rc=$?

# --- 1: corpus replay, in bounded batches ---
paths="$(mktemp)"
{
  find "$PROJECT/corpus" -name query.sql 2>/dev/null
  find "$REPO/corpus/raw" -name '*.sql' 2>/dev/null
} | sort > "$paths"
ncorpus=$(wc -l < "$paths")

diverge=0
docs=0
divlog="$(mktemp)"
doclog="$(mktemp)"
while IFS= read -r batch; do
  out="$(printf '%s\n' $batch | "$SCRYER" -g main "$HERE/gate.pl")"
  while IFS= read -r line; do
    case "$line" in
      DIVERGE\ *) diverge=$((diverge+1)); echo "    ${line#DIVERGE }" >> "$divlog" ;;
      DOC\ *)     docs=$((docs+1));       echo "    ${line#DOC }"     >> "$doclog" ;;
    esac
  done <<< "$out"
done < <(xargs -n "$BATCH" <<< "$(cat "$paths")")

corpus_ok=$((ncorpus - diverge))
if [[ "$diverge" -eq 0 ]]; then
  echo "  [corpus replay      ]  ${corpus_ok}/${ncorpus} ok"
else
  echo "  [corpus replay      ]  ${corpus_ok}/${ncorpus} ok — ${diverge} FAILED:"
  cat "$divlog"
fi
if [[ "$docs" -gt 0 ]]; then
  echo "  [corpus replay      ]  ${docs} documented divergence(s) (elided semantic guards):"
  cat "$doclog"
fi

rm -f "$paths" "$divlog" "$doclog"

# --- aggregate verdict ---
if [[ "$selftest_rc" -eq 0 && "$diverge" -eq 0 ]]; then
  echo "GATE: PASS — extracted EBNF is equivalent to the DCG."
  exit 0
else
  echo "GATE: FAIL — EBNF is NOT published."
  exit 1
fi
