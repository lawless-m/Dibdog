#!/usr/bin/env bash
# Harvest DBISAM SQL queries from a mrsflow SQL log (the JSON-lines
# file produced when `MRSFLOW_SQL_LOG=<path>` is set on any mrsflow
# binary that uses the Exportmaster native client — including the
# Dibdog engine harness).
#
# Each log line is one JSON object: {"ts":"<rfc 3339>","sql":"<sql>"}.
# This script:
#   1. Reads the log via jq, pulling out the SQL string per line.
#   2. Normalises whitespace (single-spaced).
#   3. Deduplicates against itself AND against the existing corpus
#      (so a query that already lives as 0001-simple-projection
#      doesn't get re-imported as a new entry).
#   4. Writes each new entry under corpus/mrsflow_log/NNNN-<hash>/
#      with provenance=mrsflow-runtime-log and a notes block citing
#      the source log path + the timestamp of first occurrence.
#
# Usage:
#   ./tools/harvest-mrsflow-log.sh <path-to-mrsflow-log>
#
# Then run `corpus/_schema/refresh-verdicts.sh` to capture engine
# verdicts for the new entries.
set -u

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path-to-mrsflow-log>" >&2
  exit 2
fi
LOG="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
OUT="$PROJECT/corpus/mrsflow_log"
START_ID=200   # leave space below for manual + power_bi_observed

if [[ ! -f "$LOG" ]]; then
  echo "harvest-mrsflow-log: log not found: $LOG" >&2
  exit 2
fi
if ! command -v jq >/dev/null; then
  echo "harvest-mrsflow-log: jq required" >&2
  exit 2
fi

mkdir -p "$OUT"

# Step 1: build a set of SQL strings already in the corpus (any
# provenance) so we don't double-import. Normalise the existing
# SQL the same way we'll normalise log entries.
declare -A existing
while IFS= read -r -d '' qfile; do
  norm="$(tr -s '[:space:]' ' ' <"$qfile" | sed -E 's/^ //; s/ $//')"
  existing["$norm"]=1
done < <(find "$PROJECT/corpus" -mindepth 2 -name query.sql -print0)

echo "harvest-mrsflow-log: ${#existing[@]} existing corpus queries to dedup against"

# Step 2: walk the log; per line, parse JSON, normalise SQL, skip if
# already present. Emit unique survivors as tab-separated <ts>\t<sql>.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hold first-occurrence timestamp per unique normalised SQL.
jq -r '"\(.ts)\t\(.sql)"' "$LOG" \
  | while IFS=$'\t' read -r ts sql; do
      [[ -z "$sql" ]] && continue
      norm="$(printf '%s' "$sql" | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//')"
      [[ -z "$norm" ]] && continue
      printf '%s\t%s\n' "$norm" "$ts"
    done | awk -F'\t' '!seen[$1]++' > "$TMP/unique.tsv"

unique_count="$(wc -l <"$TMP/unique.tsv")"
echo "harvest-mrsflow-log: $unique_count unique queries in the log"

# Step 3: emit new corpus entries.
next_id="$START_ID"
written=0
skipped_existing=0

while IFS=$'\t' read -r sql ts; do
  if [[ -n "${existing[$sql]:-}" ]]; then
    skipped_existing=$((skipped_existing+1))
    continue
  fi
  hash="$(printf '%s' "$sql" | sha1sum | cut -c1-12)"
  id="$(printf '%04d-mrsflowlog-%s' "$next_id" "$hash")"
  entry="$OUT/$id"

  if [[ -d "$entry" ]]; then
    skipped_existing=$((skipped_existing+1))
    continue
  fi

  mkdir -p "$entry"
  printf '%s\n' "$sql" > "$entry/query.sql"
  cat > "$entry/meta.toml" <<EOF
id = "$id"
status = "pending"
provenance = "mrsflow-runtime-log"
source = "$LOG"
first_seen_at = "$ts"
tags = ["harvest", "mrsflow-runtime", "dynamic-capture"]
notes = """
Captured at runtime from a mrsflow Exportmaster.Query path with
MRSFLOW_SQL_LOG enabled. Unlike the static .pq/.m extraction
(power_bi_observed/), this is the SQL string AFTER any M-language
concatenation and parameter interpolation — i.e., what the engine
actually sees on the wire.
"""
fixtures = []
EOF
  written=$((written+1))
  next_id=$((next_id+1))
done < "$TMP/unique.tsv"

echo "harvest-mrsflow-log: wrote $written new entries, skipped $skipped_existing already in corpus"
if [[ $written -gt 0 ]]; then
  echo "harvest-mrsflow-log: run corpus/_schema/refresh-verdicts.sh to capture engine verdicts"
fi
