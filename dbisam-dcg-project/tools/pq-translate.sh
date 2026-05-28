#!/usr/bin/env bash
# Translate a Power Query .pq / .m file from the ODBC entry path to
# mrsflow's native Exportmaster path so mrsflow can execute it on
# Linux (where the DBISAM ODBC driver doesn't exist).
#
# Substitutions performed:
#
# Odbc.Query (literal SQL):
#   Odbc.Query("DSN=Exp...", <ident>)
#     -> Exportmaster.Query("<host>", <ident>)
#   Odbc.Query("DSN=Exp...", "<string-literal>")
#     -> Exportmaster.Query("<host>", "<string-literal>")
#
# Odbc.DataSource navigation chain:
#   Odbc.DataSource("dsn=Exp...", [HierarchicalNavigation=true])
#     -> Exportmaster.Database("<host>")
#   <src>{[Name="<catalog>",Kind="Database"]}[Data]
#     -> <src>          (catalog level collapsed — Exportmaster.Database
#                        is already scoped to one catalog)
#   <src>{[Name="<table>",Kind="Table"]}[Data]
#     -> <src>{[Name="<table>"]}[Data]
#                       (drop the Kind qualifier — mrsflow's nav rows
#                        carry `ItemKind`, not `Kind`)
#
# Credentials are NOT injected — mrsflow's exportmaster_opts reads
# MRSFLOW_EM_USER / MRSFLOW_EM_PASS env vars when the M-side options
# record omits them. Set those before running mrsflow on the output.
#
# What is NOT handled (yet):
#   - Odbc.Query with string-concatenation args (& chains). The
#     regex can't bracket-match through arbitrary M expressions; such
#     calls survive unmodified and will fail at runtime.
#   - Schema-level navigation steps (Kind="Schema"). DBISAM is
#     schema-less so they shouldn't appear, but if they do the
#     translator leaves them alone.
#
# Usage:
#   ./tools/pq-translate.sh <input.pq> [<output.m>]
#
# If <output.m> is omitted, writes to stdout.
set -u

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <input.pq> [<output.m>]" >&2
  exit 2
fi
INPUT="$1"
HOST="${DIBDOG_EM_HOST:-rivsem04}"

if [[ ! -f "$INPUT" ]]; then
  echo "pq-translate: input file not found: $INPUT" >&2
  exit 2
fi

export DBLOOP_HOST="$HOST"

translate() {
  # Slurp the whole file so multi-line Odbc.Query calls (with
  # multi-line string args or & chains) get handled too. Perl's `-0777`
  # sets the record separator to undef → whole-file mode.
  #
  # M string literals use `""` to embed a literal `"` — backslash is
  # NOT an escape character. The regex `"(?:[^"]|"")*"` matches a
  # well-formed M string including embedded doubled-quotes.
  #
  # DSN= is matched case-insensitively (production .pq files use both
  # `DSN=Exportmaster` and `dsn=Exportmaster`).
  perl -0777 -pe '
    # --- Odbc.Query rewrites ---
    # First: balanced-arg form. Match Odbc.Query("[dD][sS][nN]=Exp...", <expr>)
    # where <expr> can be any M expression including parens, brackets,
    # string concatenations, and nested function calls. Done with a
    # paren-counting state walker (see below) because Perl recursive
    # regex on cross-line input is brittle here.
    1 while s{
        Odbc\.Query\s*\(\s*
        "[Dd][Ss][Nn]=Exp[a-zA-Z]*"\s*,\s*
        ([A-Za-z_]\w*)
        \s*\)
    }{Exportmaster.Query("$ENV{DBLOOP_HOST}", $1)}gx;
    # String-literal arg form, M-style escape (doubled quote = embedded quote).
    1 while s{
        Odbc\.Query\s*\(\s*
        "[Dd][Ss][Nn]=Exp[a-zA-Z]*"\s*,\s*
        ( " (?: [^"] | "" )* " )
        \s*\)
    }{Exportmaster.Query("$ENV{DBLOOP_HOST}", $1)}gx;

    # --- Odbc.DataSource navigation rewrites ---
    s{
        Odbc\.DataSource\s*\(\s*
        "[Dd][Ss][Nn]=Exp[a-zA-Z]*"\s*
        (?:,\s*\[[^\]]*\]\s*)?
        \)
    }{Exportmaster.Database("$ENV{DBLOOP_HOST}")}gx;
    s{
        ([A-Za-z_]\w*)
        \s*\{\s*\[\s*Name\s*=\s*"[^"]*"\s*,\s*Kind\s*=\s*"Database"\s*\]\s*\}
        \s*\[\s*Data\s*\]
    }{$1}gx;
    s{
        \{\s*\[\s*Name\s*=\s*"([^"]*)"\s*,\s*Kind\s*=\s*"Table"\s*\]\s*\}
        \s*\[\s*Data\s*\]
    }{{[Name="$1"]}[Data]}gx;
  ' "$INPUT" | \
  # Second pass: paren-balanced rewriter for concat / nested-call args
  # that the regex can'\''t bracket-match through. Walks character by
  # character tracking paren depth, bracket depth, and M string state
  # (with "" escape).
  perl -0777 -e '
    my $text = do { local $/; <STDIN> };
    my $host = $ENV{DBLOOP_HOST};
    my $out = "";
    my $len = length($text);
    my $i = 0;
    # Look for "Odbc.Query" prefixed by a non-word boundary.
    while ($i < $len) {
        my $pos = index($text, "Odbc.Query", $i);
        if ($pos < 0) {
            $out .= substr($text, $i);
            last;
        }
        # Check non-word boundary before the match.
        if ($pos > 0) {
            my $prev = substr($text, $pos - 1, 1);
            if ($prev =~ /\w/) {
                $out .= substr($text, $i, $pos - $i + 1);
                $i = $pos + 1;
                next;
            }
        }
        # Try to match Odbc.Query\s*\(\s*"[dD][sS][nN]=Exp..."\s*,\s*<expr>\s*\)
        my $j = $pos + 10;  # past "Odbc.Query"
        # Skip ws
        while ($j < $len && substr($text, $j, 1) =~ /\s/) { $j++ }
        # Need (
        if ($j >= $len || substr($text, $j, 1) ne "(") {
            $out .= substr($text, $i, $pos - $i + 10);
            $i = $pos + 10;
            next;
        }
        $j++;
        while ($j < $len && substr($text, $j, 1) =~ /\s/) { $j++ }
        # Need "[dD][sS][nN]=Exp..."
        if ($j >= $len || substr($text, $j, 1) ne "\"") {
            $out .= substr($text, $i, $pos - $i + 10);
            $i = $pos + 10;
            next;
        }
        my $cs_start = $j;
        $j++;
        while ($j < $len) {
            my $c = substr($text, $j, 1);
            if ($c eq "\"") {
                if ($j + 1 < $len && substr($text, $j + 1, 1) eq "\"") {
                    $j += 2; next;
                } else { last; }
            }
            $j++;
        }
        if ($j >= $len) {
            $out .= substr($text, $i, $pos - $i + 10);
            $i = $pos + 10;
            next;
        }
        my $cs = substr($text, $cs_start, $j - $cs_start + 1);
        $j++;  # past closing "
        if ($cs !~ /^"[dD][sS][nN]=Exp[a-zA-Z]*"$/) {
            $out .= substr($text, $i, $pos - $i + 10);
            $i = $pos + 10;
            next;
        }
        # Skip ws and ,
        while ($j < $len && substr($text, $j, 1) =~ /\s/) { $j++ }
        if ($j >= $len || substr($text, $j, 1) ne ",") {
            $out .= substr($text, $i, $pos - $i + 10);
            $i = $pos + 10;
            next;
        }
        $j++;
        while ($j < $len && substr($text, $j, 1) =~ /\s/) { $j++ }
        # Walk the expression arg with paren/bracket/string state.
        my $arg_start = $j;
        my $depth = 0;
        my $in_str = 0;
        while ($j < $len) {
            my $c = substr($text, $j, 1);
            if ($in_str) {
                if ($c eq "\"") {
                    if ($j + 1 < $len && substr($text, $j + 1, 1) eq "\"") {
                        $j += 2; next;
                    } else { $in_str = 0; }
                }
            } else {
                if ($c eq "\"") { $in_str = 1; }
                elsif ($c eq "(" || $c eq "[" || $c eq "{") { $depth++; }
                elsif ($c eq ")" || $c eq "]" || $c eq "}") {
                    if ($depth == 0) {
                        if ($c eq ")") { last; }
                        # unbalanced — bail
                        last;
                    }
                    $depth--;
                }
            }
            $j++;
        }
        if ($j >= $len || substr($text, $j, 1) ne ")") {
            # Couldn'\''t find balanced closer; emit verbatim.
            $out .= substr($text, $i, $pos - $i + 10);
            $i = $pos + 10;
            next;
        }
        my $arg = substr($text, $arg_start, $j - $arg_start);
        $arg =~ s/\s+$//;
        $out .= substr($text, $i, $pos - $i);
        $out .= "Exportmaster.Query(\"$host\", $arg)";
        $i = $j + 1;  # past closing )
    }
    print $out;
  '
}

if [[ $# -eq 2 ]]; then
  translate > "$2"
else
  translate
fi
