# Foundations

Settled rules. These are not to be re-litigated during development. If a
situation seems to require breaking one of them, that's a signal to surface
the case for review, not to quietly deviate.

## Target

- **One DBISAM version**, embedded in the shipped product. The actual binary
  is the canonical reference. When this document says "the engine", it means
  that specific binary.
- **One language**: the SQL accepted by that engine. Not DBISAM SQL "in
  general". Not what the docs describe. What this binary parses.

## Identifier handling

- **Table and column names are case-insensitive** for matching.
- **Identifiers are normalised in the AST to lowercase.** So `Customers`,
  `CUSTOMERS`, and `customers` all produce the same AST term containing
  `customers`.
- **String literals are case-sensitive** and preserved verbatim in the AST.
- Quoted identifiers (if DBISAM supports them in any form) follow the same
  normalisation rule unless empirical testing reveals otherwise. If it does,
  that's a divergence to be documented.

## Source of truth ordering

When the three sources disagree:

1. **The engine wins.** It's the actual binary your customers run against.
2. **The disassembly clarifies.** When engine behaviour is ambiguous, the
   parser code is the explanation.
3. **The docs are evidence**, not authority. Useful as a starting point and
   for understanding intent, but not authoritative.

Every disagreement is recorded in `DIVERGENCES.md`, not silently resolved.

## Idiom baseline

**The project's baseline assumption is SQL-89.** Most query authors in the
target org learned SQL in that era and write in that idiom. This shapes
several decisions:

- **Comma-form `FROM` is primary, not legacy.** `FROM a, b WHERE a.z = b.z`
  is the dominant join idiom in the product's queries. Explicit
  `JOIN ... ON ...` is also supported (it's what Power BI emits) but is the
  secondary case.
- **No CTEs.** Temp tables substitute (see below). The grammar does not need
  to handle `WITH ... AS (...)` constructions.
- **No window functions.** No `OVER (...)`, no `PARTITION BY`, no
  `ROW_NUMBER()` etc.
- **No lateral joins, no `MERGE`, no modern SQL conveniences.**

Anything more modern than SQL-89 only enters scope if Power BI emits it
against the target schema and we're forced to handle it. Default assumption:
no.

## Scope (in)

- **`SELECT`** with: comma-form FROM, explicit JOINs (`INNER`, `LEFT`,
  possibly `RIGHT` — confirm from corpus), `WHERE`, `GROUP BY`, `HAVING`,
  `ORDER BY`, subqueries (at least in WHERE; possibly in FROM/SELECT —
  confirm from corpus), aggregates, `LIMIT`/`TOP` or whatever DBISAM uses.
- **`INSERT`** in two forms: `INSERT ... VALUES (...)` and
  `INSERT ... SELECT ...` (the latter is central — see "Temp tables" below).
- **`UPDATE`** and **`DELETE`**.
- **Expressions**: all operators, all functions DBISAM ships with, all
  literal types including DBISAM-specific date/time/blob forms.
- **Parameterised queries** (`?` placeholders).
- **Temp tables and DROP**: see below.
- **CREATE TABLE**: scoped down — see below.

## Temp tables as a first-class idiom

The product uses temp tables in place of CTEs. The typical pattern is:

```
-- create the temp table (form to be confirmed empirically)
INSERT INTO temp_x (a, b, c)
  SELECT a, b, leaf.c
  FROM bigtable, leaf
  WHERE bigtable.k = leaf.k
    AND a IS NOT NULL
    AND c IS NOT NULL;

SELECT ... FROM temp_x WHERE ...;

DROP TABLE temp_x;
```

Implications:

- **`INSERT ... SELECT ...` with a column list is core grammar**, not an
  optional extra. It composes with all the SELECT machinery.
- **The grammar doesn't distinguish temp from permanent tables.** A temp
  table reference is just an identifier. Temporariness is a schema concern,
  not a syntactic one, *unless* DBISAM has a syntactic marker we discover
  empirically.
- **`DROP TABLE [IF EXISTS]` is in scope** in its minimal form.
- **Multi-statement sequences** are handled at the corpus metadata level
  (fixture prerequisites), not by the grammar. Each statement parses
  independently.

## CREATE TABLE scope

CREATE TABLE in DBISAM is enormous (locale, encryption, blob block size,
index page size, user-defined versions, full-text indexes, COMPRESS levels,
DESCRIPTION, MIN/MAX, CHARCASE, etc.). **Most of that is out of scope.**

CREATE TABLE is in scope only to the extent that:

1. The corpus's test fixture schemas need it.
2. The product or Power BI actually emits it (almost certainly: neither
   does, at runtime).
3. Temp-table creation in the product idiom needs it.

Concretely, the grammar handles: column definitions with types and sizes,
`NULLABLE` / `NOT NULL`, `DEFAULT`, `PRIMARY KEY` clause. Possibly basic
secondary indexes if fixtures need them.

Out of scope unless forced in: `DESCRIPTION`, `MIN`/`MAX`, `CHARCASE`,
`COMPRESS`, `LOCALE`, `ENCRYPTED WITH`, `USER MAJOR/MINOR VERSION`,
`INDEX PAGE SIZE`, `BLOB BLOCK SIZE`, `LAST AUTOINC`, `TEXT INDEX` and its
attendants, `NOKEYSTATS`, `IF NOT EXISTS`.

Schema-creation SQL that uses out-of-scope features goes in `fixtures/` as
opaque SQL the engine harness runs without parsing, not in the corpus.

## ALTER, CREATE INDEX, other DDL

Out of scope by default. In scope only if the product or Power BI emits
them, which is unlikely.

## Scope (out)

- DBISAM script/batch language, if any, beyond what's embedded in SQL.
- Procedural extensions, stored procedures.
- CTEs, window functions, lateral joins, MERGE, modern SQL features
  generally.
- CREATE TABLE decoration beyond the column/PK basics (see above).
- ALTER TABLE, CREATE INDEX, etc. unless forced in.
- Anything not exercised by the shipped product, by Power BI against the
  target schema, or required for corpus fixtures.

If something currently out of scope turns out to be needed, it gets moved in
explicitly via a documented decision, not crept in via grammar rules.

## AST principles

- Terms are **structured**, not opaque. No `unimplemented`, `todo`, or `raw`
  atoms in the AST. If a construct isn't yet handled, the grammar fails on it.
  See `ANTI_STUBS.md`.
- Terms are **uniform**: missing optional clauses use explicit markers
  (`none`, `[]`) rather than absence. Pattern matching should be predictable.
- Terms **preserve enough source information** to round-trip: literal values
  verbatim, identifier normalisation as above, operator precedence reflected
  in tree shape (not relying on a precedence table at generation time).
- Terms **do not preserve comments or whitespace** in v1. If a pretty-printer
  variant is needed later, it gets a separate annotated term form.
- **Comma-form FROM and explicit JOIN are preserved distinctly in the AST.**
  They are semantically equivalent (post-optimisation) but syntactically
  distinct, and the AST does not normalise between them. The grammar
  represents what was written. Downstream consumers wanting a uniform
  representation apply their own normalisation pass.
- **WHERE-clause predicates are not classified as join-vs-filter.** In
  comma-form joins, the WHERE clause contains a mix of join conditions and
  row filters indistinguishable to the parser. Classification is a semantic
  concern requiring schema knowledge and is left to downstream consumers.

## Versioning of the grammar itself

The grammar is the spec. When the engine doesn't change (and it won't —
shipped product, frozen version), the grammar only changes to:

- Cover constructs not yet covered.
- Fix bugs (cases where grammar and engine disagreed and engine was right).
- Improve term shape (with corresponding corpus migration).

Term shape changes are breaking and must be coordinated across the corpus.
A `corpus-migrate` tool should exist for systematic AST shape evolution.
