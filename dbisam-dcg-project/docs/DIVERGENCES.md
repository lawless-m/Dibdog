# DBISAM grammar-vs-engine divergences

The DCG is **schema-agnostic** and **single-pass syntactic**. The engine
is schema-aware, type-aware, and applies several semantic checks at
parse time. Where they disagree, this file is the canonical index.

Each divergence states:

- **Shape**: a concrete SQL example that triggers it.
- **Engine**: what DBISAM does on rivsem04 (reqcode + message).
- **Grammar**: what the DCG does.
- **Disposition**: `over-accept` (grammar accepts; engine rejects),
  `over-reject` (grammar rejects; engine accepts — would be a bug),
  or `both-reject` (agreed rejection, documented for clarity).
- **Why**: the design reason it's where it is.

Most divergences land on `over-accept` — the grammar deliberately
leaves schema, type, aggregation, and clause-order checks to the
engine. Pointer to the corpus entry or memory file that owns each one.

---

## 1. Table existence (`FROM <name>` where `<name>` isn't in the catalog)

- **Shape**: `select * from no_such_table`
- **Engine**: rejects, `reqcode = 0x2b02`, "table not found"
- **Grammar**: accepts
- **Disposition**: over-accept
- **Why**: every FROM-clause table reference is an opaque name to the
  DCG. Catalog state is an engine concern.
- **Canonical entry**: `corpus/mrsflow_log/0201-mrsflowlog-22c841dbd6cf/`
- **See also**: `docs/reqcodes.md#0x2b02-table-not-found`

## 2. Column belongs to FROM table

- **Shape**: `select code, sum(SAVAL) from analysis group by code` —
  `analysis` exists but has no `code` column
- **Engine**: rejects, `reqcode = 0x2ead`, "Expected column name but
  instead found code in SELECT SQL statement"
- **Grammar**: accepts
- **Disposition**: over-accept
- **Why**: DBISAM validates `column ∈ table.columns` eagerly at parse
  time and reuses the 0x2ead parse-error channel for it. The wording
  is misleading — it's a schema check, not a true syntax error. The
  DCG does not (and is not designed to) track column-belongs-to-table.
- **Keyword-named columns**: the check is keyword-agnostic. `select
  group from product` is accepted because `product` has a `group`
  column (verified on rivsem04); `select group from CUSTOMER` rejects
  with the same schema message because `CUSTOMER` doesn't.
  Bracketed/quoted variants (`[group]`, `"group"`) and qualified
  forms (`product.group`) all accept too. So the rejection of e.g.
  `select where from CUSTOMER` is the column-not-on-table check, not
  a reserved-word check.
- **Canonical entries**:
  - `corpus/mrsflow_log/0205-mrsflowlog-2dbe086603d2/` (bare ident)
  - `corpus/rejected/syntax_errors/0016-keyword-as-bare-ident/`
    (ident that happens to be a SQL keyword — same check)
- **See also**: `docs/reqcodes.md#0x2ead-parse-syntax-error`

## 3. Type mismatch (e.g. `abs('aaa')`)

- **Shape**: `select abs('aaa') from CUSTOMER`
- **Engine**: rejects, parse-time type check
- **Grammar**: accepts — function arg shape allows any value expression
- **Disposition**: over-accept
- **Why**: type inference is an engine concern. The function catalogue
  (`grammar/function_sigs.pl`) tracks arg counts but not types.

## 4. ODBC escapes (`{d '…'}`, `{ts '…'}`, `{fn …}`)

- **Shape**: `select * from ORDERH where OHINVDATE >= {d '2024-01-01'}`
- **Engine**: rejects, `reqcode = 0x2ead`, "Expected expression but
  instead found {"
- **Grammar**: rejects (no rule consumes `{`)
- **Disposition**: both-reject (agreed)
- **Why**: ODBC escape syntax is part of the ODBC SQL standard, not
  DBISAM. Power BI emits them; the mrsflow Exportmaster connector is
  the native DBISAM wire protocol with no translation, so the escapes
  reach the engine and are rejected. **Do not add ODBC syntax to the
  grammar** — it would break agreement.
- **Canonical entries**: `corpus/power_bi_observed/0100/`, `0101/`,
  `0109/`, `0113/` (all promoted via agreed-rejection path)
- **See also**: memory `dbisam-odbc-escapes-rejected.md`

## 5. Subqueries — accepted in exactly one position

- **Shape (accepted)**: `where col IN (select col from t)`,
  `where col NOT IN (select col from t)`
- **Shape (rejected)**: `from (SELECT …) sub` (derived table),
  `where EXISTS (SELECT …)`, `where col > (SELECT …)` (scalar),
  correlated subqueries, row-tuple IN (`(a,b) IN (…)`)
- **Engine**: each rejected shape produces a different message
- **Grammar**: accepts the canonical `IN (subselect)` form. Other
  positions: grammar rejects them too (no rule admits the shape).
  Correlation specifically: grammar can't track outer aliases and so
  accepts correlated inner SELECTs unconditionally; the engine
  catches them at parse time.
- **Disposition**: mixed — mostly both-reject (most disallowed
  positions), over-accept on correlation
- **Why**: DBISAM is unusually fussy here; the grammar matches the
  fussiness everywhere it's structurally possible, and defers
  correlation to the engine because it'd require alias-scope tracking
  the DCG deliberately doesn't have.
- **See also**: memory `dbisam-fussy-subqueries.md`

## 6. UNION asymmetry inside subqueries

- **Shape (accepted)**: `WHERE col IN (SELECT … UNION ALL SELECT …)`
- **Shape (rejected)**: `WHERE col IN (SELECT … UNION SELECT …)` (bare
  UNION rejected inside subquery)
- **Engine**: bare UNION rejected with "Expected column name but
  instead found code"
- **Grammar**: accepts both forms (the inner subselect uses
  `select_chain//1` which admits the full UNION tree)
- **Disposition**: over-accept (on bare UNION inside subquery)
- **Why**: same as correlation — the grammar doesn't track whether
  a SELECT is currently being parsed in an IN-list context, so it
  can't selectively forbid UNION there. Engine catches it.
- **See also**: memory `dbisam-fussy-subqueries.md`

## 7. HAVING restrictions

- **Shape (rejected by engine)**:
  - `select sum(price) from product having sum(price) > 100` — no GROUP BY
  - `select code from product group by code having sum(price) > 100`
    — `sum(price)` not in source columns
  - `select code, sum(price) from product group by code having sum(price) in (SELECT …)`
    — subquery in HAVING
- **Engine**: distinct error per case (missing GROUP BY / not in source
  columns / "Invalid expression select found")
- **Grammar**: accepts all of these — HAVING uses generic
  `predicate_or` which includes the IN-subquery rule, and the
  modifier list doesn't enforce "GROUP BY required before HAVING"
- **Disposition**: over-accept
- **Why**: HAVING semantics involve aggregation context and source-
  column resolution — both schema-level concerns outside the DCG.
- **See also**: memory `dbisam-having-restrictions.md`

## 8. Clause ordering

- **Standard DBISAM order**: WHERE → GROUP BY → HAVING → ORDER BY → TOP
- **Shape (rejected by engine)**: any out-of-order arrangement, e.g.
  `select … group by code order by code having sum(price) > 100`
- **Engine**: rejects with "Expected end of statement but instead
  found <keyword>"
- **Grammar**: accepts any order — `modifier_list//1` is a flat
  list of modifier alternatives with no ordering constraint
- **Disposition**: over-accept
- **Why**: enforcing order would require restructuring the modifier
  rule into a sequence with each modifier optionally present. The
  benefit (rejecting one extra wrong shape) is marginal because the
  engine catches it; the cost (more rigid grammar, more discontiguous
  declarations) is real.

## 9. Bare `select` as first identifier in an INSERT column list

- **Shape (rejected by engine)**:
  `insert into omg (select, from, table, where, group, having, order, join) values (1,2,3,4,5,6,7,8)`
- **Shape (accepted by engine)**:
  - `insert into omg ("select", from, table, where, group, having, order, join) values (...)`
    — `select` double-quoted
  - `insert into omg ([select], from, table, where, group, having, order, join) values (...)`
    — `select` bracketed (any delimiter works)
  - `insert into omg (from, table, where, select, group, having, order, join) values (...)`
    — `select` moved out of first position
- **Engine**: rejects with `0x2ead` "Expected expression but instead
  found ," — a parser ambiguity inside `INSERT INTO <table> (` where
  the engine briefly considers a paren-wrapped source before
  committing to a column list, and `select` as the very first token
  pushes it into the wrong branch.
- **Grammar**: accepts — the column list goes through `ident_list`,
  which uses generic `identifier//1` with no position-or-content
  filtering.
- **Disposition**: over-accept
- **Why**: the ambiguity is purely positional and is unique to bare
  `select` in this one spot. Fixing it in the grammar would need a
  contextual rejection rule ("if first token after `INSERT INTO t (`
  is bare `select`, fail") which is ugly disambiguation for one
  keyword in one position; the engine catches it the moment a real
  query runs. Demonstrating the asymmetry from the same probe
  session as divergence #2's keyword-named-column rabbithole:
  DBISAM is **extremely** permissive about keywords-as-identifiers
  (you can `CREATE TABLE table (select int, from int, table int,
  where int, group int, having int, order int, join int)` and the
  engine doesn't blink), with this one positional exception.

## 10. EXPORT/IMPORT file-name uses identifier syntax (not string literal)

- **Shape (rejected)**: `EXPORT TABLE foo TO 'foo.csv'` — single-quoted string literal
- **Shape (accepted by engine)**:
  - `EXPORT TABLE foo TO foo` — bare identifier
  - `EXPORT TABLE foo TO "foo.csv"` — double-quoted identifier (admits dots, slashes)
  - `EXPORT TABLE foo TO [/tmp/foo.csv]` — bracketed identifier (in this slot only)
- **Engine**: `'foo.csv'` rejects with "Expected file name but instead
  found 'foo.csv'" — DBISAM's parser refuses string literals in the
  file-name position.
- **Grammar**: accepts the bare, double-quoted, and bracketed forms;
  single-quoted string literal correctly rejected. **However**, our
  bracket-identifier rule restricts contents to bare-ident chars
  (matching column-name context from slice #40), so paths with
  slashes inside brackets — like `[/tmp/foo.csv]` — are
  grammar-rejected even though the engine accepts them. The
  workaround is to use the double-quoted form `"/tmp/foo.csv"`
  which our grammar admits via the quoted-identifier rule.
- **Disposition**: over-restrict (grammar rejects bracketed paths
  with non-ident chars; engine accepts them in EXPORT/IMPORT file
  position specifically).
- **Why**: DBISAM treats file names as object names rather than
  data values — a very Delphi-flavoured choice. The engine appears
  to relax bracket-identifier char-class rules contextually for
  this slot, while keeping the strict rule for column references.
  Fixing this in the grammar would need a position-specific
  identifier rule.
- **Canonical entries**: no corpus entries yet — EXPORT/IMPORT
  hasn't surfaced in any production query in the Ramsden codebase.
- **See also**: memory `dbisam-statement-vocabulary.md` (EXPORT/IMPORT
  are 2 of the 18 top-level statement keywords).

## 11. Multi-statement parsing

- **Shape (accepted by engine)**:
  - `select ...; select ...;` — two SELECTs in one wire submission
  - `commit; select ...;` — mixed statement types
  - `select ...;;` — multiple trailing semicolons
- **Shape (rejected by engine)**:
  - `;` alone — first token can't be `;`
  - `;;` alone — same reason
- **Engine**: accepts multiple statements separated by semicolons
  on a single wire submission. Trailing semicolons are tolerant
  (any positive count).
- **Grammar**: REJECTS all multi-statement input. The
  `trailing_semicolon_opt` rule handles ONE trailing `;` only;
  `phrase/2` requires the input to be consumed by a single
  statement.
- **Disposition**: over-reject (grammar admits one statement;
  engine admits N).
- **Why not fixed yet**: no corpus entry uses multi-statement
  (verified comprehensively in slice #75 — all 137 entries are
  single-statement). Implementing requires refactoring
  `parse_statement/2` to return a list, migrating 119 meaningful
  expected.term files, and updating the generator and harness.
  Not worth doing without a corpus driver. If a future
  production query surfaces multi-statement use, this is the
  divergence to revisit first.
- **See also**: `tools/harvest-mrsflow-log.sh` already implicitly
  assumes single-statement (one SQL string per log line); a
  multi-statement future would need both the harness and the
  grammar updated.

## 12. Documentation drift

The Elevate Software online manual (the
[DBISAM v4 SQL reference](https://www.elevatesoft.com/manual?action=topics&id=dbisam4&product=delphi&version=5&section=sql_reference))
contains several behaviours that disagree with what the engine on
rivsem04 actually does. When the docs say one thing and the engine
says another, **the engine wins** and gets recorded here. The docs
are advisory; the corpus is empirical.

- **See also**: memory `dbisam-docs-diverge-from-engine.md`

---

## How to add a new divergence

Two parallel artefacts get created:

1. **A corpus entry** (if the divergence is exemplifiable with a single
   query): add a directory under `corpus/<area>/<sub>/<NNNN-slug>/`
   with `query.sql`, `meta.toml`, `engine_verdict.json`, and (if the
   grammar accepts the SQL) `expected.term`. Use `status =
   "expected-divergent"` and add a `[divergence]` block to meta.toml:

   ```toml
   [divergence]
   reason = "One-paragraph description of why grammar and engine disagree."
   reference = "docs/DIVERGENCES.md#<anchor>"
   ```

2. **A section in this file** with the five fields (Shape, Engine,
   Grammar, Disposition, Why). Link back to the canonical corpus entry
   that triggered the addition.

The two-way reference (corpus → docs, docs → corpus) is what makes
the divergence catalogue survive future grammar changes. When you
touch grammar/dcg.pl, the harness flags any entry whose verdict moved;
when it moves on an `expected-divergent` entry, this file is where to
look first.
