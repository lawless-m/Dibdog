#!/usr/bin/env bash
# Differential harness — composes the grammar harness against the
# cached engine verdicts and emits the project dashboard.
#
# Source-of-truth split (per ARCHITECTURE.md + CORPUS.md):
#   - Engine verdicts live on disk in each entry's `engine_verdict.json`,
#     captured separately by `corpus/_schema/refresh-verdicts.sh`. If
#     stale, refresh BEFORE running this harness.
#   - Grammar verdicts come from the live grammar harness
#     (../grammar/run.sh) which invokes Scryer-Prolog per entry.
#
# The differential layer doesn't talk to the engine — it consumes the
# cached output.
#
# Output JSON (to stdout, also persisted to last-run.json):
#   {
#     "counts": {
#       "total": N, "meaningful": N, "scaffolded": N, "pending": N,
#       "expected_divergent": N, "quarantined": N,
#       "failing": N, "unclassified_disagreements": N
#     },
#     "deltas_since_last_run": null | { "<axis>": "+N" | "-N", ... },
#     "entries": [ {id, status, path, grammar_verdict, engine_verdict, agreement}, ... ]
#   }
#
# Agreement classification per entry (grammar / engine):
#   parsed_match   / accepted  -> agreed
#   parsed_drift   / accepted  -> term_drift (a disagreement)
#   parsed         / accepted  -> agreed
#   failed         / rejected  -> agreed
#   parsed*        / rejected  -> grammar_over_permissive
#   failed         / accepted  -> grammar_bug
#   no_grammar     / *         -> no_grammar (no rule yet)
#   *              / error     -> engine_error (harness/infra)
#   *              / unknown   -> verdict_missing (refresh required)
#
# `failing` counts `meaningful` entries with grammar_bug,
#   grammar_over_permissive, OR term_drift — any state where the
#   grammar disagrees with the engine OR the recorded expected.term.
# `unclassified_disagreements` counts grammar/engine verdict
#   disagreements (not term drift) that are NOT pending/quarantined
#   AND lack a `[divergence]` block in meta.toml.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CORPUS="${1:-$HERE/../../corpus}"
GRAMMAR_HARNESS="$HERE/../grammar/run.sh"
LAST_RUN="$HERE/last-run.json"

if [[ ! -x "$GRAMMAR_HARNESS" ]]; then
  echo "differential: grammar harness missing or not executable: $GRAMMAR_HARNESS" >&2
  exit 2
fi
if [[ ! -d "$CORPUS" ]]; then
  echo "differential: corpus directory not found: $CORPUS" >&2
  exit 2
fi
if ! command -v jq >/dev/null; then
  echo "differential: jq required" >&2
  exit 2
fi

# 1. Run the grammar harness across the whole corpus.
grammar_json="$("$GRAMMAR_HARNESS" "$CORPUS")" || {
  echo "differential: grammar harness failed" >&2
  exit 1
}

# 2. For each entry, cross-reference grammar verdict with cached engine verdict.
declare -A counts=(
  [meaningful]=0 [scaffolded]=0 [pending]=0
  [expected_divergent]=0 [quarantined]=0
  [failing]=0 [unclassified_disagreements]=0
)
entries_json=()

while IFS= read -r -d '' qfile; do
  entry="$(dirname "$qfile")"
  meta="$entry/meta.toml"

  id="$(grep -E '^id[[:space:]]*=[[:space:]]*"' "$meta" 2>/dev/null \
        | head -1 | sed -E 's/^id[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
  status="$(grep -E '^status[[:space:]]*=[[:space:]]*"' "$meta" 2>/dev/null \
        | head -1 | sed -E 's/^status[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
  has_divergence=no
  if grep -qE '^\[divergence\]' "$meta" 2>/dev/null; then
    has_divergence=yes
  fi
  : "${id:=unknown}"
  : "${status:=unknown}"

  grammar_verdict="$(jq -r --arg id "$id" \
    '.entries[] | select(.id == $id) | .result' <<<"$grammar_json")"
  if [[ -z "$grammar_verdict" ]]; then
    grammar_verdict="verdict_missing"
  fi

  engine_verdict="unknown"
  if [[ -f "$entry/engine_verdict.json" ]]; then
    engine_verdict="$(jq -r '.verdict' "$entry/engine_verdict.json")"
  fi

  # Classify
  agreement="unknown"
  case "$engine_verdict" in
    error)   agreement="engine_error" ;;
    unknown) agreement="verdict_missing" ;;
    *)
      case "$grammar_verdict" in
        parsed_match)
          [[ "$engine_verdict" == "accepted" ]] && agreement="agreed" \
            || agreement="grammar_over_permissive"
          ;;
        parsed_drift)
          # Grammar still accepts but the AST shape doesn't match the
          # recorded expected.term — a regression that must trip the
          # `failing` axis on meaningful entries.
          if [[ "$engine_verdict" == "accepted" ]]; then
            agreement="term_drift"
          else
            agreement="grammar_over_permissive"
          fi
          ;;
        parsed)
          [[ "$engine_verdict" == "accepted" ]] && agreement="agreed" \
            || agreement="grammar_over_permissive"
          ;;
        failed)
          [[ "$engine_verdict" == "rejected" ]] && agreement="agreed" \
            || agreement="grammar_bug"
          ;;
        no_grammar)
          agreement="no_grammar"
          ;;
        verdict_missing)
          agreement="verdict_missing"
          ;;
        *)
          agreement="unknown"
          ;;
      esac
      ;;
  esac

  # Count by declared status.
  case "$status" in
    meaningful)         counts[meaningful]=$(( counts[meaningful] + 1 )) ;;
    scaffolded)         counts[scaffolded]=$(( counts[scaffolded] + 1 )) ;;
    pending)            counts[pending]=$(( counts[pending] + 1 )) ;;
    expected-divergent) counts[expected_divergent]=$(( counts[expected_divergent] + 1 )) ;;
    quarantined)        counts[quarantined]=$(( counts[quarantined] + 1 )) ;;
  esac

  # `failing` = meaningful entries that disagree with the engine OR
  # with their recorded expected.term (term_drift). Documented
  # divergences are NOT counted as failing.
  if [[ "$status" == "meaningful" ]] \
     && [[ "$has_divergence" != "yes" ]] \
     && [[ "$agreement" == "grammar_bug" \
        || "$agreement" == "grammar_over_permissive" \
        || "$agreement" == "term_drift" ]]; then
    counts[failing]=$(( counts[failing] + 1 ))
  fi

  # `unclassified_disagreements` = verdict-level disagreement (not
  # term drift) that is NOT in a pending/quarantined state AND lacks
  # a [divergence] block. Term drift is intentionally tracked
  # separately via the `failing` axis above — it's a different kind
  # of regression and shouldn't double-count.
  if [[ "$agreement" == "grammar_bug" || "$agreement" == "grammar_over_permissive" ]] \
     && [[ "$has_divergence" != "yes" ]] \
     && [[ "$status" != "pending" ]] \
     && [[ "$status" != "quarantined" ]]; then
    counts[unclassified_disagreements]=$(( counts[unclassified_disagreements] + 1 ))
  fi

  entries_json+=("$(jq -n \
    --arg id "$id" \
    --arg status "$status" \
    --arg path "$qfile" \
    --arg gv "$grammar_verdict" \
    --arg ev "$engine_verdict" \
    --arg a "$agreement" \
    '{id:$id, status:$status, path:$path, grammar_verdict:$gv, engine_verdict:$ev, agreement:$a}')")
done < <(find "$CORPUS" -mindepth 2 -name query.sql -print0 | sort -z)

total=$(( counts[meaningful] + counts[scaffolded] + counts[pending] \
        + counts[expected_divergent] + counts[quarantined] ))

# 3. Build counts JSON.
counts_json="$(jq -n \
  --argjson total "$total" \
  --argjson m  "${counts[meaningful]}" \
  --argjson sc "${counts[scaffolded]}" \
  --argjson p  "${counts[pending]}" \
  --argjson ed "${counts[expected_divergent]}" \
  --argjson q  "${counts[quarantined]}" \
  --argjson f  "${counts[failing]}" \
  --argjson u  "${counts[unclassified_disagreements]}" \
  '{
    total: $total,
    meaningful: $m, scaffolded: $sc, pending: $p,
    expected_divergent: $ed, quarantined: $q,
    failing: $f, unclassified_disagreements: $u
  }')"

# 4. Compute deltas if a prior run exists.
if [[ -f "$LAST_RUN" ]]; then
  deltas_json="$(jq -n \
    --argjson old "$(jq '.counts' "$LAST_RUN")" \
    --argjson new "$counts_json" \
    '
    def sign(n): if n >= 0 then "+\(n)" else "\(n)" end;
    {
      meaningful: sign($new.meaningful - $old.meaningful),
      scaffolded: sign($new.scaffolded - $old.scaffolded),
      pending: sign($new.pending - $old.pending),
      expected_divergent: sign($new.expected_divergent - $old.expected_divergent),
      quarantined: sign($new.quarantined - $old.quarantined),
      failing: sign($new.failing - $old.failing),
      unclassified_disagreements: sign($new.unclassified_disagreements - $old.unclassified_disagreements)
    }
    ')"
else
  deltas_json="null"
fi

# 5. Assemble and emit.
if [[ ${#entries_json[@]} -eq 0 ]]; then
  entries_array='[]'
else
  entries_array="$(printf '%s\n' "${entries_json[@]}" | jq -s '.')"
fi

final="$(jq -n \
  --argjson counts "$counts_json" \
  --argjson deltas "$deltas_json" \
  --argjson entries "$entries_array" \
  '{ counts: $counts, deltas_since_last_run: $deltas, entries: $entries }')"

echo "$final"

# 6. Persist for next run's delta computation.
echo "$final" > "$LAST_RUN"
