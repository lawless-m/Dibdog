# Railroad Diagrams for the DBISAM Grammar

## Goal

Produce a set of railroad (syntax) diagrams for DBISAM SQL in the visual style of the SQLite `lang_select.html` page — one diagram per nonterminal, cross-linked, rendered as SVG, embeddable in an HTML page. The diagrams document the dialect the Dibdog DCG actually accepts, so they are *derived mechanically from the grammar*, never hand-drawn from memory or from Elevate's docs.

## The non-negotiable: the diagram must track the DCG

The whole value of this is that the picture matches what `grammar/dcg.pl` accepts. A diagram that drifts from the grammar is worse than no diagram, because it lies with authority. So the EBNF the diagrams are drawn from is *extracted* from the grammar by a program, and an equivalence gate proves the extracted EBNF accepts the same language as the DCG. That gate is the heart of this project, not an afterthought.

## Approach: extract, don't transcribe

The DCG is complete and stable. The diagrams are built by a Claude-written **extractor** that reads the grammar's clauses and emits a railroad-ready EBNF mechanically. No human or hand-authored intermediate sits between the DCG and the EBNF — a transcribed intermediate would reintroduce exactly the silent-drift risk this project exists to kill, and would turn the equivalence gate into a perpetual transcription-error catcher instead of a one-time proof. With extraction, the gate verifies a *program* against the grammar; once it passes, it stays correct for free.

```
grammar/dcg.pl ──► extractor (Scryer, via clause/2) ──► grammar.ebnf
                                                            │
                              ┌─────────────────────────────┤
                              ▼                             ▼
                     equivalence gate                  railroad renderer
                  (corpus + fuzzer)                    (EBNF → SVG per rule)
                              │                             │
                          pass/fail                    diagrams/*.svg
                                                            │
                                                       index.html
                                                  (SQLite-style page,
                                                   cross-linked)
```

## The extractor

**Run it inside Scryer, reading the loaded grammar with `clause/2` — do not parse `dcg.pl` as text.** The grammar is already valid Prolog that Scryer loads; asking the loaded program what its rules are (via `clause(Head, Body)` over the DCG-expanded clauses, or by reading terms before expansion with `read_term/3` and `term_expansion`) is robust where regexing source is fragile. The extractor walks each rule body and maps DCG constructs to railroad EBNF:

- **Sequence.** A conjunction `A, B, C` in a rule body → a railroad track in order.
- **Whitespace is elided.** `ws` and `ws1` carry no syntax and produce no diagram element. Drop them.
- **Keywords are terminals.** `keyword(select)` → the uppercase terminal `SELECT`. Keywords are structural only and never nonterminal references.
- **Literal terminals.** `[',']`, `['(']`, `['.']` etc. → the literal terminal box for that token.
- **Alternation.** Multiple clauses sharing a head → parallel branches (a `Choice`). E.g. `statement_body//1`'s thirteen clauses → a thirteen-way branch.
- **Option.** A clause plus an empty (`--> []`) clause for the same head → an optional bypass. E.g. `distinct_opt` → `[ DISTINCT | ALL ]` with a skip path; `where_opt`, `trailing_semicolon_opt` likewise.
- **Repetition — the one transform with teeth.** The pervasive idiom
  ```
  foo_list([X|Xs])      --> foo(X), foo_list_rest(Xs).
  foo_list_rest([])     --> [].
  foo_list_rest([X|Xs]) --> ws, [','], ws, foo(X), foo_list_rest(Xs).
  ```
  must be **collapsed into a single `OneOrMore(foo, separator=',')`** loop, not drawn as two unrelated rules. The extractor detects the `_list` / `_list_rest` (or equivalent recursive-tail) pairing and folds it. This is the only heuristic in the extractor; everything else is rote. Because it is a heuristic, it is exactly what the equivalence gate exists to validate — if the fold ever mis-fires, a fuzz sentence will diverge and the gate fails loudly.
- **Nonterminal reference.** Any other DCG nonterminal call → a hyperlinked `NonTerminal` pointing at that rule's own diagram.

**Fail loudly on unrecognised clause shapes.** If the extractor meets a body construct it has no mapping for, it must error and name the offending rule — never silently skip it. A construct it can't project must surface as a visible failure, not a missing diagram. (The grammar being complete, this should fire only if a genuinely novel shape exists; treat any firing as either a missing extractor case or a grammar oddity worth a look.)

## Build the gate before the renderer

Order matters: a correct EBNF you cannot yet draw is real progress; a beautiful diagram you cannot trust is not. So:

1. Extractor → EBNF.
2. **Equivalence gate green.** Only then,
3. Renderer → SVG → page.

Do not start the renderer until the gate passes. The renderer is rote SVG plumbing; the gate is where correctness lives.

## The equivalence gate — how the EBNF is kept honest

Two complementary checks, both reusing machinery the repo already has:

1. **Corpus replay (necessary).** Every statement in `corpus/` the DCG accepts must also be derivable by the extracted EBNF grammar; every corpus negative (where marked) must be rejected by both. The corpus is curated ground truth — the EBNF must neither narrow nor widen it.

2. **Differential fuzzing (the strong check).** Run the DCG *backwards* as a generator — the grammar is relational and `generate_statement/2` already emits valid canonical SQL — to produce sentences, and confirm the EBNF parses each. Then generate sentences from the EBNF and confirm the DCG parses each. Any sentence accepted by one and rejected by the other is a bug: usually a projection error in the extractor (fix it), occasionally a real grammar issue the diagram work surfaced (worth knowing). This proves *picture ≡ parser*.

The gate runs in CI. A diagram set that has not passed the gate is not published.

## Diagram inventory

One diagram per significant nonterminal, top-down. At minimum:

- `statement` (entry: ws → statement-body → optional `;`)
- `statement-body` (the thirteen-way alternation)
- `select-statement` (the `SELECT … INTO … FROM` variant, tried first, and the plain variant)
- `select-chain` / `union-rest` (left-associative `UNION` / `UNION ALL` loop)
- `column-list`, `column` (`*`, `aliased(Item, AS ident)`, value-expression columns)
- `table-ref-list`, `table-or-joined`, join forms (`INNER` / `LEFT [OUTER]` / `RIGHT` `JOIN … ON …`, comma form, left-associative chaining)
- `modifier-list` and each modifier (`TOP n`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`) — DBISAM source-order is WHERE, GROUP BY, HAVING, ORDER BY, TOP
- `predicate` family (`AND` / `OR` with precedence, `cmp`, `LIKE` / `NOT LIKE`, `IS [NOT] NULL`, `[NOT] IN (list | subselect)`, `[NOT] BETWEEN`, `NOT (...)`)
- `value` / expression (identifiers, qualified `a.b`, string / integer / decimal / boolean literals, `?` parameter, `arith` with precedence, `CAST`, `CASE` searched + simple, `function_call`, `EXTRACT`, `TRIM`, `neg`)
- DML/DDL statements (`UPDATE`, `INSERT` two source forms, `DELETE`, `DROP TABLE [IF EXISTS]`, `DROP INDEX` bare + qualified, `CREATE [UNIQUE|NOCASE] INDEX … ON … (cols)`, `ALTER TABLE … ADD col type`, `RENAME TABLE … TO …`, maintenance `EMPTY|OPTIMIZE|VERIFY|REPAIR|UPGRADE TABLE`, `EXPORT` / `IMPORT TABLE`, transaction control)
- lexical leaves drawn as terminals, not expanded: `identifier`, `string-literal`, `integer-literal`, `decimal-literal`

Cross-link every nonterminal reference to its own diagram, as the SQLite page does.

## Renderer

Use the established railroad-diagram generator lineage (tabatkins' `railroad-diagrams`, the family behind the SQLite-style diagrams) — it emits SVG with the rounded-terminal / branch / loop vocabulary the SQLite page uses. The EBNF → renderer-input step is a small transform: terminal → `Terminal`, nonterminal ref → `NonTerminal` (hyperlinked), sequence → `Sequence`, alternation → `Choice`, option → `Optional`, the collapsed list idiom → `OneOrMore` with separator.

Output: one SVG per nonterminal plus an `index.html` laying them out and cross-linking, matching the SQLite "factored" presentation (each rule shown separately, sub-rules linked rather than inlined). The repo is already majority-HTML, so this slots into the existing output story.

## Scope boundaries

- **Whitespace and keyword-casing are not drawn.** `ws`/`ws1` elided; keywords render uppercase as terminals (the grammar accepts case-insensitive keywords; the canonical form is upper, per `generate_statement/2`).
- **No semantic annotations in the track.** The diagram shows syntax only. Notes like "DBISAM rejects multi-row VALUES" or "file names are object names, not string literals" go in prose beneath the relevant diagram — as the SQLite page keeps its deviation notes in text, not in the rails.
- **The diagram documents the current grammar.** Out-of-scope constructs have no rule and fail to parse honestly; the diagrams inherit that scope. A construct the DCG doesn't accept must not be drawn.

## Open questions

1. **One page or many.** SQLite puts the whole `SELECT` syntax on one page with sub-rules factored below. Dibdog covers far more than SELECT (full DML/DDL). Decide: one mega-page mirroring SQLite, or an index page linking per-statement pages.
2. **Fuzzer seed source for the gate.** Reuse the generator's sentence enumeration (breadth) or drive from corpus shapes (realism)? Probably both, corpus shapes weighted higher.
3. **Terminal granularity for `identifier`.** DBISAM identifiers come bare, double-quoted, and bracketed. Draw `identifier` as a single terminal box (simpler, matches SQLite's `table-name` treatment) or expand the three lexical forms into their own diagram? Likely a single box with a prose note.
4. **Pre- vs post-expansion clause reading.** Read DCG clauses after standard DCG expansion (bodies carry the `S0/S` threading, which the extractor must unwind) or intercept terms before expansion via `term_expansion`/`read_term` (cleaner bodies, but the extractor reimplements the rule-shape reading)? Spike both early; pick whichever makes the `_list`/`_rest` fold easier to detect reliably.
