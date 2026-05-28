#!/usr/bin/env bash
# probe-functions.sh — probe the live DBISAM engine on rivsem04 to
# determine which functions exist and what literal-arg shapes they
# accept. Writes:
#
#   grammar/functions.pl       — valid_function/1 facts for the names
#                                the engine actually recognises.
#   grammar/function_sigs.pl   — function_arg_shape/2 facts for each
#                                accepted literal-arg shape.
#   docs/functions.md          — human catalogue with per-function
#                                status and accepted shapes.
#
# Requires the engine harness to be reachable at $HARNESS_URL
# (default http://127.0.0.1:38120).
#
# Probe strategy: for each candidate function, try a small set of
# literal-arg shapes via `SELECT <FN>(<args>) FROM CUSTOMER TOP 1`.
# Classification per probe:
#   accepted        → function exists, this shape works
#   exists          → function exists; rejected for *other* reasons
#                     (wrong-arity / wrong-type / column-not-found etc.)
#                     i.e. message doesn't say "Expected expression but
#                     instead found <FN>"
#   unknown         → rejected with "Expected expression but instead
#                     found <FN>" — parser doesn't know this name
#
# A function counts as "valid" if any probe came back `accepted` or
# `exists`. Accepted shapes go into function_arg_shape/2.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:38120}"

OUT_FN="$PROJECT/grammar/functions.pl"
OUT_SIGS="$PROJECT/grammar/function_sigs.pl"
OUT_DOCS="$PROJECT/docs/functions.md"

# Candidate function names from the docs (slice that extracted them
# earlier). Stored inline so the probe is self-contained.
CANDIDATES=(
  ABS ACOS ASIN ATAN ATAN2 AVG CEIL CEILING COALESCE CONCAT
  COS COT COUNT DAYSFROMMSECS DEGREES EXP FLOOR HOURSFROMMSECS
  IDENT_CURRENT IF IFNULL LASTAUTOINC LCASE LEFT LENGTH LIST
  LOG LOG10 LOWER LTRIM MAX MIN MINSFROMMSECS MOD MSECSFROMMSECS
  NULLIF OCCURS PI POS POSITION POWER RADIANS RAND REPEAT
  REPLACE RIGHT ROUND RTRIM RUNSUM SECSFROMMSECS SIGN SIN SQRT
  STDDEV SUBSTRING SUM TAN TEXTOCCURS TEXTSEARCH TRUNC TRUNCATE
  UCASE UPPER YEARSFROMMSECS
)

# Probe shapes: (label, arg-types, arg-text). The label goes into
# function_arg_shape/2; the arg-text goes inline into the SQL.
declare -A SHAPES=(
  [zero]=''
  [int1]='0'
  [str1]="'x'"
  [int2]='0, 0'
  [str2]="'x', 'x'"
  [int_str]="0, 'x'"
  [str_int]="'x', 0"
  [int3]='0, 0, 0'
)
declare -A SHAPE_ARG_TYPES=(
  [zero]=''
  [int1]='numeric'
  [str1]='string'
  [int2]='numeric, numeric'
  [str2]='string, string'
  [int_str]='numeric, string'
  [str_int]='string, numeric'
  [int3]='numeric, numeric, numeric'
)
SHAPE_ORDER=(zero int1 str1 int2 str2 int_str str_int int3)

if ! curl -sS --fail "$HARNESS_URL/health" >/dev/null 2>&1; then
  echo "probe-functions: harness not reachable at $HARNESS_URL" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "probe-functions: probing ${#CANDIDATES[@]} candidates × ${#SHAPE_ORDER[@]} shapes against $HARNESS_URL"

# probe(name, args_text) -> echo "verdict|message"
probe() {
  local name="$1"
  local args="$2"
  local sql="SELECT ${name}(${args}) FROM CUSTOMER TOP 1"
  local resp
  resp="$(curl -sS -X POST -H "Content-Type: application/json" \
    --data "$(jq -n --arg s "$sql" '{sql:$s}')" \
    "$HARNESS_URL/verdict")"
  local verdict
  verdict="$(jq -r '.verdict' <<<"$resp")"
  local message
  message="$(jq -r '.message // ""' <<<"$resp")"
  printf '%s|%s\n' "$verdict" "$message"
}

# Process each candidate.
for fn in "${CANDIDATES[@]}"; do
  for shape in "${SHAPE_ORDER[@]}"; do
    args="${SHAPES[$shape]}"
    result="$(probe "$fn" "$args")"
    verdict="${result%%|*}"
    message="${result#*|}"

    if [[ "$verdict" == "accepted" ]]; then
      printf '%s\t%s\taccepted\t\n' "$fn" "$shape" >> "$TMP/probes.tsv"
    elif [[ "$verdict" == "rejected" ]]; then
      # Detect "function unknown" via message pattern. The engine emits
      # "Expected expression but instead found <FN> in SELECT SQL statement"
      # when the parser doesn't recognise the function name.
      unknown_pattern="Expected expression but instead found ${fn} in SELECT SQL statement"
      if [[ "$message" == "$unknown_pattern" ]]; then
        printf '%s\t%s\tunknown\t%s\n' "$fn" "$shape" "$message" >> "$TMP/probes.tsv"
      else
        printf '%s\t%s\texists\t%s\n' "$fn" "$shape" "$message" >> "$TMP/probes.tsv"
      fi
    else
      printf '%s\t%s\terror\t%s\n' "$fn" "$shape" "$message" >> "$TMP/probes.tsv"
    fi
  done
done

echo "probe-functions: $(wc -l <"$TMP/probes.tsv") raw probe results"

# Categorise per function.
declare -A FN_STATUS    # accepted | exists | unknown
declare -A FN_ACCEPTED  # space-separated list of accepted shape labels
for fn in "${CANDIDATES[@]}"; do
  status="unknown"
  accepted_shapes=""
  while IFS=$'\t' read -r name shape verdict _message; do
    [[ "$name" == "$fn" ]] || continue
    case "$verdict" in
      accepted)
        status="accepted"
        accepted_shapes="$accepted_shapes $shape"
        ;;
      exists)
        # Promote unknown→exists, but accepted stays accepted.
        [[ "$status" != "accepted" ]] && status="exists"
        ;;
    esac
  done < "$TMP/probes.tsv"
  FN_STATUS[$fn]="$status"
  FN_ACCEPTED[$fn]="$accepted_shapes"
done

# Emit grammar/functions.pl
{
  cat <<'EOF'
:- module(functions, [valid_function/1]).

% DBISAM SQL functions verified to exist on the live engine.
% Auto-generated by tools/probe-functions.sh — do not hand-edit.
% Each `valid_function/1` fact is a function the engine recognises;
% the grammar's function-call rule must reject anything else, since
% the engine does so at parse time.

EOF
  for fn in "${CANDIDATES[@]}"; do
    case "${FN_STATUS[$fn]}" in
      accepted|exists)
        printf "valid_function('%s').\n" "$fn"
        ;;
    esac
  done
} > "$OUT_FN"

# Emit grammar/function_sigs.pl
{
  cat <<'EOF'
:- module(function_sigs, [function_arg_shape/2]).

% Accepted literal-argument shapes per function, as confirmed by live
% engine probing. Auto-generated by tools/probe-functions.sh.
%
% function_arg_shape(Name, ArgTypes) — ArgTypes is a list of arg-type
% atoms in {numeric, string} (only literal shapes were probed). A
% function with multiple accepted shapes has multiple facts.
%
% Functions with `exists` but no `accepted` shape (so the engine
% recognises the name but none of our literal probes were valid for it
% — typically aggregates that need column refs, or 0-arg functions our
% probe missed) get no fact here; the grammar's function-call rule
% should accept any arg shape for such functions until corpus entries
% force a tighter check.

EOF
  for fn in "${CANDIDATES[@]}"; do
    for shape in ${FN_ACCEPTED[$fn]}; do
      types="${SHAPE_ARG_TYPES[$shape]}"
      if [[ -z "$types" ]]; then
        printf "function_arg_shape('%s', []).\n" "$fn"
      else
        printf "function_arg_shape('%s', [%s]).\n" "$fn" "$types"
      fi
    done
  done
} > "$OUT_SIGS"

# Emit docs/functions.md
{
  cat <<'EOF'
# DBISAM functions — observed on rivsem04

Catalogue of functions probed against the live engine, generated by
`tools/probe-functions.sh`. Each row is a function name from Elevate's
public documentation; the `status` column is the empirical finding on
the actual platform we target.

`status` values:
- **accepted** — at least one of our literal-arg probes parsed cleanly.
- **exists** — parser recognises the name but all our literal probes
  were rejected for non-name reasons (wrong-arity, type mismatch,
  needs-a-column-reference, etc). Common for aggregates and 0-arg
  functions our probe shape doesn't cover.
- **unknown** — every probe rejected with "Expected expression but
  instead found <FN>"; the parser doesn't know this name on this
  platform. Excluded from `grammar/functions.pl`.

Accepted shapes use compact labels: `zero`, `int1`, `str1`, `int2`,
etc., matching the keys in `tools/probe-functions.sh`.

| Function | Status | Accepted shapes |
| -------- | ------ | --------------- |
EOF
  for fn in "${CANDIDATES[@]}"; do
    status="${FN_STATUS[$fn]}"
    shapes="${FN_ACCEPTED[$fn]:-—}"
    shapes="${shapes## }"   # trim leading space
    [[ -z "$shapes" || "$shapes" == "—" ]] && shapes="—"
    printf "| %-15s | %-9s | %s |\n" "$fn" "$status" "$shapes"
  done
} > "$OUT_DOCS"

# Summary to stdout
declare -A COUNTS=([accepted]=0 [exists]=0 [unknown]=0)
for fn in "${CANDIDATES[@]}"; do
  COUNTS[${FN_STATUS[$fn]}]=$((COUNTS[${FN_STATUS[$fn]}] + 1))
done
echo "probe-functions: accepted=${COUNTS[accepted]}  exists=${COUNTS[exists]}  unknown=${COUNTS[unknown]}"
echo "probe-functions: wrote $OUT_FN, $OUT_SIGS, $OUT_DOCS"
