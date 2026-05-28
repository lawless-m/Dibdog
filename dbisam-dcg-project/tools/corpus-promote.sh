#!/usr/bin/env bash
# Proto `corpus-promote` — runs the four promotion checks from
# CORPUS.md against a single entry, reports pass/fail per criterion.
# Does NOT mutate meta.toml; that's a manual edit by the human after
# all four checks come back clean.
#
# Usage:
#   ./tools/corpus-promote.sh <entry-path>
#
# Exit codes:
#   0 — all four checks passed; entry is ready for status=meaningful
#   1 — at least one check failed (entry should stay at current status)
#   2 — invocation error (missing args, missing files)
#
# Criteria per CORPUS.md "Promotion bar":
#   1. expected.term has no placeholder atoms
#   2. grammar parses query.sql to a term equal to expected.term
#   3. round-trip stable (term → generate → re-parse → same term)
#   4. engine agreement (engine_verdict.json says accepted, AND
#      grammar parses it — or both reject)
set -u

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <entry-path>" >&2
  exit 2
fi
entry="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"

for f in query.sql meta.toml engine_verdict.json; do
  if [[ ! -f "$entry/$f" ]]; then
    echo "corpus-promote: missing $entry/$f" >&2
    exit 2
  fi
done

echo "Promotion checks for $entry"
echo "---"

# ---------------- Agreed-rejection branch ----------------
# An entry without an `expected.term` is implicitly declaring "this
# SQL is unparseable by design — both grammar and engine should
# reject it." The four-criteria gate collapses to two: grammar
# rejects AND engine rejects. Used for SQL the engine itself rejects
# (e.g. ODBC `{d '...'}` escapes that Power BI emits but DBISAM
# doesn't understand on the native wire — see memory
# `dbisam-odbc-escapes-rejected.md`), and for the canonical syntax-
# error canary `0003-syntax-error-bare-from`.
if [[ ! -f "$entry/expected.term" ]]; then
  echo "no expected.term — treating as agreed-rejection candidate"

  # Grammar must reject: parse-to-term.pl exits 1 on rejection.
  if scryer-prolog -g main "$HERE/parse-to-term.pl" -- \
       "$entry/query.sql" >/dev/null 2>&1; then
    echo "criterion 1 (grammar rejects):  FAIL — grammar accepts the SQL"
    echo "  Either write expected.term (parses cleanly) or fix the grammar."
    exit 1
  fi
  echo "criterion 1 (grammar rejects):  pass"

  engine_verdict="$(jq -r '.verdict' "$entry/engine_verdict.json")"
  case "$engine_verdict" in
    rejected)
      echo "criterion 2 (engine rejects):   pass"
      ;;
    *)
      echo "criterion 2 (engine rejects):   FAIL — engine verdict is '$engine_verdict'"
      echo "  Agreed-rejection requires both sides to reject; this entry"
      echo "  belongs in the standard four-criteria path with an expected.term."
      exit 1
      ;;
  esac

  echo "---"
  echo "BOTH-REJECT AGREEMENT"
  echo "Entry is ready for status=meaningful (agreed rejection)."
  exit 0
fi

# ---------------- Criterion 1 ----------------
# Forbidden atoms per ANTI_STUBS.md §"Forbidden in expected terms".
if grep -qwE 'unimplemented|todo|tbd|stub|placeholder|not_yet_handled|raw' "$entry/expected.term"; then
  echo "criterion 1 (no placeholders): FAIL"
  grep -nwE 'unimplemented|todo|tbd|stub|placeholder|not_yet_handled|raw' "$entry/expected.term"
  exit 1
fi
echo "criterion 1 (no placeholders):  pass"

# ---------------- Criteria 2 + 3 ----------------
# Run promote-check.pl which handles parse + round-trip together.
check_out="$(scryer-prolog -g main "$HERE/promote-check.pl" -- \
  "$entry/query.sql" "$entry/expected.term" 2>&1)"
check_rc=$?
echo "$check_out" | sed 's/^/  /'

if [[ $check_rc -ne 0 ]]; then
  echo "criteria 2+3: FAIL (scryer-prolog exit=$check_rc)"
  exit 1
fi

# Don't trust exit code alone; the script output is the ground truth.
if echo "$check_out" | grep -q '^term_match: pass$'; then
  echo "criterion 2 (term match):       pass"
else
  echo "criterion 2 (term match):       FAIL"
  exit 1
fi

if echo "$check_out" | grep -q '^roundtrip_match: pass$'; then
  echo "criterion 3 (round-trip):       pass"
else
  echo "criterion 3 (round-trip):       FAIL"
  exit 1
fi

# ---------------- Criterion 4 ----------------
# Engine verdict cross-check. Grammar parsed (we know — criterion 2
# passed); engine should also accept. For deliberately-rejected
# corpus entries (provenance ~ rejected/syntax_errors), the
# direction reverses — grammar must reject AND engine must reject.
engine_verdict="$(jq -r '.verdict' "$entry/engine_verdict.json")"
case "$engine_verdict" in
  accepted)
    echo "criterion 4 (engine agreement): pass (engine: accepted)"
    ;;
  rejected)
    # If we got here, the grammar accepted (criterion 2 passed) but
    # engine rejected. That's a "grammar over-permissive" disagreement;
    # the entry should not be meaningful — it belongs in expected-divergent
    # with a documented [divergence] block, or the grammar needs fixing.
    echo "criterion 4 (engine agreement): FAIL"
    echo "  Grammar accepts (matches expected.term) but engine rejects."
    echo "  Either fix the grammar to also reject, OR record this as a"
    echo "  documented divergence per CORPUS.md and set status=expected-divergent."
    exit 1
    ;;
  error)
    echo "criterion 4 (engine agreement): FAIL"
    echo "  Engine verdict is 'error' (infrastructure failure); refresh it"
    echo "  via corpus/_schema/refresh-verdicts.sh and retry."
    exit 1
    ;;
  *)
    echo "criterion 4 (engine agreement): FAIL (unknown verdict '$engine_verdict')"
    exit 1
    ;;
esac

echo "---"
echo "ALL FOUR CRITERIA PASS"
echo "Entry is ready for status=meaningful. Update meta.toml manually,"
echo "then re-run the differential harness to verify the dashboard moves."
exit 0
