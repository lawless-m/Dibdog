# power_bi_observed

Corpus entries harvested from real Power Query / .m source files.
Provenance is the second-highest-priority category in `LOOP.md`'s
"What to work on" list — these queries are what Power BI emits
against the production database, and they MUST parse for the
eventual ODBC driver use case.

## How they got here

Static extraction via `../../tools/harvest-pq.sh` against
`../../../MrsFlow/examples/`. The harvester:

1. Walks every `.pq` / `.m` source file under that tree.
2. Filters to files that mention `Exportmaster` (case-insensitive)
   — drops the .pq files that target DuckDB, Postgres, etc.
3. Extracts every double-quoted string starting with `SELECT`
   (case-insensitive).
4. Decodes the M-source whitespace escapes `#(lf)`, `#(cr)`,
   `#(tab)`, `#(cr,lf)` to actual whitespace bytes (matches what
   the engine sees at runtime).
5. Normalises whitespace runs to single spaces.
6. Deduplicates by normalised text.

Slice #6's initial harvest produced 31 distinct queries.

## What's NOT here

- **Dynamically-built SQL**: M expressions that build SQL with
  `& "..."` concatenation, parameter interpolation, or runtime
  variable substitution have only their first quoted fragment
  captured — the rest is invisible to static extraction. Roughly
  4 of the harvested entries are incomplete fragments for this
  reason; the engine rejects them and they sit `pending` until a
  dynamic-logging harvest catches their full form.
- **Non-DBISAM queries**: anything from .pq files targeting other
  backends (DuckDB Parquet, Postgres) is filtered out.
- **Queries that never made it into a .pq file**: e.g., ad-hoc
  reports run from Excel directly via the ODBC connection. Those
  require dynamic logging on the wire.

The dynamic harvest path is tracked as a follow-up task; the
harness already supports it in principle via mrsflow's
`Exportmaster.Query` path.

## Quality reading

Out of 31 harvested queries, the engine accepted 27 and rejected
4 at capture time. The 4 rejected are either incomplete fragments
(see above) or genuine engine-level rejections of constructs we
need to understand. They stay in the corpus as `pending` with
`engine_verdict.json` recording the rejection — useful negative
material for the grammar to match.
