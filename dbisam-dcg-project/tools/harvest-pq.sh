#!/usr/bin/env bash
# Static harvest of DBISAM SQL queries from Power Query .pq / .m files.
#
# Extraction is STRUCTURAL, not text-grep:
#
#   For each .pq / .m file:
#     For each Odbc.Query(...) call in the file:
#       If the connection-string arg matches "dsn=Exp..." (case-insens),
#         AND the SQL arg is a string literal:
#           record the SQL string for harvest.
#       Otherwise: skip the call.
#
# This is what slice #6's original file-level filter SHOULD have been.
# Earlier behaviour mistakenly pulled every "SELECT ..." string out of
# any file that merely mentioned "exportmaster" — including SQL Server
# T-SQL strings sitting inside Odbc.Query("dsn=Sage1000 CRM", ...) calls
# in the same files. See entry 0108's history for the contamination
# that triggered this rewrite.
#
# Not handled:
#   - Variable-bound SQL args: Odbc.Query("dsn=Exp...", sqlVar)
#     The variable binding isn't followed; this case is left for the
#     dynamic-logging harvester (corpus/mrsflow_log/) which captures
#     the SQL after M-level evaluation.
#   - String-concatenation args: Odbc.Query("dsn=Exp...", "A" & x & "B")
#     Same reason — only fully-evaluated SQL is honest; static text
#     extraction would mangle the call.
#
# Usage:
#   ./tools/harvest-pq.sh                # default source root
#   ./tools/harvest-pq.sh <source-root>
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -ne 1 ]]; then
  SRC="${HERE}/../../../MrsFlow/examples"
else
  SRC="$1"
fi

PROJECT="$(cd "$HERE/.." && pwd)"
OUT="$PROJECT/corpus/power_bi_observed"
START_ID=100

if [[ ! -d "$SRC" ]]; then
  echo "harvest-pq: source dir not found: $SRC" >&2
  exit 2
fi
if ! command -v perl >/dev/null; then
  echo "harvest-pq: perl required" >&2
  exit 2
fi

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "harvest-pq: scanning $SRC"

# Phase 1: walk each .pq/.m file, parse out Odbc.Query calls with
# dsn=Exp... connection strings and literal-string SQL args. Emit
# <normalised-sql>\t<source-path> per match.
#
# The walker is implemented inline in Perl — handles M string escape
# ("" embedded quote), paren balancing inside the call, and the
# DBISAM whitespace escapes (#(lf), #(cr), #(tab), #(cr,lf)).
find "$SRC" -type f \( -name '*.pq' -o -name '*.m' \) -print0 \
  | xargs -0 perl -0777 -e '
    for my $file (@ARGV) {
        open(my $fh, "<", $file) or next;
        my $text = do { local $/; <$fh> };
        close $fh;
        my $len = length($text);
        my $i = 0;
        while ($i < $len) {
            my $pos = index($text, "Odbc.Query", $i);
            last if $pos < 0;
            # Word boundary check before
            if ($pos > 0 && substr($text, $pos - 1, 1) =~ /\w/) {
                $i = $pos + 1; next;
            }
            my $j = $pos + 10;
            $j++ while $j < $len && substr($text, $j, 1) =~ /\s/;
            if ($j >= $len || substr($text, $j, 1) ne "(") {
                $i = $pos + 10; next;
            }
            $j++;
            $j++ while $j < $len && substr($text, $j, 1) =~ /\s/;
            # First arg must be a string literal — the connection string.
            if ($j >= $len || substr($text, $j, 1) ne "\"") {
                $i = $pos + 10; next;
            }
            my $cs_start = $j;
            $j++;
            while ($j < $len) {
                my $c = substr($text, $j, 1);
                if ($c eq "\"") {
                    if ($j + 1 < $len && substr($text, $j + 1, 1) eq "\"") {
                        $j += 2; next;
                    }
                    last;
                }
                $j++;
            }
            if ($j >= $len) { $i = $pos + 10; next; }
            my $cs = substr($text, $cs_start, $j - $cs_start + 1);
            $j++;  # past closing "
            # DSN check — must start with dsn=Exp (case-insensitive).
            if ($cs !~ /^"[Dd][Ss][Nn]=Exp[a-zA-Z]*"$/) {
                $i = $j; next;
            }
            # Skip ws, comma, ws, optional options record [...] + ws + comma + ws
            $j++ while $j < $len && substr($text, $j, 1) =~ /\s/;
            if ($j >= $len || substr($text, $j, 1) ne ",") {
                $i = $j; next;
            }
            $j++;
            $j++ while $j < $len && substr($text, $j, 1) =~ /\s/;
            # Allow an options record before the SQL arg
            # (Odbc.Query("dsn=Exp",[opts],"sql") form)
            if ($j < $len && substr($text, $j, 1) eq "[") {
                my $depth = 1; $j++;
                while ($j < $len && $depth > 0) {
                    my $c = substr($text, $j, 1);
                    if ($c eq "[") { $depth++ }
                    elsif ($c eq "]") { $depth-- }
                    $j++;
                }
                $j++ while $j < $len && substr($text, $j, 1) =~ /\s/;
                if ($j >= $len || substr($text, $j, 1) ne ",") {
                    $i = $j; next;
                }
                $j++;
                $j++ while $j < $len && substr($text, $j, 1) =~ /\s/;
            }
            # Second positional arg: only handle literal string here.
            if ($j >= $len || substr($text, $j, 1) ne "\"") {
                $i = $j; next;
            }
            my $sql_start = $j;
            $j++;
            while ($j < $len) {
                my $c = substr($text, $j, 1);
                if ($c eq "\"") {
                    if ($j + 1 < $len && substr($text, $j + 1, 1) eq "\"") {
                        $j += 2; next;
                    }
                    last;
                }
                $j++;
            }
            if ($j >= $len) { $i = $j; next; }
            my $sql_raw = substr($text, $sql_start + 1, $j - $sql_start - 1);
            $j++;  # past closing "
            # Decode the M-source whitespace escapes.
            $sql_raw =~ s/#\(cr,lf\)/ /g;
            $sql_raw =~ s/#\(cr\)/ /g;
            $sql_raw =~ s/#\(lf\)/ /g;
            $sql_raw =~ s/#\(tab\)/ /g;
            # Decode M `""` -> single " (M source escape).
            $sql_raw =~ s/""/"/g;
            # Normalise whitespace runs to single space and trim.
            $sql_raw =~ s/\s+/ /g;
            $sql_raw =~ s/^\s+|\s+$//g;
            next if length($sql_raw) < 10;
            print $sql_raw . "\t" . $file . "\n";
            $i = $j;
        }
    }
  ' > "$TMP/raw.tsv"

raw_count="$(wc -l <"$TMP/raw.tsv")"
echo "harvest-pq: $raw_count raw matches"

# Phase 2: dedup by SQL string, keeping first source.
sort -t$'\t' -k1,1 -u "$TMP/raw.tsv" > "$TMP/unique.tsv"
unique_count="$(wc -l <"$TMP/unique.tsv")"
echo "harvest-pq: $unique_count distinct queries after dedup"

# Phase 3: emit corpus entries (skipping any whose hash is already
# present so re-runs are idempotent).
next_id="$START_ID"
written=0
skipped=0
declare -A existing_hashes
for d in "$OUT"/*/; do
  [[ -d "$d" ]] || continue
  id="$(basename "$d")"
  hash="${id##*-pqharvest-}"
  existing_hashes[$hash]=1
done

while IFS=$'\t' read -r sql src; do
  hash="$(printf '%s' "$sql" | sha1sum | cut -c1-12)"
  if [[ -n "${existing_hashes[$hash]:-}" ]]; then
    skipped=$((skipped+1))
    continue
  fi
  # Find next free numeric prefix.
  while [[ -d "$OUT/$(printf '%04d-pqharvest-%s' "$next_id" "$hash")" ]]; do
    next_id=$((next_id+1))
  done
  id="$(printf '%04d-pqharvest-%s' "$next_id" "$hash")"
  entry="$OUT/$id"

  # Trim leading $SRC from $src to produce a stable relative source path
  # rooted at MrsFlow/.
  rel_src="${src#$SRC/}"
  # Recover full path under MrsFlow for documentation.
  pretty_src="MrsFlow/examples/$rel_src"

  mkdir -p "$entry"
  printf '%s\n' "$sql" > "$entry/query.sql"
  cat > "$entry/meta.toml" <<EOF
id = "$id"
status = "pending"
provenance = "power-bi-observed"
source = "$pretty_src"
tags = ["harvest", "static-extracted", "pq-literal", "dsn-verified"]
notes = """
Statically extracted from an Odbc.Query("dsn=Exp...", "<sql>") call
in the named .pq / .m file via tools/harvest-pq.sh. The DSN is
verified at the AST level (the call-site connection string actually
starts with "dsn=Exp"), so this entry's SQL is provably destined for
the DBISAM Exportmaster backend. Concat-arg and variable-bound SQL
arguments are not handled by static harvest — they show up in the
dynamic harvest (corpus/mrsflow_log/) instead.
"""
fixtures = []
EOF
  written=$((written+1))
  next_id=$((next_id+1))
done < "$TMP/unique.tsv"

echo "harvest-pq: wrote $written new entries, skipped $skipped already in corpus"
if [[ $written -gt 0 ]]; then
  echo "harvest-pq: run corpus/_schema/refresh-verdicts.sh to capture engine verdicts"
fi
