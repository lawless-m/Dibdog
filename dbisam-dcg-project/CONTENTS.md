# DBISAM DCG Project — Document Set

This bundle contains the planning documents for building a Scryer-Prolog DCG
that formally specifies the SQL dialect of a single, specific, embedded version
of DBISAM.

The target dialect is SQL-89 in idiom (comma-form FROM, no CTEs, no window
functions) plus DBISAM-specific extensions. Temp tables substitute for CTEs
and are a first-class corpus concern. See `FOUNDATIONS.md` for the full scope.

## Where to start

Read in this order:

1. **`README.md`** — what this project is, what it isn't, the deliverable.
2. **`FOUNDATIONS.md`** — settled rules that don't get re-litigated
   (case sensitivity, scope, version targeting).
3. **`ARCHITECTURE.md`** — the three-harness model and how the pieces fit.
4. **`CORPUS.md`** — the structure and lifecycle of the test corpus.
5. **`ANTI_STUBS.md`** — the structural protections against false-progress
   (read this carefully; it's the difference between a working project and a
   project that *looks* like it's working).
6. **`REFERENCES.md`** — the three sources of truth (docs, engine, disassembly)
   and how disagreements get recorded.
7. **`LOOP.md`** — how Claude Code should iterate against this project.
8. **`STATE.md`** — current built state (grammar coverage, corpus
   statistics, divergences, tooling, memory-file index). Updated
   periodically; the existing planning docs say what was intended,
   STATE.md says what's there now.

## What's not here

- No grammar code. The DCG is the deliverable, not the input.
- No SQL parser for Power Query / Power BI output. This project targets DBISAM
  SQL only. A different project (or `sqlparser-rs`) handles the input side of
  any future translator.
- No ODBC driver code. Out of scope; this project produces the dialect
  specification that a future driver would consume.

## Glossary

- **DCG** — Definite Clause Grammar, a Prolog facility for declarative
  grammars that work in both parsing and generation directions.
- **Corpus** — the accumulated set of known SQL strings with metadata,
  expected grammar behaviour, and engine verdicts.
- **Engine harness** — wrapper around the live DBISAM engine that returns
  structured accept/reject verdicts for arbitrary SQL.
- **Differential testing** — running the same SQL through grammar and engine
  and comparing outcomes.
- **Meaningful / scaffolded / pending** — corpus entry status; see
  `ANTI_STUBS.md`.
