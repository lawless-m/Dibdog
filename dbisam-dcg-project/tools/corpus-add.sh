#!/usr/bin/env bash
# corpus-add — add a single raw .sql file to the corpus as a new
# pending entry. Proto version of CORPUS.md's `corpus-add` tool.
#
# Usage:
#   ./tools/corpus-add.sh <path-to-raw.sql> [slug] [category]
#
# Defaults:
#   slug      = basename of input file, sans .sql extension
#   category  = product_log (matches the typical provenance of hand-
#               extracted production queries)
#
# What it does:
#   1. Compute the next free 4-digit numeric prefix in
#      corpus/<category>/.
#   2. Build an ID `<NNNN>-<slug>` and create the entry directory.
#   3. Copy the SQL into `<entry>/query.sql`.
#   4. Write `<entry>/meta.toml` with status=pending, the appropriate
#      provenance, a relative `source` pointer back at the raw file,
#      and a tags array the user can edit afterwards.
#   5. If an engine harness is reachable at $HARNESS_URL (default
#      http://127.0.0.1:38120), capture the verdict immediately;
#      otherwise advise running refresh-verdicts.sh later.
#   6. Print the new entry path and verdict outcome.
#
# What it does NOT do:
#   - Generate `expected.term`. The entry stays `pending` until
#     promoted via corpus-promote.sh after the grammar covers it.
#   - Validate the SQL dialect — the harness verdict is the truth.
#   - Mutate the raw source file. The original is untouched.
set -u

if [[ $# -lt 1 || $# -gt 3 ]]; then
  cat <<EOF >&2
usage: $0 <path-to-raw.sql> [slug] [category]
  slug      defaults to filename without .sql extension
  category  defaults to product_log
EOF
  exit 2
fi

INPUT="$1"
SLUG_DEFAULT="$(basename "$INPUT")"
SLUG_DEFAULT="${SLUG_DEFAULT%.sql}"
SLUG="${2:-$SLUG_DEFAULT}"
CATEGORY="${3:-product_log}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
CORPUS_DIR="$PROJECT/corpus/$CATEGORY"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:38120}"
ENGINE_VERSION="${ENGINE_VERSION:-dbisam-4-unknown-build}"

if [[ ! -f "$INPUT" ]]; then
  echo "corpus-add: input file not found: $INPUT" >&2
  exit 2
fi

mkdir -p "$CORPUS_DIR"

# Find next free 4-digit prefix in this category.
next_id=1
for d in "$CORPUS_DIR"/*/; do
  [[ -d "$d" ]] || continue
  base="$(basename "$d")"
  prefix="${base%%-*}"
  if [[ "$prefix" =~ ^[0-9]+$ ]]; then
    n=$((10#$prefix))
    if (( n >= next_id )); then
      next_id=$((n + 1))
    fi
  fi
done
ID="$(printf '%04d-%s' "$next_id" "$SLUG")"
ENTRY="$CORPUS_DIR/$ID"

if [[ -d "$ENTRY" ]]; then
  echo "corpus-add: entry already exists: $ENTRY" >&2
  exit 1
fi

mkdir -p "$ENTRY"
cp "$INPUT" "$ENTRY/query.sql"

case "$CATEGORY" in
  product_log) PROV="product-log" ;;
  *)           PROV="manual" ;;
esac

# Stable relative source path rooted at the parent of the project dir
# (mirrors how repterr's source path was written in slice #2).
ABS_INPUT="$(realpath "$INPUT")"
ABS_PROJECT_PARENT="$(realpath "$PROJECT/..")"
REL_SOURCE="${ABS_INPUT#$ABS_PROJECT_PARENT/}"

cat > "$ENTRY/meta.toml" <<EOF
id = "$ID"
status = "pending"
provenance = "$PROV"
source = "$REL_SOURCE"
tags = ["raw-import"]
notes = """
Added via tools/corpus-add.sh from the raw file at $REL_SOURCE.
SQL copied verbatim. Promote via tools/corpus-promote.sh once the
grammar covers the construct(s) this query uses.
"""
fixtures = []
EOF

# Try to capture engine verdict immediately if the harness is up.
verdict_status="skipped (harness not reachable at $HARNESS_URL)"
if command -v curl >/dev/null && curl -sS --fail "$HARNESS_URL/health" >/dev/null 2>&1; then
  sql="$(cat "$ENTRY/query.sql")"
  resp="$(curl -sS -X POST -H "Content-Type: application/json" \
    --data "$(jq -n --arg s "$sql" '{sql:$s}')" \
    "$HARNESS_URL/verdict")"
  verdict="$(jq -r '.verdict' <<<"$resp")"
  captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$verdict" in
    accepted)
      bytes="$(jq -r '.bytes // null' <<<"$resp")"
      jq -n \
        --arg v "$verdict" --arg ev "$ENGINE_VERSION" --arg at "$captured_at" \
        --argjson b "$bytes" '{
          verdict: $v, engine_version: $ev, captured_at: $at,
          rows_affected: null, error_code: null, error_message: null,
          harness_reqcode: null, harness_response_bytes: $b
        }' > "$ENTRY/engine_verdict.json"
      verdict_status="accepted (${bytes} bytes)"
      ;;
    rejected)
      reqcode="$(jq -r '.reqcode // ""' <<<"$resp")"
      message="$(jq -r '.message // ""' <<<"$resp")"
      table="$(jq -r '.table // ""' <<<"$resp")"
      catalog="$(jq -r '.catalog // ""' <<<"$resp")"
      code_a="$(jq -r '.code_a // null' <<<"$resp")"
      code_b="$(jq -r '.code_b // null' <<<"$resp")"
      jq -n \
        --arg v "$verdict" --arg ev "$ENGINE_VERSION" --arg at "$captured_at" \
        --arg rc "$reqcode" --arg msg "$message" --arg tab "$table" --arg cat "$catalog" \
        --argjson ca "$code_a" --argjson cb "$code_b" '{
          verdict: $v, engine_version: $ev, captured_at: $at,
          rows_affected: null, error_code: null,
          error_message: (if $msg == "" then null else $msg end),
          harness_reqcode: $rc, harness_response_bytes: null,
          harness_table: (if $tab == "" then null else $tab end),
          harness_catalog: (if $cat == "" then null else $cat end),
          harness_code_a: $ca, harness_code_b: $cb
        }' > "$ENTRY/engine_verdict.json"
      verdict_status="rejected (${reqcode}: ${message})"
      ;;
    *)
      verdict_status="$verdict — see harness for detail"
      ;;
  esac
fi

echo "corpus-add: created $ENTRY"
echo "             verdict: $verdict_status"
