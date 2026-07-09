#!/usr/bin/env bash
# diag-vs-engine.sh — REPORT ONLY. For every corpus entry that both the
# grammar rejects AND the engine rejected with a parse error (0x2ead),
# print the engine's reported error position (harness_code_b) next to the
# grammar's furthest-failure position (from parse_statement_diag/2, via
# tools/parse-to-term.pl's `furthest:` line).
#
# This is a diagnostic aid, NOT a gate and NOT a regression check:
#   - The two positions use different conventions — engine code_b is a
#     1-based char position of the offending token; grammar `furthest` is
#     a 0-based char offset of the furthest token boundary any parse
#     branch reached. They will NOT match exactly, and the grammar's
#     backtracking furthest can over-report when a speculative branch
#     runs deep. Do NOT tune the grammar to match code_b.
#   - Its value is spotting entries where the two disagree wildly, which
#     can flag a genuinely confusing rejection worth a closer look.
#
# Usage:  bash tools/diag-vs-engine.sh
# Requires: scryer-prolog, jq.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
CORPUS="$PROJECT/corpus"

if ! command -v jq >/dev/null;            then echo "diag-vs-engine: jq required" >&2; exit 2; fi
if ! command -v scryer-prolog >/dev/null; then echo "diag-vs-engine: scryer-prolog required" >&2; exit 2; fi

printf '%-58s | %-13s | %-15s\n' "entry" "engine_code_b" "grammar_furthest"
printf '%s\n' "-----------------------------------------------------------+---------------+----------------"

n=0
while IFS= read -r -d '' vfile; do
  entry="$(dirname "$vfile")"
  [[ -f "$entry/query.sql" ]] || continue

  reqcode="$(jq -r '.harness_reqcode // ""' "$vfile")"
  code_b="$(jq -r '.harness_code_b // ""' "$vfile")"
  [[ "$reqcode" == "0x2ead" && -n "$code_b" && "$code_b" != "null" ]] || continue

  # Grammar must also reject (exit 1). Capture the furthest diagnostic
  # from stderr. exit 0 (grammar accepts) → skip: that's a divergence,
  # not a shared rejection, and there's no furthest position to compare.
  err="$(cd "$HERE" && scryer-prolog -g main parse-to-term.pl -- "$entry/query.sql" 2>&1 1>/dev/null)"
  rc=$?
  [[ $rc -eq 1 ]] || continue
  furthest="$(sed -n 's/^furthest: //p' <<<"$err" | head -1)"
  [[ -n "$furthest" ]] || furthest="?"

  rel="${entry#"$PROJECT"/}"
  printf '%-58s | %-13s | %-15s\n' "$rel" "$code_b" "$furthest"
  n=$((n + 1))
done < <(find "$CORPUS" -name engine_verdict.json -print0 | sort -z)

echo
echo "diag-vs-engine: $n grammar-rejected + engine-0x2ead entries compared (report only)."
