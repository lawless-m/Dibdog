#!/usr/bin/env bash
# Grammar harness driver — single-Scryer-process variant.
#
# Walks the corpus, builds the entry list, pipes every path through a
# SINGLE long-running scryer-prolog instance over stdin, reads
# results back over stdout in the same order. Aggregates into a JSON
# report.
#
# This is the shell side of the harness described in
# ARCHITECTURE.md §"Grammar harness". It deliberately does NO grammar
# work itself — its job is enumeration, invocation, and aggregation.
# The actual parse attempt lives in runner.pl.
#
# Output JSON shape:
#   {
#     "summary": {
#       "total": N,
#       "parsed": N, "parsed_match": N, "parsed_drift": N,
#       "failed": N, "no_grammar": N, "io_error": N, "error": N
#     },
#     "entries": [
#       {"id": "...", "status": "...", "path": "...", "result": "..."}
#     ]
#   }
#
# Result semantics:
#   parsed         — grammar accepted; no expected.term to match against
#   parsed_match   — grammar accepted AND parsed term == expected.term
#   parsed_drift   — grammar accepted BUT parsed term != expected.term
#   failed         — grammar rejected
#   no_grammar     — predicate undefined
#   io_error       — file read error
#   error          — other
#
# Usage:
#   ./run.sh                  # walk default corpus dir
#   ./run.sh path/to/corpus   # explicit corpus root
#
# Requires: scryer-prolog (on PATH), jq.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CORPUS="${1:-$HERE/../../corpus}"
RUNNER="$HERE/runner.pl"
SCRYER="${SCRYER:-scryer-prolog}"

if ! command -v "$SCRYER" >/dev/null; then
  echo "grammar harness: scryer-prolog not found on PATH" >&2
  exit 2
fi
if [[ ! -f "$RUNNER" ]]; then
  echo "grammar harness: runner.pl missing at $RUNNER" >&2
  exit 2
fi

# Phase 1: enumerate entries. Capture (id, status, path) into parallel
# arrays so the FIFO ordering aligns with the Scryer pipeline.
declare -a ids statuses paths
while IFS= read -r -d '' qfile; do
  entry="$(dirname "$qfile")"
  meta="$entry/meta.toml"
  id="$(grep -E '^id[[:space:]]*=[[:space:]]*"' "$meta" 2>/dev/null \
        | head -1 | sed -E 's/^id[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
  status="$(grep -E '^status[[:space:]]*=[[:space:]]*"' "$meta" 2>/dev/null \
        | head -1 | sed -E 's/^status[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
  : "${id:=unknown}"
  : "${status:=unknown}"
  ids+=("$id")
  statuses+=("$status")
  paths+=("$qfile")
done < <(find "$CORPUS" -mindepth 2 -name query.sql -print0 | sort -z)

# Phase 2: pipe every path through one Scryer instance.
# Stdin gets one path per line, then EOF (closed by `printf` finishing).
# Stdout returns one result atom per line, in input order.
if [[ ${#paths[@]} -eq 0 ]]; then
  results_raw=""
else
  results_raw="$(printf '%s\n' "${paths[@]}" | "$SCRYER" -g main "$RUNNER" 2>/dev/null)"
fi

declare -a results
while IFS= read -r line; do
  results+=("$line")
done <<< "$results_raw"

# Phase 3: pair, classify, count, emit.
declare -A counts=(
  [parsed]=0 [parsed_match]=0 [parsed_drift]=0
  [failed]=0 [no_grammar]=0
  [io_error]=0 [error]=0
)
entries_json=()

for i in "${!paths[@]}"; do
  raw="${results[i]:-}"
  case "$raw" in
    parsed|parsed_match|parsed_drift|failed|no_grammar|io_error)
      result="$raw"
      ;;
    error\(*\))
      result="error"
      ;;
    *)
      # Empty / unrecognised — count as error so it surfaces.
      result="error"
      ;;
  esac
  counts[$result]=$(( ${counts[$result]:-0} + 1 ))
  entries_json+=("$(jq -n \
    --arg id "${ids[i]}" \
    --arg s "${statuses[i]}" \
    --arg p "${paths[i]}" \
    --arg r "$result" \
    --arg raw "$raw" \
    '{id:$id, status:$s, path:$p, result:$r, raw:$raw}')")
done

total=$(( counts[parsed] + counts[parsed_match] + counts[parsed_drift] \
       + counts[failed] + counts[no_grammar] \
       + counts[io_error] + counts[error] ))

if [[ ${#entries_json[@]} -eq 0 ]]; then
  entries_array='[]'
else
  entries_array="$(printf '%s\n' "${entries_json[@]}" | jq -s '.')"
fi

jq -n \
  --argjson total "$total" \
  --argjson parsed "${counts[parsed]}" \
  --argjson parsed_match "${counts[parsed_match]}" \
  --argjson parsed_drift "${counts[parsed_drift]}" \
  --argjson failed "${counts[failed]}" \
  --argjson no_grammar "${counts[no_grammar]}" \
  --argjson io_error "${counts[io_error]}" \
  --argjson error "${counts[error]}" \
  --argjson entries "$entries_array" \
  '{
    summary: {
      total: $total,
      parsed: $parsed,
      parsed_match: $parsed_match,
      parsed_drift: $parsed_drift,
      failed: $failed,
      no_grammar: $no_grammar,
      io_error: $io_error,
      error: $error
    },
    entries: $entries
  }'
