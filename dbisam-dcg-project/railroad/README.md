# railroad — syntax diagrams for the DBISAM grammar

Railroad (syntax) diagrams for DBISAM SQL, in the visual style of the
SQLite `lang_select.html` page — **derived mechanically from
`grammar/dcg.pl`**, never hand-drawn, and proven equivalent to the DCG
by a gate before anything is published.

See [`PLAN.md`](PLAN.md) (the original `railroad-diagrams.md` from
`dibdog-railroad.zip`) for the project plan. This directory is the
implementation.

## Pipeline

```
grammar/dcg.pl ──► extractor.pl ──► grammar.ebnf{.pl,.json,}  (the extracted EBNF)
                                          │
                        ┌─────────────────┴───────────────┐
                        ▼                                  ▼
                  gate/ (equivalence)              renderer.js
                  corpus + curated + negatives     EBNF → SVG + index.html
                        │                                  │
                     PASS/FAIL                       diagrams/*.svg, index.html
```

Build order is **extractor → gate → renderer**, and the gate must be
green before the diagrams are published.

## Components

| File | What it does |
| --- | --- |
| `extractor.pl` | Reads `grammar/dcg.pl` as Prolog *terms* and emits the railroad-ready EBNF in three forms. |
| `grammar.ebnf` | Human-readable EBNF (the doc artifact). |
| `grammar.ebnf.pl` | EBNF as Prolog facts (`ebnf_rule/2`), consumed by the gate. |
| `grammar.ebnf.json` | EBNF as JSON IR, consumed by the renderer. |
| `gate/interp.pl` | The extracted-EBNF interpreter: tokenise (reusing the DCG's lexer) then parse. |
| `gate/curated.pl` | Curated AST set (from `tools/fuzz-roundtrip.pl`) for the DCG→EBNF differential. |
| `gate/gate.pl` | The equivalence gate: corpus replay + curated differential + over-permissiveness negatives. |
| `gate/run.sh` | Gate driver — enumerates the corpus and runs `gate.pl`. |
| `renderer.js` | EBNF IR → one SVG per rule + cross-linked `index.html`. |

## Running it

```sh
cd railroad
scryer-prolog -g main extractor.pl     # 1. extract EBNF  → grammar.ebnf{,.pl,.json}
gate/run.sh                            # 2. prove equivalence (exit 0 = PASS)
node renderer.js                       # 3. render (only after the gate passes)
```

`gate/run.sh` exits non-zero and names every divergence if the EBNF and
the DCG disagree on any corpus query, curated sentence, or negative.

## The extractor

Walks each DCG rule body and maps constructs to a railroad IR:

- conjunction `A, B, C` → a track in order (`seq`);
- `ws` / `ws1` → **elided** (no element);
- `keyword(select)` → the uppercase terminal `SELECT`;
- `[',']`, `['(']`, `['<','=']` → literal terminals (`,`, `(`, `<=`);
- `{Goal}` and `!` → elided (semantic guards / cuts carry no syntax);
- several clauses sharing a head → a `Choice`;
- a clause plus an empty (`--> []`) clause → an `Optional` bypass;
- `identifier` / `string_literal` / `integer_literal` / `decimal_literal`
  → lexical **leaf** terminals (a single box, noted in prose, not expanded);
- any other nonterminal call → a hyperlinked `NonTerminal`.

**The one heuristic — the recursive-tail fold.** The pervasive idiom

```prolog
foo_list([X|Xs])      --> foo(X), foo_list_rest(Xs).
foo_list_rest([])     --> [].
foo_list_rest([X|Xs]) --> ws, [','], ws, foo(X), foo_list_rest(Xs).
```

collapses to a single `foo { "," foo }` (`OneOrMore` with separator). The
extractor detects any predicate that is an empty base plus self-recursive
tails and folds it to a loop. `_rest` / `_more` helpers are inlined (no
own diagram); a directly self-recursive list head (e.g. `modifier_list`)
keeps its diagram but renders as `{ modifier }`. This uniformly folds the
`_list`/`_list_rest` family **and** the accumulator families
(`or_rest`, `and_rest`, `add_rest`, `mul_rest`, `join_rest`, `union_rest`).

The extractor **fails loudly** (throws, naming the rule) on any body
construct it has no mapping for — it never skips silently.

## The gate

Reuses machinery the repo already has. Three checks:

1. **Corpus replay** (necessary). Every corpus query — the structured
   project corpus plus the repo-root raw corpus — is parsed by **both**
   the DCG and the extracted EBNF; their accept/reject verdicts must
   agree. The EBNF may neither narrow nor widen the corpus language.

2. **DCG→EBNF curated differential** (the strong necessary check). The
   DCG run backwards (`generate_statement/2`) emits canonical SQL for a
   broad curated AST set spanning every grammar feature; the EBNF must
   parse each. A mis-fired fold or a dropped construct fails here.

3. **Over-permissiveness negatives**. Malformed strings the DCG rejects —
   heavy on fold edge-cases (`a,,b`, `,a`, `a,`, empty lists, dangling
   separators) — must also be rejected by the EBNF.

The gate's interpreter **shares the DCG's lexer** (`identifier//1`,
`string_literal//1`, `integer_literal//1`, `decimal_literal//1`, `ws//0`
are exported from `grammar/dcg.pl` for this), so only the extracted
*production structure* is under test, never the tokeniser.

## Open questions (resolved)

The plan flagged four decisions for the human; resolved here as:

1. **One page or many** → a single cross-linked `index.html` (the SQLite
   "factored" presentation: each rule drawn separately, sub-rules linked).
2. **Fuzzer seed source** → both, corpus-shaped (real) plus the curated
   AST set (breadth). The reverse (EBNF→DCG) direction is exercised by
   targeted negatives rather than free generation, because the DCG
   carries semantic guards (function-name/arity validity, alias
   look-ahead) that the syntax-only diagrams intentionally elide — free
   EBNF generation would mostly re-discover those elisions, not extractor
   bugs.
3. **`identifier` granularity** → a single terminal box with a prose note
   covering the bare / `"quoted"` / `[bracketed]` forms.
4. **Pre- vs post-expansion clause reading** → pre-expansion (`read_term/3`).
   Pre-expansion bodies carry no `S0/S` threading, which makes the
   recursive-tail fold trivially detectable.

## Scope (inherited from the grammar)

- Whitespace and keyword casing are not drawn.
- No semantic annotations in the track — deviation notes live in prose.
- The diagrams document the *current* grammar: a construct the DCG
  doesn't accept has no rule and is not drawn.
