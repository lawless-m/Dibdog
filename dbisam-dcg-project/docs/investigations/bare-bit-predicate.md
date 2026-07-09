# Investigation: bare Bit column as a predicate

**Status:** closed (2026-07-09) — engine probed on rivsem04; confirmed
`over-reject`; grammar fixed and regression-guarded.
**Disposition:** `over-reject`, **confirmed** — the catalogue's first
consequential over-reject. See **Results** below and `DIVERGENCES.md` #13.
**Raised from:** the Pintail `quote_conversion.m` work (2026-07). The Pintail
POC→Live playbook originally recommended `CASE WHEN c.customer THEN 'Y' ELSE 'N'
END` for a Bit column; the grammar rejected it and the recommendation was changed
to `= TRUE`. That change was made on the *grammar's* say-so alone — the engine's
behaviour was never probed. This doc exists to close that gap.

If confirmed as `over-reject`, this is the **first over-reject of consequence** in
the catalogue: every other entry in `docs/DIVERGENCES.md` is an `over-accept`
(grammar permissive, engine strict) or an agreed `both-reject`. An over-reject
means the grammar is turning away SQL the engine would run — a false negative,
which is the failure mode that actually costs us (it tells a report author their
valid query is malformed).

---

## The finding, precisely

A lone Bit/Boolean column used *as a truth value* — with no comparison operator —
is rejected by the DCG in every predicate position.

Verified against grammar HEAD `dbef463` with `tools/parse-to-term.pl`
(exit 0 = grammatical, exit 1 = rejected):

| # | SQL | DCG |
|---|-----|-----|
| 1 | `select case when c.customer = true then 'Y' else 'N' end as x from customer c` | accept |
| 2 | `select case when c.customer then 'Y' else 'N' end as x from customer c` | **reject** |
| 3 | `select code from customer c where c.customer` | **reject** |
| 4 | `select code from customer c where c.customer = 1` | accept |
| 5 | `select code from customer c where c.customer = true` | accept |
| 6 | `select code from customer c where c.customer and c.code > 0` | **reject** |

Reproduce:

```bash
cd tools
printf "%s\n" "select code from customer c where c.customer" > /tmp/q.sql
scryer-prolog -g main parse-to-term.pl -- /tmp/q.sql ; echo "exit=$?"
```

## Results — engine probed on rivsem04, 2026-07-09

Probed via the engine harness (`harness/engine`, native DBISAM wire
protocol — the project oracle, **not** DuckDB) against a real Bit column,
`CUSTOMER.CUSTOMER` (the Pintail "is a customer" flag; confirmed `BOOLEAN`
in the catalog). The harness was proven to discriminate in the same
session: `select * from no_such_table_xyz` → rejected `0x2b02`, and
`select nonexistent_col_xyz from CUSTOMER` → rejected `0x2ead`. So the
accepts below are genuine.

| # | Shape | SQL | Engine | Grammar (pre-fix) |
|---|-------|-----|--------|-------------------|
| 1 | WHERE, bare | `where c.CUSTOMER` | **accepted** | reject |
| 2 | WHERE, bare AND-chain | `where c.CUSTOMER and c.CODE > '0'` | **accepted** | reject |
| 3 | WHERE, NOT of bare | `where not c.CUSTOMER` | **accepted** | reject |
| 4 | searched CASE WHEN, bare | `case when c.CUSTOMER then 'Y' else 'N' end` | **accepted** | reject |
| 5 | control: `= 1` | `where c.CUSTOMER = 1` | accepted | accept |
| 6 | control: `= TRUE` | `where c.CUSTOMER = true` | accepted | accept |
| 7 | control: CASE `= TRUE` | `case when c.CUSTOMER = true then …` | accepted | accept |

**Verdict: outcome 1 — the engine accepts the bare form everywhere.**
Every reqcode was `0x0000` (accepted). This is a confirmed `over-reject`:
the grammar was turning away SQL the engine runs. The Pintail `= TRUE`
recommendation was defensible but unnecessary — the grammar, not the
engine, forced it.

**Fix landed (2026-07-09):** the `predicate_atom(truth(V)) --> value(V)`
alternative described below, plus its `gen_predicate` mirror. Verified:
all four bare shapes now parse; `fuzz-roundtrip` 73/73 (incl. 5 new
`truth/1` cases); zero verdict moves across the other 136 corpus entries.
Regression guard: `corpus/select/basic/0013-bare-bit-predicate/`
(`meaningful`). Catalogued as `DIVERGENCES.md` #13.

## Root cause in the grammar — one gap, four surfaces

`predicate_atom//1` (`grammar/dcg.pl:1193`–`1285`) has exactly twelve
alternatives: parenthesised sub-predicate, `NOT`, `IS [NOT] NULL`, `[NOT] IN`,
`[NOT] BETWEEN`, `[NOT] LIKE`, `cmp_op`, and `=`. Every one of them consumes a
`value` and then **requires an operator/keyword to follow**. There is no
alternative of the shape:

```prolog
predicate_atom(<truth>(V)) --> value(V).
```

So a bare `value` reaches `predicate_atom`, matches the leading `value(L)` of each
alternative, finds no operator, and every alternative fails — the whole predicate
fails.

Because all four predicate-bearing positions funnel through the same
`predicate_or//1`, the single gap surfaces in all of them:

- `WHERE` — `where_opt`, `dcg.pl:704`
- `JOIN ... ON` — `dcg.pl:1029`
- `HAVING` — `dcg.pl:1102` / `1134`
- **searched `CASE WHEN`** — `case_when_list_searched`, `dcg.pl:1403`, whose
  condition slot is `predicate_or(C)`

(The *simple* `CASE <expr> WHEN <value>` form at `dcg.pl:1411` uses `value`, not a
predicate, so it's unaffected — the WHEN there is a value to match, not a truth
test.)

This is tidy: if the engine accepts the bare form, one added alternative fixes all
four positions at once.

---

## What is NOT yet known — the engine side

> **Resolved 2026-07-09 — see Results above.** This section framed the
> open question; the probe answered it (outcome 1). Kept for the record
> of how the gap was reasoned about before the engine was asked.

**We have never probed rivsem04 for this.** The belief that DBISAM accepts a bare
Bit column as a predicate is inherited from a Delphi/Pascal intuition (DBISAM has a
real Boolean type), not from an engine verdict. DuckDB accepts the bare form, but
DuckDB is not the arbiter here — the engine on rivsem04 is.

Three outcomes are genuinely possible, and the probe decides which:

1. **Engine accepts the bare form everywhere** → confirmed `over-reject`. Fix the
   grammar (see below), add a corpus entry, add a `DIVERGENCES.md` section.
2. **Engine rejects the bare form too** → `both-reject`. No grammar change. The
   Pintail `= TRUE` recommendation was right, just for a reason we hadn't
   established. Document it as an agreed rejection so nobody re-opens it.
3. **Engine accepts it in some positions but not others** (e.g. `WHERE` yes,
   `CASE WHEN` no) → position-dependent. Document per position; the fix, if any,
   becomes surgical rather than the single-atom change.

Do not assume outcome 1. Outcome 2 is entirely plausible — plenty of SQL engines
forbid bare boolean columns and demand `= TRUE` / `= 1`.

---

## Exploration plan (run in a Dibdog session on rivsem04)

### 1. Pick a real Bit column

Substitute a genuine Bit column on a real table for `<bitcol>` below. The Pintail
work used the customer "is a customer" flag on `CUSTOMER`; confirm the actual
column name from the catalog before probing (a mis-named column would reject with
the 0x2ead column-not-on-table check — divergence #2 — and mask the real result).

### 2. Probe matrix

For each position, run the **bare** form and its `= 1` / `= TRUE` controls. The
controls must pass; if a control fails, the table/column is wrong, not the finding.

```sql
-- WHERE, bare
select * from CUSTOMER where <bitcol>;
-- WHERE, bare in an AND chain
select * from CUSTOMER where <bitcol> and code > '0';
-- WHERE, NOT of bare
select * from CUSTOMER where not <bitcol>;
-- searched CASE WHEN, bare
select case when <bitcol> then 'Y' else 'N' end from CUSTOMER;
-- JOIN ON, bare  (needs a second table; adapt to a real FK)
-- HAVING, bare   (needs a GROUP BY; adapt)

-- controls (expected to pass on the engine):
select * from CUSTOMER where <bitcol> = 1;
select * from CUSTOMER where <bitcol> = true;
select case when <bitcol> = true then 'Y' else 'N' end from CUSTOMER;
```

Capture the reqcode for each rejection (see `docs/reqcodes.md`). A bare-form
rejection will most likely come back as `0x2ead` "Expected ... but instead found
...", but record the *exact* message — the wording tells us whether the engine
wants an operator (syntactic) or is doing something type-aware.

### 3. Record verdicts

Log each shape's `{verdict, reqcode, message}` in this doc under a "Results" table
before deciding disposition. Empirical first, disposition second — house style.

---

## If confirmed `over-reject`: the fix, and its one trap

The parse fix is a single alternative, added **last** in `predicate_atom//1` so it
only fires when no operator form matched (ordering is significant — Prolog tries
clauses top-to-bottom):

```prolog
% Bare Bit/Boolean column used as a truth value. LAST alternative:
% only reached when the value is followed by no comparison operator.
predicate_atom(truth(V)) --> value(V).
```

**The trap: this grammar is bidirectional.** `predicate_atom` has a matching
`gen_predicate/2` generator, and the corpus round-trips (parse → term → generate →
must equal canonical SQL, see `tools/fuzz-roundtrip.pl`). So the fix is *not* one
line:

- The AST needs a **distinct functor** (`truth(V)` above, not bare `V`) or the
  generator can't tell "emit `col`" from "emit the value `col`" in a non-predicate
  slot, and round-trip becomes ambiguous.
- Add the mirror `gen_predicate(truth(V), Chars) :- gen_value(V, Chars).` and make
  sure it's *not* also reachable through `gen_value` in a way that lets a plain
  value serialise as a predicate.
- Re-run the full corpus harness. Any `meaningful` entry whose value expression
  could now *also* parse as a bare-truth predicate would show a verdict move —
  check none do (a bare column in a value slot must stay a value; only the
  predicate positions gain the new reading).

Because the new alternative is last and requires the absence of an operator, the
common cases (`col = 1`, `col LIKE '%x%'`, `col IN (...)`) are unaffected — they
match an earlier alternative and never reach the fallback.

### Corpus entry to add

Mirror the format of an existing `expected-divergent` entry
(`corpus/ddl/alter_table/0100-alter-table-add-column/`). Under
`corpus/select/<NNNN-bare-bit-predicate>/`:

- `query.sql` — the `WHERE <bitcol>` shape
- `engine_verdict.json` — `{"verdict":"accepted"}` (from the probe)
- `expected.term` — the parsed term *after* the fix (before the fix there is none,
  because the grammar rejects it — which is the whole point)
- `meta.toml` with `status = "expected-divergent"` **only if** it stays divergent.
  If the fix lands and grammar+engine now agree, this becomes a plain `meaningful`
  entry, not divergent — it's the regression guard that the fix holds.

### DIVERGENCES.md section

Add as divergence **#13**, disposition `over-reject`, with the five standard
fields, and cross-link back to this investigation. Note it's the catalogue's first
consequential over-reject.

---

## If confirmed `both-reject`

No grammar change. Add a short `DIVERGENCES.md` entry (disposition `both-reject`)
recording that DBISAM requires an explicit `= TRUE` / `= 1` and does not admit bare
Bit columns as predicates — so the Pintail playbook's `= TRUE` recommendation is
correct and the grammar is faithful. Close this investigation. The value of writing
it down is stopping the next person re-deriving the `CASE WHEN c.customer` mistake.

---

## Cross-references

- Grammar: `predicate_atom//1` `grammar/dcg.pl:1193`; predicate positions at
  `:704` (WHERE), `:1029` (ON), `:1102`/`:1134` (HAVING), `:1403` (searched CASE).
- Divergence catalogue: `docs/DIVERGENCES.md` (this would be #13).
- Origin: Pintail `POC_TO_LIVE_PLAYBOOK.md` (the `= TRUE` recommendation) and the
  `dbisam-odbc-quirks` memory (Bit-column wrapping note).
- Verified on grammar HEAD `dbef463`.
