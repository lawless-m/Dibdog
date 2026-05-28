# Architecture

The project consists of the grammar and three distinct harnesses. Keeping the
harnesses separate is a deliberate choice: they have different failure modes,
different speeds, and answer different questions. Combining them confuses
diagnosis.

## The three harnesses

### Grammar harness

**Question answered:** does the DCG do what we expect?

**Inputs:** SQL strings (from the corpus), expected outcomes (parse to term /
reject).

**Outputs:** pass / fail per test, with structural diff on failure.

**Dependencies:** Scryer-Prolog and the grammar. Nothing else. No database,
no network.

**Speed target:** full corpus run in well under a minute. This is the harness
Claude Code hammers repeatedly; it must be fast.

**Failure clarity requirement:** on mismatch, output should point at the
specific divergence between expected and actual term, not just dump both for
visual diff. The harness knows the AST shape and should use that knowledge.

### Engine harness

**Question answered:** what does DBISAM actually do with this SQL?

**Inputs:** SQL strings.

**Outputs:** structured verdict — `accepted` (with rows affected), `rejected`
(with error code, error message, position if available), or `error`
(infrastructure problem distinct from SQL rejection).

**Dependencies:** the live DBISAM engine, the native Rust client wrapping it.

**Implementation:** the native client exposes a small HTTP endpoint
(JSON request / JSON response) so it's callable from Prolog, shell, and any
other tool. Long-lived connection inside the wrapper; per-request overhead
minimised.

**Speed target:** ~1ms per query against a warm cache, ~20ms uncached. Cache
keyed on `(sql_string, engine_version)`; invalidate on engine version change.

**State management:** every query against a mutable test database runs inside
a transaction or savepoint that's rolled back, so test ordering doesn't
matter. Read-only queries skip the wrap for speed.

**Reliability requirement:** this is the project's oracle. Flakiness here
poisons everything downstream. The harness must be unambiguous about
infrastructure failures versus engine verdicts. "Couldn't connect to engine"
is not the same as "engine rejected the query", and conflating them creates
spurious divergences.

### Differential harness

**Question answered:** do the grammar and the engine agree?

**Inputs:** corpus entries.

**Outputs:** for each entry — agreement (both accept / both reject), or
disagreement (one accepts and the other rejects), categorised.

**Dependencies:** both other harnesses.

**Disagreement categories (computed):**
- **Grammar bug**: grammar rejects, engine accepts. Almost always means a
  missing or incorrect grammar rule.
- **Grammar over-permissive**: grammar accepts, engine rejects. The grammar
  is too loose somewhere.
- **Expected divergence**: marked as such on the corpus entry, with reference
  to `DIVERGENCES.md`. Counted but not reported as a failure.
- **Unclassified**: a new disagreement requiring human triage.

**Triage workflow:** unclassified disagreements are presented for human
decision: is this a grammar bug to fix, a divergence to document, or a
corpus entry whose expectation was wrong?

**Speed target:** full corpus in under five minutes, dominated by engine
queries. Cached aggressively.

## How they compose

The grammar harness runs constantly during development — every grammar edit
should be followed by a grammar-harness run. Sub-minute.

The differential harness runs less often — at the end of a work session, or
when claiming a corpus entry has been promoted from `scaffolded` to
`meaningful`. Promotion requires passing differential agreement.

CI runs all three. The differential harness's "unclassified disagreements"
count must be zero for a build to be green — every disagreement is either
fixed or documented.

## What lives where

```
harness/
├── grammar/         Prolog-side test runner, AST diff, reporting
├── engine/          Rust wrapper around the native client, HTTP server
└── differential/    Orchestrator that calls both and compares
```

The grammar harness is Prolog. The engine harness is Rust. The differential
harness can be either; Prolog is fine since it talks to engine over HTTP and
already speaks the AST.

## Determinism

Every harness produces byte-identical output for byte-identical input. No
timestamps in test output (or stable timestamps in a separate metadata
stream). No random iteration order. No hash-map ordering leaks. This is
non-negotiable because it's the foundation of "did my change improve
things or not?" — and that's the question Claude Code needs to answer every
loop iteration.

## Reporting format

Every harness run produces structured output in addition to human-readable
output. Structured output drives the dashboard described in `ANTI_STUBS.md`:

```json
{
  "meaningful": 1247,
  "scaffolded": 12,
  "pending": 89,
  "expected_divergent": 23,
  "failing": 0,
  "unclassified_disagreements": 0,
  "deltas_since_last_run": {
    "meaningful": "+3",
    "scaffolded": "-1",
    "pending": "-1"
  }
}
```

A run where `meaningful` doesn't move but `scaffolded` does is visibly
not progress. The metric design makes inflation impossible to disguise as
work.

## REPLs and exploratory tools

Beyond the test harnesses, two interactive tools matter:

- A wrapper around the engine harness for ad-hoc query exploration: "what
  does the engine think of this?"
- The Scryer REPL with the grammar pre-loaded, plus a pretty-printer for AST
  terms: "what does the grammar think of this?"

Both should be one command to invoke and use the same caches and config as
the test harnesses.
