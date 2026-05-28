#!/usr/bin/env bash
# harvest-ri.sh — extract individual SQL queries from `ri-*.sql` files
# under ../corpus/raw/, then add each as a new corpus entry via
# tools/corpus-add.sh.
#
# Each ri-* file is multi-query, separated by `-- line N` marker
# comments. Format example:
#
#     -- Extracted from: <java source>
#     -- N SQL string(s)
#
#     -- line 17
#     SELECT ... ;
#
#     -- line 42
#     INSERT INTO ... ;
#
# Queries that contain Java-style `%s` placeholders (parameter slots
# from the original Java string.format calls) are SKIPPED — they're
# templates, not runnable SQL.
#
# Usage:
#   ./tools/harvest-ri.sh [--dry-run]
#
# Outputs progress + final summary (added N, skipped M, errored K).
set -u

cd "$(dirname "$0")/.."

DRY_RUN=0
if [[ ${1:-} == "--dry-run" ]]; then
  DRY_RUN=1
fi

RAW_DIR="../corpus/raw"
if [[ ! -d "$RAW_DIR" ]]; then
  echo "no $RAW_DIR — run from project root, with ../corpus/raw/ in place" >&2
  exit 1
fi

ADDED=0
SKIPPED_TEMPLATE=0
ERRORED=0

# Split a single ri-* file into one SQL per call to corpus-add.sh.
# Slugs are derived from the file basename + the source `line N`
# number so each gets a stable, unique identity.
harvest_file() {
  local file="$1"
  local base
  base="$(basename "$file" .sql)"

  # AWK splits on `-- line N` markers. State machine: accumulate SQL
  # lines into a buffer; on a new `-- line N` marker (or EOF), flush
  # the previous buffer. Header comments (`-- Extracted from`,
  # `-- N SQL string(s)`) are pre-marker and get discarded.
  awk -v base="$base" -v outdir="/tmp/harvest-ri" '
    BEGIN {
      system("rm -rf " outdir " && mkdir -p " outdir);
      curline = "";
      buf = "";
    }
    /^-- line [0-9]+/ {
      if (curline != "" && buf != "") {
        outfile = outdir "/" base "__line" curline ".sql"
        # trim trailing whitespace/newlines via printf without
        # trailing newline; let any in-SQL whitespace stay
        sub(/[ \t\n]+$/, "", buf)
        print buf > outfile
        close(outfile)
      }
      curline = $0
      sub(/^-- line /, "", curline)
      buf = ""
      next
    }
    /^--/ { next }   # skip other comment lines (header)
    /^[ \t]*$/ {
      # blank line — preserve only if we have buffered SQL
      if (buf != "") buf = buf "\n"
      next
    }
    {
      if (buf == "") buf = $0
      else buf = buf "\n" $0
    }
    END {
      if (curline != "" && buf != "") {
        outfile = outdir "/" base "__line" curline ".sql"
        sub(/[ \t\n]+$/, "", buf)
        print buf > outfile
        close(outfile)
      }
    }
  ' "$file"

  # Now process each split-out file
  for sql in /tmp/harvest-ri/${base}__line*.sql; do
    [[ -f "$sql" ]] || continue
    local slug
    slug="$(basename "$sql" .sql)"

    # Skip templated SQL (Java %s placeholders) — historically these
    # got skipped, but if you sed-replace them with `?` in the raw
    # files (DBISAM's native parameter syntax), the templates become
    # harvestable normal SQL and this branch no longer fires.
    if grep -q '%s' "$sql"; then
      echo "  SKIP    $slug (contains %s template placeholder)"
      SKIPPED_TEMPLATE=$((SKIPPED_TEMPLATE + 1))
      continue
    fi

    # Idempotency: skip if an entry with this slug was previously
    # added. Re-running the harvester is safe — duplicate slugs are
    # silently noop'd.
    if find corpus -type d -name "*${slug}" 2>/dev/null | grep -q .; then
      echo "  SKIP    $slug (already in corpus)"
      continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  WOULD ADD: $slug"
      echo "    SQL (first 80 chars): $(head -c 80 "$sql")..."
    else
      if tools/corpus-add.sh "$sql" "$slug" "product_log" >/tmp/harvest-ri-add.log 2>&1; then
        echo "  ADD     $slug"
        ADDED=$((ADDED + 1))
      else
        echo "  ERROR   $slug"
        tail -3 /tmp/harvest-ri-add.log | sed 's/^/          /'
        ERRORED=$((ERRORED + 1))
      fi
    fi
  done
}

for f in "$RAW_DIR"/ri-*.sql; do
  [[ -f "$f" ]] || continue
  echo "$(basename "$f"):"
  harvest_file "$f"
done

echo
echo "summary: added $ADDED, skipped (templates) $SKIPPED_TEMPLATE, errored $ERRORED"
