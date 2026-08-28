# GRAMMAR.md — reading the DBISAM grammar

This is an orientation document, not the grammar itself. The grammar has
exactly one source of truth:

- **Canonical** — `grammar/dcg.pl`. The DCG is the specification. If this
  document and the DCG ever disagree, the DCG wins.

Everything else is a *rendering* of that source, kept honest by tooling:

- **Surface syntax (EBNF)** — `railroad/grammar.ebnf`. Auto-generated from
  `grammar/dcg.pl` by `railroad/extractor.pl` and proven equivalent to the
  DCG by `railroad/gate/` before publication. This is the human-readable
  BNF-style rendering: every production, one line each. Read this to answer
  "is _construct X_ accepted, and in what shape?".
- **Syntax diagrams** — `railroad/index.html` + `railroad/diagrams/*.svg`,
  rendered from the same EBNF. Read these for a visual railroad view.

So: **to check whether something is in the grammar, search the DCG or the
EBNF — never infer it from prose.** Prose drifts; those two cannot, because
the gate fails the build if they disagree.

## Entry points (the Prolog API)

Exported from `grammar/dcg.pl`:

| Predicate | Purpose |
| --- | --- |
| `parse_statement/2`     | SQL string → AST term |
| `generate_statement/2`  | AST term → canonical SQL string |
| `roundtrip_term/2`      | parse → generate → parse stability check |
| `statement//1`          | the DCG nonterminal itself |

## AST term vocabulary

The EBNF describes *surface syntax* and deliberately carries no AST shape.
This section is the other half: the term vocabulary `parse_statement/2`
produces and `generate_statement/2` consumes. It is the part most easily
missed by a reader skimming only the production rules.

**Top level** is either a single `select_statement/4` or a left-associative
UNION tree: `a UNION b UNION c` → `union(union(a, b), c)`; `UNION ALL` uses
`union_all/2` likewise. (Non-SELECT statements — UPDATE, DELETE, INSERT,
DROP, CREATE INDEX, ALTER, RENAME, maintenance, IMPORT/EXPORT, transaction
control — have their own top-level functors; see `railroad/grammar.ebnf`
lines for `*_statement` and the corresponding rules in `grammar/dcg.pl`.)

**SELECT** is:

```
select_statement(Distinct, Columns, FromList, Modifiers)
```

- `Distinct` ∈ `{distinct, all_rows}` — `distinct` iff `DISTINCT` was used;
  `all_rows` is the default (DBISAM's `ALL` is accepted as a synonym).
- `Columns` — list of `star` (`*`) or projection items.
- `FromList` — `[table(identifier(Name), Alias), ...]`, `Alias` either
  `no_alias` or `identifier(A)`.
- `Modifiers` — a list of clause functors **in source order** (`[]` for the
  bare form). The full set:

  | Functor | Clause | Notes |
  | --- | --- | --- |
  | `where(Pred)`      | `WHERE`    | |
  | `group_by([..])`   | `GROUP BY` | |
  | `having(Pred)`     | `HAVING`   | **In the grammar.** Accepts any predicate; the engine enforces the GROUP-BY-required and aggregation-context restrictions — see `DIVERGENCES.md` §7. |
  | `order_by([..])`   | `ORDER BY` | |
  | `top(Integer)`     | `TOP n`    | DBISAM places `TOP` last, not after `SELECT`. |

  DBISAM source-order per the Elevate `SELECT_Statement` docs is
  `WHERE → GROUP BY → HAVING → ORDER BY → TOP`.

## Where the rest lives

- **Coverage** (which statements/features are implemented) — `STATE.md`.
- **Doc/engine/disassembly disagreements** — `DIVERGENCES.md`.
- **Sources of truth and how conflicts are recorded** — `REFERENCES.md`
  (repo root).
- **Function catalogue** — `docs/functions.md`.
