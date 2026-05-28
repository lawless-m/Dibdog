#!/usr/bin/env bash
# Capture engine verdicts for every corpus entry.
#
# Walks corpus/, finds every entry directory containing query.sql,
# POSTs the SQL to the engine harness at $HARNESS_URL (default
# http://127.0.0.1:38120), and writes engine_verdict.json next to
# the source query in the CORPUS.md-mandated shape.
#
# Stand-in for the eventual `corpus-refresh-verdicts` tool listed in
# CORPUS.md §"Tooling commands". Crude but stable enough for the
# foundation slices.
#
# Usage:
#   bash corpus/_schema/refresh-verdicts.sh                  # all entries
#   bash corpus/_schema/refresh-verdicts.sh <entry-path>...  # selected entries
#
# Requires: curl, jq. Harness must be running.
set -u

HERE="$(cd "$(dirname "$0")"/../.. && pwd)"
CORPUS="$HERE/corpus"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:38120}"
ENGINE_VERSION="${ENGINE_VERSION:-dbisam-4-unknown-build}"

# Health-check the harness before doing any work.
if ! curl -sS --fail "$HARNESS_URL/health" >/dev/null; then
  echo "refresh-verdicts: harness not reachable at $HARNESS_URL/health" >&2
  exit 2
fi

if [[ $# -gt 0 ]]; then
  ENTRIES=("$@")
else
  mapfile -d '' ENTRIES < <(find "$CORPUS" -name query.sql -print0)
  # Strip /query.sql suffix so each ENTRIES element is the entry dir.
  for i in "${!ENTRIES[@]}"; do
    ENTRIES[$i]="${ENTRIES[$i]%/query.sql}"
  done
fi

for entry in "${ENTRIES[@]}"; do
  if [[ ! -f "$entry/query.sql" ]]; then
    echo "refresh-verdicts: skip (no query.sql): $entry" >&2
    continue
  fi
  sql="$(cat "$entry/query.sql")"
  captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  resp="$(curl -sS -X POST -H "Content-Type: application/json" \
    --data "$(jq -n --arg s "$sql" '{sql:$s}')" \
    "$HARNESS_URL/verdict")"
  verdict="$(jq -r '.verdict' <<<"$resp")"
  case "$verdict" in
    accepted)
      bytes="$(jq -r '.bytes' <<<"$resp")"
      jq -n \
        --arg v "$verdict" \
        --arg ev "$ENGINE_VERSION" \
        --arg at "$captured_at" \
        --argjson b "$bytes" \
        '{
          verdict: $v,
          engine_version: $ev,
          captured_at: $at,
          rows_affected: null,
          error_code: null,
          error_message: null,
          harness_reqcode: null,
          harness_response_bytes: $b
        }' > "$entry/engine_verdict.json"
      ;;
    rejected)
      # Slice #7: the harness now returns structured rejection detail.
      # Fold reqcode → harness_reqcode, message → error_message, and
      # keep the structured table/catalog/code_a/code_b fields under a
      # `harness_*` namespace so the spec's CORPUS.md schema (verdict,
      # engine_version, captured_at, error_code, error_message,
      # rows_affected) stays the load-bearing surface.
      reqcode="$(jq -r '.reqcode // ""' <<<"$resp")"
      message="$(jq -r '.message // ""' <<<"$resp")"
      table="$(jq -r '.table // ""' <<<"$resp")"
      catalog="$(jq -r '.catalog // ""' <<<"$resp")"
      code_a="$(jq -r '.code_a // null' <<<"$resp")"
      code_b="$(jq -r '.code_b // null' <<<"$resp")"
      jq -n \
        --arg v "$verdict" \
        --arg ev "$ENGINE_VERSION" \
        --arg at "$captured_at" \
        --arg rc "$reqcode" \
        --arg msg "$message" \
        --arg tab "$table" \
        --arg cat "$catalog" \
        --argjson ca "$code_a" \
        --argjson cb "$code_b" \
        '{
          verdict: $v,
          engine_version: $ev,
          captured_at: $at,
          rows_affected: null,
          error_code: null,
          error_message: (if $msg == "" then null else $msg end),
          harness_reqcode: $rc,
          harness_response_bytes: null,
          harness_table: (if $tab == "" then null else $tab end),
          harness_catalog: (if $cat == "" then null else $cat end),
          harness_code_a: $ca,
          harness_code_b: $cb
        }' > "$entry/engine_verdict.json"
      ;;
    error)
      detail="$(jq -r '.detail' <<<"$resp")"
      jq -n \
        --arg v "$verdict" \
        --arg ev "$ENGINE_VERSION" \
        --arg at "$captured_at" \
        --arg em "$detail" \
        '{
          verdict: $v,
          engine_version: $ev,
          captured_at: $at,
          rows_affected: null,
          error_code: null,
          error_message: $em,
          harness_reqcode: null,
          harness_response_bytes: null
        }' > "$entry/engine_verdict.json"
      ;;
    *)
      echo "refresh-verdicts: unrecognised verdict $verdict for $entry: $resp" >&2
      continue
      ;;
  esac
  echo "  $entry -> $verdict"
done
