#!/usr/bin/env bash
# Railroad equivalence gate driver.
#
# Runs the three equivalence checks against the extracted EBNF:
#   1. corpus replay        (DCG vs EBNF agree on every corpus query)
#   2. DCG->EBNF curated     (every curated sentence parses under the EBNF)
#   3. over-perm negatives   (malformed strings rejected by both)
#
# Each check runs as its own short-lived Scryer process (one process over
# everything grows heap past the box's memory), and corpus replay is split
# into bounded batches. The mode is chosen by the -g goal — never stdin,
# since get_char on a pipe under -g races EOF; corpus batch paths are passed
# in a temp file.
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
GATE="$HERE/gate.pl"
BATCH="${BATCH:-25}"

if ! command -v "$SCRYER" >/dev/null 2>&1; then
  echo "gate: scryer-prolog not found on PATH" >&2
  exit 2
fi
if [[ ! -f "$RAILROAD/grammar.ebnf.pl" ]]; then
  echo "gate: grammar.ebnf.pl missing — run the extractor first" >&2
  exit 2
fi

echo "== railroad equivalence gate =="

# --- 2: curated differential ---
"$SCRYER" -g run_curated "$GATE"; curated_rc=$?
# --- 3: over-permissiveness negatives ---
"$SCRYER" -g run_negatives "$GATE"; neg_rc=$?

# --- 1: corpus replay, in bounded batches ---
paths="$(mktemp)"
{
  find "$PROJECT/corpus" -name query.sql 2>/dev/null
  find "$REPO/corpus/raw" -name '*.sql' 2>/dev/null
} | sort > "$paths"
ncorpus=$(grep -c . "$paths")

diverge=0
docs=0
divlog="$(mktemp)"
doclog="$(mktemp)"
batchfile="$(mktemp)"
batch_no=0
total_batches=$(( (ncorpus + BATCH - 1) / BATCH ))
while [[ $((batch_no * BATCH)) -lt $ncorpus ]]; do
  sed -n "$((batch_no*BATCH + 1)),$(((batch_no+1)*BATCH))p" "$paths" > "$batchfile"
  out="$("$SCRYER" -g "corpus('$batchfile')" "$GATE")"
  while IFS= read -r line; do
    case "$line" in
      DIVERGE\ *) diverge=$((diverge+1)); echo "    ${line#DIVERGE }" >> "$divlog" ;;
      DOC\ *)     docs=$((docs+1));       echo "    ${line#DOC }"     >> "$doclog" ;;
    esac
  done <<< "$out"
  batch_no=$((batch_no+1))
done

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

rm -f "$paths" "$divlog" "$doclog" "$batchfile"

# --- aggregate verdict ---
if [[ "$curated_rc" -eq 0 && "$neg_rc" -eq 0 && "$diverge" -eq 0 ]]; then
  echo "GATE: PASS — extracted EBNF is equivalent to the DCG."
  exit 0
else
  echo "GATE: FAIL — EBNF is NOT published."
  exit 1
fi
