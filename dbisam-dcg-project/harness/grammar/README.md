# Grammar harness

Scryer-Prolog runner for the DCG, paired with a shell driver that
walks the corpus and aggregates per-entry results. The "grammar
harness" of `ARCHITECTURE.md`.

## Files

- `runner.pl` — long-running Scryer-Prolog process. Reads SQL file
  paths one per line from stdin and emits one of `parsed | failed |
  no_grammar | io_error | error(...)` per line to stdout (flushed
  after each). Terminates on EOF or an empty line.
- `run.sh` — driver. Walks the corpus, enumerates entries, pipes
  the path list through a single `runner.pl` invocation, aggregates
  results as JSON to stdout.

## What's not here

The DCG itself. Per `../../ANTI_STUBS.md`, the grammar is structured
so that constructs without explicit rules **fail loudly**, never
pass via a stub. Until slice #5 introduces the first rules, the
`statement//0` DCG predicate is intentionally undefined and every
corpus entry comes back as `no_grammar`. That's the honest signal.

## Run

```
./run.sh
```

Output is JSON:

```json
{
  "summary": {
    "total": 8,
    "parsed": 0,
    "failed": 0,
    "no_grammar": 8,
    "io_error": 0,
    "error": 0,
    "invalid_invocation": 0
  },
  "entries": [ ... ]
}
```

## Speed

One Scryer-Prolog process per harness run, paths piped over stdin,
results read back over stdout in FIFO order. Per-entry parse cost
is sub-ms; the floor is the ~190ms Scryer cold start.

Measured against the current 39-entry corpus:

| Stage              | Time   |
| ------------------ | ------ |
| Pure Scryer pipe   | 219ms  |
| Full `run.sh`      | 696ms  |

The Scryer side scales linearly at ~13ms per entry; projected
~1 second at a 1000-entry corpus.

The `run.sh` bash post-processing currently does one `jq` call per
entry (~10-15ms each), which is the next bottleneck if the corpus
grows past several hundred. A future micro-optimisation is to fold
all entries into a single `jq -s` call. Not blocking for any
forseeable corpus size against `ARCHITECTURE.md`'s "well under a
minute" target.

## ANTI_STUBS compliance

- `runner.pl` contains zero DCG rules — no `statement//` clauses.
- No catch-all productions, no placeholder atoms.
- The undefined-predicate path is the *normal* path here, not an
  exception; the anti-stub linter (when built) should treat
  `existence_error(procedure, statement/2)` as load-bearing, not as
  a warning.
