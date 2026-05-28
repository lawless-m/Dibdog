# Corpus

The accumulated knowledge of DBISAM SQL behaviour: every query the
project has seen, what the engine does with it, what the grammar
does with it, and where they agree or differ.

The authoritative spec for this directory is `../CORPUS.md` (entry
shape, status taxonomy, promotion bar, provenance categories,
tooling commands). This file is the operational sketch.

## Layout

```
corpus/
├── select/{basic, joins_comma, joins_explicit, subqueries}/
├── dml/{insert_values, insert_select, update, delete}/
├── ddl/{create_table, drop_table}/
├── expressions/{precedence, functions}/
├── rejected/syntax_errors/
├── product_log/
└── _schema/        meta about the corpus itself
```

## Entry shape

Each entry is a directory `corpus/<area>/<sub>/<NNNN-slug>/` containing:

- `query.sql` — the SQL string, plain text.
- `meta.toml` — id, status, provenance, tags, notes, fixtures.
- `engine_verdict.json` — derived by the engine harness; do not
  hand-edit.
- `expected.term` — present once status reaches `scaffolded` or
  later; not present for `pending`.

## Seed corpus (this slice)

Eight `pending` entries — five hand-written plus three from a real
production query (a UNION, contributed by the user, split into the
full form plus its two reductions):

| ID | Path | Provenance | Behaviour |
|----|------|------------|-----------|
| 0001-simple-projection             | select/basic            | manual         | accepted (canary) |
| 0002-update-empty-match            | dml/update              | manual         | accepted — no real mutation |
| 0003-syntax-error-bare-from        | rejected/syntax_errors  | manual         | rejected (0x2ead) |
| 0004-select-top-n                  | select/basic            | manual         | accepted — DBISAM-specific TOP placement |
| 0005-paren-projection              | select/basic            | manual         | accepted — round-trip-tricky |
| 0006-repterr-union-quotes-orders   | product_log             | product-log    | accepted (FLAKY — see entry notes) |
| 0007-repterr-quotes-half           | product_log             | reduced-from-0006 | accepted |
| 0008-repterr-orders-half           | product_log             | reduced-from-0006 | accepted |

All eight are `status = pending`. They become `scaffolded` once a
grammar rule attempts to parse them, and `meaningful` only after
passing the four promotion checks in `../CORPUS.md` ("Promotion bar").

## Engine verdict capture

Verdicts are captured via the engine harness at
`../harness/engine/`. See that directory's README for how to run it
and what shape the responses take. Once `corpus-refresh-verdicts`
tooling exists (per `../CORPUS.md`'s "Tooling commands"), it will
re-run the harness against every entry and refresh
`engine_verdict.json` files whose `engine_version` is stale.

Today (this slice) verdicts are captured via
`_schema/refresh-verdicts.sh`, a stand-in for the eventual
`corpus-refresh-verdicts` tool listed in `../CORPUS.md`. The
harness's structured-detail capture (engine error code, error
message, rows affected) is task #7 in the project's task list and
is not yet wired up — verdicts captured this session leave those
fields null.

### Order-dependence caveat

Engine verdicts are presently NOT deterministic across runs.
`ARCHITECTURE.md` calls determinism non-negotiable; we don't have
it yet. Observed: the same SQL string can return `accepted` or
`rejected` depending on what queries preceded it in the same
harness run, even with per-query reconnect on the client side.
The DBISAM server appears to retain cross-connection session state
that survives client logout/login. Root cause and fix tracked in
task #8 (upstream mrsflow cursor cleanup); the most flaky entry in
this seed corpus is 0006 (the full UNION) which is annotated with
the `engine-verdict-flaky` tag.

Until task #8 is resolved, do not promote `pending` entries to
`scaffolded` based on `engine_verdict.json` alone — re-probe the
specific entry against a known-clean harness state first.
