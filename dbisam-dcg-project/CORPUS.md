# Corpus

The corpus is the project's accumulated empirical knowledge about DBISAM SQL.
Tests are one *use* of it; it's also the divergences source, the regression
suite, the coverage data, and the documentation-by-example.

## Layout

```
corpus/
├── select/
│   ├── basic/
│   │   ├── 0001-simple-projection/
│   │   │   ├── query.sql
│   │   │   ├── meta.toml
│   │   │   ├── expected.term
│   │   │   └── engine_verdict.json
│   │   └── ...
│   ├── joins_comma/          SQL-89 comma-form, the dominant idiom
│   ├── joins_explicit/       JOIN ... ON form (mostly Power BI)
│   └── subqueries/
├── dml/
│   ├── insert_values/
│   ├── insert_select/        Central: temp table population pattern
│   ├── update/
│   └── delete/
├── ddl/
│   ├── create_table/         Bounded scope — see FOUNDATIONS.md
│   └── drop_table/
├── expressions/
│   ├── precedence/
│   └── functions/
├── rejected/
│   └── syntax_errors/
└── product_log/
    └── (entries imported from production query logs)

fixtures/
└── (schema-creation SQL run by engine harness, not part of grammar corpus)
```

The directory structure is for humans navigating the corpus. The numeric IDs
in entry names are the stable identifiers used by code, divergences docs,
issue trackers, and commit messages.

## Fixtures vs corpus

A deliberate split:

- **`corpus/`** contains SQL the grammar must parse, with expected terms.
  Every entry is a tested grammar artefact.
- **`fixtures/`** contains schema-creation SQL the engine harness runs
  during setup, to make the test databases the corpus queries run against.
  Fixture SQL is *not* run through the grammar. It exists so engine
  verdicts can be captured; it doesn't need to parse with our DCG.

This split exists because DBISAM's CREATE TABLE has a huge amount of
syntax we don't need to support in the grammar (locale, encryption, blob
block sizes, etc.) but we may still need to *use* in setting up realistic
test schemas. Fixtures get the kitchen-sink treatment from the engine
without burdening the grammar.

Corpus entries can declare schema prerequisites via metadata (see
`meta.toml` below); the engine harness ensures those fixtures are in place
before capturing verdicts.

## Entry structure

Every entry is a directory containing:

### `query.sql`

The SQL string. Plain text. Whatever encoding DBISAM accepts (probably
Latin-1 or Windows-1252 given the era — confirm and document).

### `meta.toml`

Hand-authored metadata:

```toml
id = "0001-simple-projection"
status = "meaningful"          # see "Lifecycle" below
provenance = "manual"          # see "Provenance" below
tags = ["select", "projection", "basic"]
notes = "Smallest possible SELECT; used as canary."

# Schema prerequisites — fixtures the engine harness must apply before
# capturing a verdict for this query. Names refer to entries in fixtures/.
# Omit or leave empty for queries that don't need a schema (e.g. pure
# syntax-rejection tests).
fixtures = ["customers_basic", "orders_basic"]

# Only present when status = "expected-divergent"
[divergence]
reason = "Engine accepts trailing semicolon, grammar requires absence"
reference = "DIVERGENCES.md#trailing-semicolons"

# Only present when status = "quarantined"
[quarantine]
reason = "Round-trip fails on date literal formatting"
opened_at = "2026-05-22"
tracking = "issue-47"

# Only present when provenance = "reduced-from-X"
[reduction]
from_id = "1247-product-log-complex-join"
notes = "Removed unrelated columns to isolate join behaviour."
```

### `expected.term`

The expected AST term, in pretty-printed Prolog. Canonical formatting
enforced by `corpus-format` so diffs are clean.

Absent or contains only a placeholder marker if status is `pending`.

### `engine_verdict.json`

Derived, not authored. Cached output from the engine harness:

```json
{
  "verdict": "accepted",
  "engine_version": "X.Y.Z",
  "captured_at": "2026-05-20T10:15:30Z",
  "rows_affected": null,
  "error_code": null,
  "error_message": null
}
```

For rejections:

```json
{
  "verdict": "rejected",
  "engine_version": "X.Y.Z",
  "captured_at": "2026-05-20T10:15:30Z",
  "error_code": 12345,
  "error_message": "DBISAM Engine Error #12345 Invalid SQL ..."
}
```

Stale verdicts (engine version mismatch) are refreshed automatically.

## Lifecycle

```
   added            human or automated
     │
     ▼
  pending  ─────►  scaffolded  ─────►  meaningful
     │                                       │
     │                                       ▼
     │                              expected-divergent
     │                                       │
     │                                       ▼
     └─────────────────────────────────► quarantined
```

- **`pending`**: SQL string and metadata exist; no grammar work done yet.
  No expected term. Engine verdict captured. Counts as known-but-not-covered.
- **`scaffolded`**: Grammar accepts but expected term is incomplete or
  hasn't passed all promotion checks. Visibly *not* meaningful coverage.
- **`meaningful`**: Full expected term, round-trip works, differential
  agreement with engine. The only state that counts as real coverage.
- **`expected-divergent`**: Like meaningful, but grammar and engine
  deliberately disagree, with the disagreement documented in
  `DIVERGENCES.md`. Counted separately for visibility.
- **`quarantined`**: Was meaningful, now failing for unknown reasons.
  Excluded from active suite but tracked. Prevents one bug blocking
  everything else while staying visible.

## Promotion bar

`scaffolded` → `meaningful` requires *all* of:

1. `expected.term` contains no placeholder atoms (`unimplemented`, `todo`,
   `_`, etc.). The anti-stub linter enforces this.
2. Grammar parses `query.sql` to a term equal to `expected.term`.
3. Round-trip: generating SQL from `expected.term` and re-parsing produces
   the same term. (Generated SQL doesn't need to be string-equal to original
   — whitespace, parenthesisation may differ — but the term must round-trip.)
4. Differential agreement with engine, *or* an `[divergence]` section in
   `meta.toml` referencing a documented divergence (which moves the entry
   to `expected-divergent` instead).

The harness checks all four. Manual promotion is forbidden.

## Provenance

Tagged per entry. Affects priority and triage:

- **`product-log`** — extracted from the shipped product's actual query
  stream. Highest priority; these *must* work or production breaks.
- **`power-bi-observed`** — captured by running Power BI against a test
  database. Critical because Power BI is the eventual driver consumer.
- **`docs-example`** — from DBISAM documentation. Useful but lower
  authority (docs lie).
- **`manual`** — written by hand to exercise a specific construct.
- **`reduced-from-NNNN`** — minimised version of a larger query, with
  back-reference. The original is *also* kept; both have value.
- **`fuzzer-generated`** — produced by running the DCG in generation mode
  with random seeds. Lowest priority but useful for finding over-permissive
  grammar.
- **`regression`** — added to lock down a previously-fixed bug.

## Parameter handling

Production queries from Power BI will be parameterised. Corpus entries
should reflect this: a query with `WHERE id = ?` and recorded parameter
values is one entry, not many. Literal-heavy variants get deduplicated to
their parameterised form during import.

The `expected.term` represents the parameterised query; parameter values
live in metadata if needed for execution against the engine.

## Tooling commands

The following commands form the corpus's operational surface. All are
expected to exist; details elided here, scope is what they do.

- **`corpus-add <sql>`** — assign an ID, capture engine verdict, run grammar,
  create the entry as `pending` (or `scaffolded` if grammar accepts), prompt
  for category/tags.
- **`corpus-import <file>`** — bulk import from a query log; deduplicates
  against existing entries (exact match, normalised match, structural
  match).
- **`corpus-promote <id>`** — attempt promotion from `scaffolded` to
  `meaningful`; runs the four promotion checks and reports which fail.
- **`corpus-format`** — canonicalise formatting of all `expected.term` files
  and `meta.toml` files for diff-cleanliness.
- **`corpus-validate`** — audit the entire corpus: IDs unique and match
  directory names, all required files present per status, anti-stub linter
  clean.
- **`corpus-refresh-verdicts`** — re-run engine harness on entries whose
  cached verdict is stale (engine version changed, or `--force`).
- **`corpus-find-similar <sql>`** — surface entries with similar shape to
  a candidate, for dedup during manual addition.
- **`corpus-reduce <id>`** — attempt to minimise a query while preserving
  its grammar/engine disagreement or failure mode. Creates a new entry
  with `reduced-from-NNNN` provenance.
- **`corpus-report`** — generate the coverage dashboard (see `ANTI_STUBS.md`).
- **`corpus-migrate <migration>`** — apply a systematic AST-shape change
  across all `expected.term` files when the term shape evolves.

## Coverage views

Computed from the corpus by `corpus-report`:

- **Production coverage**: of the DCG productions defined, how many have ≥N
  `meaningful` entries that exercise distinct paths through them.
- **Feature coverage**: counts of `meaningful` entries per tag, surfaced
  as a feature matrix.
- **Provenance coverage**: how much of each provenance category exists in
  the corpus, with `meaningful` percentage per category. Tells you whether
  the product-log queue is being worked.
- **Divergence inventory**: all `expected-divergent` entries grouped by
  their referenced divergence reason.

## Things to decide / verify early

Lexical questions that affect a large fraction of the corpus:

- Exact rules for identifier characters and quoting (likely double-quote
  or bracket-quote, possibly neither).
- String literal escape sequences (single quote doubling? backslash escapes?
  neither?).
- Date / time / datetime literal formats accepted.
- Number literal formats (especially BCD/money — `$123.45`? `123.45m`?).
- Comment syntax (`--` line? `/* */` block? Both? Nesting?).
- Whitespace handling at the lexical layer (where is it required vs
  optional?).
- Case-folding of keywords (always insensitive presumably, but confirm).

Structural questions worth settling early:

- **Join syntax confirmation**: comma-form is dominant (per
  `FOUNDATIONS.md`), but: does DBISAM support explicit `JOIN ... ON`
  syntax at all? Does it support `LEFT`/`RIGHT`/`FULL OUTER`? Does it
  have any old-style outer-join operator (Oracle `(+)` or similar)?
- **Temp table mechanism**: what's the exact syntax? `CREATE TEMP TABLE`?
  `CREATE TEMPORARY TABLE`? An `INTO` clause on SELECT? Something else?
- **Subquery positions**: in WHERE for sure. In FROM (derived tables)?
  In SELECT projection (scalar subqueries)? Each enables or restricts a
  whole class of query.
- **Statement terminator**: required, optional, or context-dependent? The
  docs are ambiguous (see the `CURRENT_DATE` example with a missing comma
  in CREATE TABLE that may also be a missing semicolon).

These go in `FOUNDATIONS.md` once settled, with corpus entries demonstrating
the confirmed behaviour.
