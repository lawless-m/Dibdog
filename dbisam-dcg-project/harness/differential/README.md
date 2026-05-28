# Differential harness

The orchestrator that turns the engine harness and the grammar
harness into a single project dashboard. The "differential harness"
of `ARCHITECTURE.md`.

## What it does

For every corpus entry: cross-references its cached engine verdict
against a freshly-computed grammar verdict, classifies the result,
and aggregates the dashboard's status vector. Persists the run so the
next invocation can compute deltas.

## Architecture choice: cached vs live engine verdicts

This harness reads `engine_verdict.json` files from the corpus rather
than calling the live engine each run. That matches `CORPUS.md`'s
split:

- **Engine verdicts** are *cached, derived* output. Refresh them via
  `corpus/_schema/refresh-verdicts.sh` (the proto
  `corpus-refresh-verdicts`) — which IS the thing that talks to the
  engine harness.
- **Grammar verdicts** are fast (no IO beyond reading the SQL file)
  and Scryer-deterministic, so they're recomputed every run.

That keeps differential runs fast and means the engine harness
doesn't have to be up to compute the dashboard.

## Run

```
./run.sh                  # default corpus path
./run.sh /path/to/corpus  # explicit corpus root
```

Output is the dashboard JSON to stdout. The same JSON is also
written to `last-run.json` for the next run's deltas.

## Output shape

```json
{
  "counts": {
    "total": 8,
    "meaningful": 0,
    "scaffolded": 0,
    "pending": 8,
    "expected_divergent": 0,
    "quarantined": 0,
    "failing": 0,
    "unclassified_disagreements": 0
  },
  "deltas_since_last_run": {
    "meaningful": "+0",
    "scaffolded": "+0",
    "pending": "+0",
    "expected_divergent": "+0",
    "quarantined": "+0",
    "failing": "+0",
    "unclassified_disagreements": "+0"
  },
  "entries": [ ... ]
}
```

`deltas_since_last_run` is `null` on the first run (no prior state).

## Agreement classification

Per entry, the harness pairs the grammar verdict with the cached
engine verdict:

| grammar         | engine    | agreement                  |
| --------------- | --------- | -------------------------- |
| parsed_match    | accepted  | agreed                     |
| parsed          | accepted  | agreed                     |
| failed          | rejected  | agreed                     |
| parsed_drift    | accepted  | **term_drift**             |
| parsed*         | rejected  | grammar_over_permissive    |
| failed          | accepted  | grammar_bug                |
| no_grammar      | *         | no_grammar                 |
| *               | error     | engine_error               |
| missing         | any       | verdict_missing            |

The grammar harness produces three "parsed" variants:
- `parsed_match` — grammar accepted AND parsed term equals
  `expected.term`.
- `parsed_drift` — grammar accepted BUT the AST shape differs from
  the recorded `expected.term`. This is a runtime regression check
  for CORPUS.md "Promotion bar" criterion 2.
- `parsed` — grammar accepted; entry has no `expected.term` to
  compare against (typically `pending` entries that happen to fit
  the current grammar).

`failing` counts `meaningful` entries with `grammar_bug`,
`grammar_over_permissive`, OR `term_drift` (any state where the
grammar disagrees with the engine or with the recorded expected
term). Entries with a documented `[divergence]` block are NOT
counted as failing.

`unclassified_disagreements` counts **verdict-level** disagreements
(grammar_bug or grammar_over_permissive) that are NOT
`pending`/`quarantined` AND lack a `[divergence]` block.
`term_drift` is tracked separately via `failing` and does not
double-count.

## The metric design (and why)

The dashboard exposes a vector, not a single number, deliberately —
see `../../ANTI_STUBS.md`'s "Metrics that resist gaming". The loop's
success criterion is:

> Advance `meaningful`; do not let `scaffolded`, `quarantined`,
> `failing`, or `unclassified_disagreements` grow.

A run that "fixes" failing by demoting entries to `scaffolded` is
visibly sleight of hand because both numbers move and only one
counts as progress.

## Status today (slice #4)

First dashboard ever produced for this project:

```
meaningful:                   0
scaffolded:                   0
pending:                      8
expected_divergent:           0
quarantined:                  0
failing:                      0
unclassified_disagreements:   0
```

There is no grammar yet (slice #5 introduces the first rules), so
every entry comes back `no_grammar` and nothing has been promoted.
This is the honest zero state. From here, the loop's job is to make
`meaningful` go up.
