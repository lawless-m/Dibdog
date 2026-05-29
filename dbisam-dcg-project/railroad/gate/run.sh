#!/usr/bin/env bash
# Railroad equivalence gate driver.
#
# Enumerates every corpus query (the structured project corpus plus the
# repo-root raw corpus) and pipes the paths into gate.pl, which runs the
# three equivalence checks (corpus replay, DCG->EBNF curated differential,
# over-permissiveness negatives) against the extracted EBNF.
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

if ! command -v "$SCRYER" >/dev/null 2>&1; then
  echo "gate: scryer-prolog not found on PATH" >&2
  exit 2
fi
if [[ ! -f "$RAILROAD/grammar.ebnf.pl" ]]; then
  echo "gate: grammar.ebnf.pl missing — run the extractor first" >&2
  exit 2
fi

{
  find "$PROJECT/corpus" -name query.sql 2>/dev/null
  find "$REPO/corpus/raw" -name '*.sql' 2>/dev/null
} | sort | "$SCRYER" -g main "$HERE/gate.pl"
