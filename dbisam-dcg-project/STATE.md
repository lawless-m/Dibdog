# Project state

Snapshot of what's built, what isn't, and where to find things.
This complements the planning docs (`README`, `FOUNDATIONS`,
`ARCHITECTURE`) — they describe intent; this describes current
reality.

Last updated: 2026-05-28.

---

## Corpus

```
total                  137 entries
meaningful             119
expected-divergent      18
pending                  0
failing                  0
```

Every entry the grammar's seen is classified. Pending and failing
have stayed at zero across the last 30+ slices.

Corpus material comes from four harvest sources, all exhausted:

| Source                                  | Count | Tool used                       |
| --------------------------------------- | ----- | ------------------------------- |
| `../corpus/raw/*.sql` (hand-authored)   | ~10   | manual                          |
| `../corpus/raw/ri-*.sql` (Java extracts)| 25    | `tools/harvest-ri.sh`           |
| `/tmp/mrsflow.log` (runtime captures)   | 15    | `tools/harvest-mrsflow-log.sh`  |
| `MrsFlow/examples/xlsx_pq/`             | 31    | `tools/harvest-pq.sh`           |
| Hand-written canaries                   | ~30   | manual + `tools/corpus-add.sh`  |
| Statement-type canaries (slice #74)     | 15    | manual                          |

Slice #75 confirmed no further unharvested material exists in any
known location.

---

## Grammar coverage

### Statements (15 of 18 top-level keywords have grammar rules)

| Keyword          | Status                                       |
| ---------------- | -------------------------------------------- |
| `SELECT`         | full — DISTINCT/ALL, JOIN family, WHERE, GROUP BY, HAVING, ORDER BY, TOP, UNION/UNION ALL, IN-subselect, SELECT INTO |
| `INSERT`         | full — single-row VALUES, INSERT FROM SELECT, optional column list |
| `UPDATE`         | full — multi-col SET, WHERE, qualified LHS  |
| `DELETE`         | full — FROM-required, optional WHERE         |
| `CREATE`         | INDEX only (TABLE intentionally bounded out of scope per FOUNDATIONS) |
| `DROP`           | TABLE (with optional IF EXISTS), INDEX (bare + qualified `table.idx`) |
| `ALTER`          | TABLE ADD COLUMN only (other forms not in DBISAM's narrow syntax) |
| `RENAME`         | RENAME TABLE only (single pair, no multi-rename) |
| `EMPTY`, `OPTIMIZE`, `VERIFY`, `REPAIR`, `UPGRADE` | uniform `<KEYWORD> TABLE <name>` shape |
| `EXPORT`, `IMPORT` | TABLE TO/FROM <file-identifier> (file slot is identifier, not string literal) |
| `START`          | START TRANSACTION (TRANSACTION required) |
| `COMMIT`         | bare + WORK variant |
| `ROLLBACK`       | bare + WORK variant |

The intentionally-skipped 3 of 18: **CREATE TABLE** (bounded out of
scope per FOUNDATIONS — 40+ clauses), plus the procedural
non-keywords (DECLARE, EXEC, BEGIN, etc.) that we verified are
absent (see `dbisam-no-procedural-sql` memory).

### Expressions and operators

- **Arithmetic precedence chain**: `+`, `-`, `||` (additive) /
  `*`, `/`, `MOD` (multiplicative) / unary `-` / primary.
  Standard SQL precedence, left-associative.
- **Comparison**: `=`, `<>`, `!=`, `<`, `>`, `<=`, `>=`,
  `LIKE`, `NOT LIKE`, `BETWEEN`, `NOT BETWEEN`, `IN`, `NOT IN`,
  `IS NULL`, `IS NOT NULL`.
- **Boolean composition**: `AND`, `OR`, `NOT` (prefix), parens.
- **Predicates as values**: `IF(cond, a, b)` admits comparisons in
  the cond position (slice #54).
- **Literals**: integer (`42`), decimal (`3.14`, `.5`, `5.`, `1.5e3`,
  `1.5E-3`), string (`'x'` with SQL-standard doubled-quote escape
  `''`), boolean (`TRUE`/`FALSE`), JDBC parameter (`?`).
- **CASE WHEN**: both searched (`CASE WHEN cond THEN…`) and simple
  (`CASE expr WHEN val THEN…`) forms, optional ELSE.
- **CAST**: standard `CAST(expr AS type)` and DBISAM extension
  `CAST(expr, type)`.
- **CONCAT**: comma and DBISAM-specific `WITH` separator forms.

### Identifiers

Three forms, all producing `identifier(Atom)` AST:

- bare: `name` (letter-start alnum/underscore)
- double-quoted: `"name with chars"` (any char except `"`)
- bracketed: `[name]` (same char class as bare — strict)

### Other lexical

- SQL comments: `--` line (to EOL/EOF), `/* */` block (non-nesting).
  Slice #66 — engine probed and matched.
- Optional trailing `;`.
- Whitespace-tolerant in obvious places.

---

## Function catalogue

`grammar/functions.pl` — 70 verified function names.
`grammar/function_sigs.pl` — per-function arg shapes.

The `function_call//1` rule consults `function_arg_shape/2` and
`function_variadic/1` to enforce arity at parse time. So
`CONCAT('a', 'b', 'c')` (3 args) is grammar-rejected, matching the
engine's binary CONCAT.

DBISAM-specific quirks captured in catalogue:

- `COALESCE` declared variadic
- `IFNULL` is a 3-arg ternary (NOT the standard 2-arg form)
- `SUBSTRING` admits 2-arg and 3-arg
- `LASTAUTOINC` / `IDENT_CURRENT` need a table-name string arg
- `RUNSUM` is aggregate-like
- See `dbisam-function-quirks` memory for the full picture

---

## Documented divergences

`docs/DIVERGENCES.md` catalogues 11 grammar-vs-engine divergences:

1. Table existence — schema check (over-accept)
2. Column belongs to FROM table — schema check (over-accept)
3. Type mismatch — schema check (over-accept)
4. ODBC escapes (`{d '…'}`) — both reject (agreed)
5. Subquery position fussiness — mixed (mostly both-reject, over-accept on correlation)
6. UNION asymmetry inside subqueries — over-accept
7. HAVING restrictions — over-accept on aggregation context
8. Clause ordering — over-accept (modifier_list is order-agnostic)
9. Bare `select` as first identifier in INSERT column list — over-accept (one positional parser quirk)
10. EXPORT/IMPORT file-name uses identifier syntax (not string literal) — agreed shape; grammar over-restrict on bracketed paths with slashes
11. Multi-statement parsing — grammar over-reject (engine accepts N statements; grammar wants exactly 1)

Each section explains shape, engine response, grammar response,
disposition, and rationale. Cross-linked to corpus entries that
exercise them.

---

## Engine reqcodes catalogued

`docs/reqcodes.md` documents 5 observed reqcodes:

- `0x0000` — accepted
- `0x2b02` — table not found (schema-time)
- `0x2b05` — operational rejection during DDL (ALTER, CREATE INDEX)
- `0x2c18` — operational rejection during RENAME / maintenance
- `0x2ead` — parse / syntax error

Each documented with sample SQL and the Pack-stream layout the
harness decodes.

---

## Memory files (behavioural facts the grammar can't express)

In `~/.claude/projects/-home-matt-Git-Dibdog/memory/` and indexed
in `MEMORY.md`. 16 entries:

| File                                     | What it tells you                          |
| ---------------------------------------- | ------------------------------------------ |
| `mrsflow-exportmaster-connector`         | The engine harness substrate               |
| `dbisam-official-docs-url`               | Where the published docs live              |
| `dbisam-docs-diverge-from-engine`        | Engine wins every doc disagreement         |
| `run-unattended-no-permission-pauses`    | Matt's collaboration preference            |
| `dbisam-fussy-subqueries`                | The one position subqueries work in        |
| `dbisam-odbc-escapes-rejected`           | Don't add `{d '…'}` to the grammar         |
| `dbisam-statement-vocabulary`            | The 18 top-level keywords (engine-enumerated) |
| `dbisam-join-family`                     | Which JOIN forms work / don't              |
| `dbisam-function-quirks`                 | CONCAT binary, IFNULL ternary, etc.        |
| `dbisam-null-semantics`                  | Two-valued logic (`null = null` is TRUE)   |
| `dbisam-having-restrictions`             | HAVING engine-side restrictions            |
| `dbisam-date-time-literals`              | ISO format only, TRUE/FALSE are literals   |
| `dbisam-operators-audit`                 | Bitwise none; NOT prefix; NOT LIKE         |
| `dbisam-no-window-functions`             | No OVER, no ranking, no offset             |
| `dbisam-no-procedural-sql`               | No DECLARE/PROC/VIEW/TRIGGER/FUNCTION      |
| `dbisam-aggregate-semantics`             | Standard empty/NULL + Sys__Avg__Count leak |
| `dbisam-like-patterns`                   | `%`/`_` wildcards; `*` is LITERAL          |

For folding-context questions ("can DBISAM do X?"), check the
relevant memory first.

---

## Tooling

In `tools/`:

| Tool                         | What it does                                     |
| ---------------------------- | ------------------------------------------------ |
| `parse-to-term.pl`           | parse a single SQL file → AST term               |
| `corpus-add.sh`              | add a raw SQL file as a new corpus entry         |
| `corpus-promote.sh`          | run the four promotion checks on one entry       |
| `corpus-promote-loop.sh`     | sweep all pending entries and try to promote     |
| `harvest-ri.sh`              | harvest the ri-* Java-extracted SQL files        |
| `harvest-pq.sh`              | harvest SQL from .pq/.m Power Query files        |
| `harvest-mrsflow-log.sh`     | harvest the mrsflow runtime SQL log              |
| `probe-functions.sh`         | auto-populate the function catalogue             |
| `pq-translate.sh`            | translate .pq/.m files for mrsflow execution     |
| `promote-check.pl`           | run the parse+round-trip part of promotion       |
| `fuzz-roundtrip.pl`          | 68 round-trip AST tests across all grammar features |

Engine harness at `harness/engine/` (Rust). Grammar harness at
`harness/grammar/` (Scryer driver). Differential dashboard at
`harness/differential/run.sh` with classification + delta tracking.

---

## Known over-restrictions (grammar rejects what engine accepts)

These are real fix-candidates if a corpus entry or use case
surfaces them:

1. **Multi-statement** — engine accepts `select 1; select 2;`;
   grammar wants exactly one statement per parse. Refactor cost:
   moderate (parse_statement returning a list, expected.term
   migration). No corpus entry uses it. Documented in DIVERGENCES §11.
2. **Bracketed-identifier paths in EXPORT/IMPORT** — engine accepts
   `[/tmp/file.csv]`; grammar's bracket-identifier rule restricts to
   bare-ident chars. Workaround: double-quoted identifier
   `"/tmp/file.csv"` works in grammar. Documented in DIVERGENCES §10.
3. **CREATE TABLE** — intentionally out of scope per FOUNDATIONS.
   Could be reopened with a minimal `CREATE TABLE name (col type, …)`
   form if needed; current decision is hold.

---

## How to use this as a folding contract

For folding Power Query operations to DBISAM SQL in MrsFlow:

1. **Generate the SQL** for whatever fold candidate the M operation
   produces.
2. **Run it through the grammar**:
   `scryer-prolog -g main tools/parse-to-term.pl -- /path/to/query.sql`.
3. **If it parses**, the engine will too (modulo the over-accept
   divergences — those are mostly schema/runtime, not folder
   concerns).
4. **If it rejects**, consult the divergences and memory files to
   understand whether the fold can be salvaged with a different
   shape or if it should fail back to client-side.

The function catalogue and arity enforcement let the folder
pre-validate function calls without round-tripping the whole
query. The `valid_function/1` and `function_arg_shape/2` predicates
are the queryable interface.

---

## What this isn't and won't become without scope reopen

- A CREATE TABLE schema definer (40+ clauses; bounded scope decision)
- A multi-statement parser (no corpus driver)
- A Power Query / M parser (different language, different project —
  belongs in MrsFlow)
- A SQL formatter / pretty-printer (generator emits canonical
  single-line SQL; ugly but stable)
- A query optimiser / rewriter (the grammar is the spec, not the
  rewriter)
