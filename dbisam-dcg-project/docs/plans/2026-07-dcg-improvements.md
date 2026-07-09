# Plan: DCG improvements (from the 2026-07-09 review)

Follow-up work items from the post-bare-bit-predicate review of
`grammar/dcg.pl` (see commit `60d76b4` and
`docs/investigations/bare-bit-predicate.md` for the precedent this plan's
working style is based on). Each task is independent and should land as
**one commit per task**, in the order given (rationale under "Ordering").

## Ground rules (project house style — do not skip)

- **Empirical first.** Never change the grammar on intuition or on another
  engine's behaviour (DuckDB accepts things DBISAM doesn't, and vice
  versa). The oracle is the live engine on rivsem04 via `harness/engine`.
  Record probe results in a doc *before* deciding disposition.
- **The grammar is bidirectional.** Every parse rule change needs its
  `gen_*` mirror checked, plus `tools/fuzz-roundtrip.pl` cases. Distinct
  AST functors per construct — never reuse a functor for two readings.
- **Ordering is load-bearing** in `predicate_atom//1`: Prolog tries
  clauses top-to-bottom. `truth(V) --> value(V)` MUST stay the last
  alternative (it fires only when no operator form matched).
- **Three verification gates for any grammar change** (all must be green
  before commit):
  1. Targeted parse checks via `tools/parse-to-term.pl` (exit 0 = parse,
     1 = reject).
  2. `scryer-prolog -g main tools/fuzz-roundtrip.pl` — currently
     **73/73**; must stay all-green (add cases for new constructs).
  3. Full-corpus zero-drift: run `parse-to-term.pl` per entry, before
     and after, diff the exit codes. Currently **118 parse / 20 reject**
     across 138 entries. Any moved verdict must be explained or reverted.
- **Windows environment gotchas** (all pre-existing; do not "fix" them
  as a side quest):
  - `harness/grammar/run.sh` (single long-running Scryer) exhausts file
    descriptors → use a one-process-per-entry loop instead:
    ```bash
    find corpus -mindepth 2 -name query.sql | sort | while read -r q; do
      scryer-prolog -g main tools/parse-to-term.pl -- "$q" >/dev/null 2>&1
      echo -e "$?\t$q"
    done > /tmp/parse-<label>.txt
    ```
  - `harness/differential/run.sh` fails with `jq: Argument list too long`
    in its final aggregation. Per-entry results are still the truth; the
    zero-drift diff above is the accepted substitute.
  - Paths with spaces (`Y:\Data Warehouse\...`) break in Bash; use
    PowerShell for those.
- **Engine harness recipe** (only needed for Task 2):
  ```bash
  # build (once): cd harness/engine && cargo build --release
  export DIBDOG_EM_HOST=rivsem04
  export DIBDOG_EM_USER=e3user
  export DIBDOG_EM_PASS="$(kdbx-getfield '//RIVSPROD02/RI SERVICES/Credentials/ServicePasswords.kdbx' kdbx-services 'Exportmaster/RIVSEM04' password)"
  ./harness/engine/target/release/dibdog-engine-harness.exe   # background
  curl -s http://127.0.0.1:38120/health    # {"ok":true,"target":"rivsem04"}
  ```
  Credentials never go in any repo file. Kill the harness
  (`taskkill //IM dibdog-engine-harness.exe //F`) when probing is done —
  it holds a connection to a production server.
  **Always run discrimination controls** in the same session before
  trusting accepts: `select * from no_such_table_xyz` must reject
  `0x2b02`; `select nonexistent_col_xyz from CUSTOMER` must reject
  `0x2ead`.

---

## Task 1 — Fix the stale module header

**Problem:** `grammar/dcg.pl:1-58` still describes "first slice … one
statement: bare SELECT". The grammar now covers 13 statement types,
UNION trees, IN-subqueries, DML, DDL, transactions, comments, and the
`truth/1` predicate form. The header is the newcomer's map and it is
wrong.

**Do:**
- Rewrite the header to describe current scope: list the statement
  types (mirror `statement_body//1` at `dcg.pl:652-664`), summarise the
  AST conventions (functor-per-construct, `identifier/1` wrapping,
  modifiers list in source order), keep the case-handling, round-trip
  discipline, and anti-stub sections (still accurate).
- Point to `docs/DIVERGENCES.md` and `docs/reqcodes.md` as companions.
- Do NOT touch any rule code in this commit.

**Verify:** gates 2 and 3 (trivially unchanged — this is comments only;
run them anyway so the commit message can say so).

---

## Task 2 — Probe `WHERE <constant>` (nuance left by the truth/1 fix)

**Problem:** `predicate_atom(truth(V)) --> value(V)` admits *any* value,
not just columns — so `WHERE 1`, `WHERE 'x'`, `WHERE 1 + 1` now parse.
Nobody has probed whether the engine accepts a constant truth value.
If it rejects, that's a (probably acceptable) over-accept to catalogue,
consistent with divergences #1–#3; if it accepts, document agreement.

**Do:**
1. Start the engine harness (recipe above), run discrimination controls.
2. Probe at minimum:
   - `select CODE from CUSTOMER where 1`
   - `select CODE from CUSTOMER where 0`
   - `select CODE from CUSTOMER where 'x'`
   - `select CODE from CUSTOMER where 1 + 1`
   - `select case when 1 then 'Y' else 'N' end from CUSTOMER`
   - control: `select CODE from CUSTOMER where CUSTOMER` (known accept)
3. Record `{verdict, reqcode, message}` per shape in a new short section
   of `docs/investigations/bare-bit-predicate.md` (it's the natural
   home — "constant truth values" is the same investigation's tail) or a
   new investigation doc if the results are surprising.
4. Disposition:
   - Engine rejects constants → add an over-accept note to
     `DIVERGENCES.md` #13 (grammar stays as-is; type-awareness is an
     engine concern, same reasoning as #3). Optionally add a
     `corpus/rejected/` or `expected-divergent` entry.
   - Engine accepts → note the agreement in #13; consider a small
     corpus entry as regression guard.
5. Kill the harness.

**Verify:** doc updated with empirical table; any corpus entry added
passes `tools/corpus-promote.sh` (or the agreed-rejection branch of it).

---

## Task 3 — Make the `keyword//1` boundary contract explicit

**Problem:** `keyword//1` (`dcg.pl:1857-1866`) matches characters and
stops — it does NOT check that the next char isn't an identifier
continuation. Token-boundary safety relies on every *caller* following
the keyword with `ws1` or punctuation (e.g. `keyword(not), ws1` refuses
a column named `notes` only because `ws1` fails on `e`). This invariant
is real but implicit; a future rule written `keyword(k), ws, <optional>`
could silently mis-tokenize.

**Do (minimal, in this order of preference):**
1. Add a loud comment block above `keyword//1` stating the contract:
   "callers MUST follow a keyword with ws1 or an explicit punctuation
   token; `keyword//1` performs no boundary lookahead."
2. Audit all `keyword(...)` call sites for violations — i.e. any
   occurrence where the keyword is followed by `ws` (zero-or-more) and
   the next element could match an identifier-continuation char. Grep:
   `grep -n "keyword(" grammar/dcg.pl` and inspect each. Record the
   audit result in the comment ("audited 2026-07-XX: all N call sites
   comply").
3. ONLY IF the audit finds a real violation: fix that call site (not the
   keyword predicate), with a targeted parse test proving the
   mis-tokenization existed.

Do NOT add a negative-lookahead variant speculatively — that's
complexity without a driver (CLAUDE.md simplicity rule).

**Verify:** gates 2 and 3 unchanged. If a violation was fixed, add a
fuzz/parse case demonstrating it.

---

## Task 4 — Left-factor `predicate_atom//1`

**Problem:** every operator alternative in `predicate_atom//1`
(`dcg.pl:1193-1297`) starts with `value(L)` and backtracks the entire
value parse when the operator tail doesn't match — up to ~10 re-parses
of the same value per predicate atom. Fine at corpus scale; multiplicative
for bulk-parsing harvested query logs (deep function-call/CASE values
inside long AND chains).

**Do:**
- Restructure to parse the leading value ONCE, then dispatch on a tail:
  ```prolog
  % Keep these two FIRST, unchanged (they don't start with value):
  predicate_atom(P)      --> ['('], ws, predicate_or(P), ws, [')'].
  predicate_atom(not(P)) --> keyword(not), ws1, predicate_atom(P).
  % Then the factored form:
  predicate_atom(P)      --> value(L), predicate_tail(L, P).
  ```
  with `predicate_tail(L, P)` alternatives preserving the EXACT current
  ordering: `IS NOT NULL` before `IS NULL`; `NOT IN`/`NOT BETWEEN`/
  `NOT LIKE` before their positive forms; `cmp_op` longer-prefix rules
  unchanged; `=` after `cmp_op`; and **`truth` as the empty tail, LAST**:
  ```prolog
  predicate_tail(L, truth(L)) --> [].
  ```
- The AST must be byte-identical for every existing input — this is a
  pure refactor. First-solution semantics matter: the harness commits to
  the first parse (`phrase_from_file(...) -> ...`), so alternative order
  inside `predicate_tail` must reproduce the current first solution.
- Generator side: NO changes (`gen_predicate` keys on AST functors,
  which don't change).
- Keep the existing explanatory comments with the rules they describe;
  add a short comment explaining the factoring and that tail order
  mirrors the old clause order.

**Verify (all three gates, strictly):**
- Doc matrix: the 7 bare/control queries from
  `docs/investigations/bare-bit-predicate.md` all still exit 0.
- `fuzz-roundtrip.pl`: 73/73.
- Full-corpus diff vs a pre-change baseline: **zero moved verdicts**
  AND zero `expected.term` drift — for the 117+1 parsing entries, also
  compare the emitted term against each entry's `expected.term`
  (`tools/promote-check.pl <query.sql> <expected.term>` per meaningful
  entry, or diff `parse-to-term.pl` output against `expected.term`).
  Term-shape identity is the point of this gate: verdict-only diffing
  would miss an AST change.

---

## Task 5 — Failure diagnostics (furthest-failure position)

**Problem:** `parse_statement/2` fails with no reason and no position.
The investigation that produced this plan was about the cost of telling
a report author "your valid query is malformed"; the next-worst
experience is "malformed, and I won't say where". The engine reports
`code_b` = 1-based char position of the offending token
(`docs/reqcodes.md`), so a grammar-side position also unlocks a new
differential axis.

**Design constraints:**
- Do NOT slow down or destabilise the happy path. Parse normally first;
  run diagnostics ONLY on failure, as a separate instrumented pass:
  `parse_statement_diag(Chars, Diag)` alongside the untouched
  `parse_statement/2`.
- Suggested mechanism (adapt if a cleaner Scryer-native way exists):
  a `mark//0` nonterminal placed after each successful token consume in
  the *lexical* layer only (keyword, identifier, literals, punctuation),
  which computes `Pos = TotalLen - RemainingLen` and keeps the maximum
  in backtrackable-global state (`bb_put`/`bb_get` from
  `library(iso_ext)`, or pass TotalLen via the diag entry point).
  `length/2` on the remaining list is O(n) per mark — acceptable because
  this pass runs only on already-failed inputs.
- Output shape: `diag(FurthestPos)` at minimum; expected-token-set is a
  stretch goal, not required for this task.
- Wire into `tools/parse-to-term.pl`: on parse failure, print
  `furthest: <N>` to stderr and keep exit code 1.

**Differential axis (report-only for now):**
- New tool `tools/diag-vs-engine.sh`: for every corpus entry whose
  `engine_verdict.json` is a `0x2ead` rejection with `harness_code_b`,
  and which the grammar also rejects, print
  `<entry> engine_code_b=<M> grammar_furthest=<N>`.
- Positions will NOT match exactly (the engine reports its own token
  positions; whitespace/comment handling differs). This is an advisory
  report — do NOT make it a gate, do NOT tune the grammar to match
  `code_b`. If a stable offset relationship emerges, document it in
  `docs/reqcodes.md`.

**Verify:**
- `parse_statement/2` behaviour unchanged (all three gates).
- New targeted tests: 3–5 known-bad inputs (reuse
  `corpus/rejected/syntax_errors/*`) each produce a plausible furthest
  position (assert the exact numbers in a small test script so they're
  pinned).
- `diag-vs-engine.sh` runs over the corpus without error and produces a
  row for each grammar-rejected + engine-`0x2ead` entry.

---

## Task 6 — Generative round-trip fuzzing

**Problem:** `tools/fuzz-roundtrip.pl` is a curated list (78 terms after
Task 4's additions, if any). Curated lists only catch asymmetries someone
anticipated. Bidirectional grammars break in composition corners — e.g.
the AND/OR paren-wrapping logic (`dcg.pl:366-392`) interacting with NOT,
truth/1, and nested CASE.

**Do:**
- New tool `tools/fuzz-generative.pl`: **deterministic enumeration**
  (not random — reproducibility matters more than coverage-per-run) of
  AST terms up to a fixed depth, from a table of functor signatures:
  - values: `identifier/1`, `qualified/2`, `integer_literal/1`,
    `string_literal/1`, `boolean_literal/1`, `arith/3`, `neg/1`,
    `function_call/2` (one arity-safe function, e.g. `'ABS'`),
    `case_when/2`, `cast/2`
  - predicates: `eq/2`, `cmp/3`, `and/2`, `or/2`, `not/1`, `truth/1`,
    `is_null/1`, `is_not_null/1`, `like/2`, `between/3`, `in/2`
  - wrap each generated predicate in
    `select_statement(all_rows, [identifier(code)], [table(identifier(t), no_alias)], [where(P)])`
    and each generated value in a projection slot.
- Depth 3 over that signature set will produce thousands of terms; cap
  the run (e.g. first 5,000 in enumeration order) and print the count so
  truncation is visible, not silent.
- Same pass/fail contract as `fuzz-roundtrip.pl`:
  `generate → parse → AST == original`, exit 0/1, `FAIL:` lines with the
  generated SQL for each mismatch.
- If it finds real asymmetries: fix them one commit at a time, each with
  the failing term added to the *curated* suite as a pinned regression
  case. Do not bulk-fix.

**Verify:** the new tool runs clean on the current grammar (or every
failure it finds is triaged into its own follow-up fix with a pinned
case). Curated suite still 100%.

---

## Ordering rationale

1 (header) and 2 (probe) are independent and cheap — do them first; 2
needs the harness, so batch it with any other probing you plan.
3 (keyword audit) before 4 (left-factor) so the audit reads the code
that's about to move. 4 before 5 (diagnostics) so the instrumentation
lands on the settled predicate structure, not one about to be
refactored. 6 last — it's the safety net that then guards everything
above, and any asymmetry it finds becomes ordinary follow-up work.

## Out of scope (deliberately — do not drift into these)

- Fixing the Windows `jq`/file-descriptor harness issues (worth doing,
  but it's infra work, not grammar work — separate plan if wanted).
- Multi-statement support (divergence #11 — explicitly parked until a
  production query drives it).
- Clause-order enforcement (divergence #8 — documented as not worth it).
- Any ODBC-escape syntax (divergence #4 — agreed both-reject; adding it
  would break agreement).
