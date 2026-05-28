# DBISAM DCG

A formal, executable specification of the SQL dialect accepted by a specific
embedded version of DBISAM, written as a Definite Clause Grammar (DCG) in
Scryer-Prolog.

## What this is

The artefact is a Prolog library that:

- **Parses** DBISAM SQL strings into structured AST terms.
- **Generates** DBISAM SQL strings from AST terms (DCG bidirectionality).
- **Validates** whether a given term represents a syntactically valid query.

Together with its documentation, the project also constitutes:

- A reconciled normative specification of the dialect (more complete and more
  accurate than the original docs).
- A test corpus of real and synthetic queries with verified engine behaviour.
- A divergences record cataloguing every place where official docs, engine
  behaviour, and disassembly disagree.

## Why this exists

Downstream uses include (but are not constrained by) an ODBC driver, migration
tooling, query analysers, schema documentation, and query rewriters. The
grammar is independent of all of these and has its own intrinsic value as a
specification.

## What this isn't

- **Not version-general.** This targets exactly one DBISAM version — the one
  embedded in our shipped product. Other versions are out of scope. There is
  no "DBISAM 3.x vs 4.x" question; there is one engine, one binary, one truth.
- **Not a parser for the SQL Power Query / Power BI emits.** That is a
  separate input dialect handled elsewhere (likely `sqlparser-rs`).
- **Not the ODBC driver.** No FFI, no Windows code, no Rust. Pure Prolog plus
  test infrastructure.
- **Not a query executor.** The grammar describes syntax. Semantics are
  delegated to the engine via the engine harness.
- **Not modern SQL.** SQL-89 is the baseline idiom (see `FOUNDATIONS.md`).
  No CTEs (temp tables substitute), no window functions, no MERGE, no
  lateral joins. Comma-form FROM is primary; explicit JOIN is secondary.
- **Not a full DBISAM dialect implementation.** CREATE TABLE in particular
  is scoped down to what corpus fixtures need; most of DBISAM's elaborate
  table-creation syntax (locale, encryption, blob block size, etc.) is
  out of scope and handled as opaque SQL in `fixtures/`.

## Resources available to the project

- A running DBISAM engine of the target version (the oracle).
- A native protocol client (Rust) that can drive the engine programmatically.
- The official DBISAM documentation (which does not entirely match the
  engine's behaviour — see `REFERENCES.md`).
- Disassembly notes from reverse-engineering the engine's native protocol and
  parser behaviour.
- Example queries from the shipped product.

## Deliverable shape

```
.
├── grammar/         The DCG itself, organised by syntactic category
├── corpus/          Test corpus (see CORPUS.md)
├── fixtures/        Schema-creation SQL for engine harness (not parsed)
├── harness/         The three harnesses (see ARCHITECTURE.md)
├── docs/
│   ├── GRAMMAR.md       Human-readable BNF-style rendering
│   ├── DIVERGENCES.md   Catalogue of doc/engine/disassembly disagreements
│   ├── REFERENCES.md    Source-of-truth catalogue
│   └── QUESTIONS.md     Running list of unresolved engine-behaviour questions
└── reports/         Generated dashboards and coverage views
```

## Success criteria

The project is "done enough to use" when:

1. Every query in the shipped product's query log parses meaningfully (status
   `meaningful` per `ANTI_STUBS.md`).
2. Every query Power BI emits against the test schema parses meaningfully.
3. Round-trip (parse → term → generate → parse) is stable for all meaningful
   entries.
4. Differential agreement with the engine is ≥99% on the corpus, with
   remaining disagreements documented as expected divergences.
5. Negative tests exist for all major rejected-construct categories.

"Done forever" doesn't apply — the corpus grows; the grammar evolves with it.
