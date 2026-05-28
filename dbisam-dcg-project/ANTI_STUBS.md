# Anti-Stubs: Structural Protections Against False Progress

> A test that passes for the wrong reason is worse than a test that fails.
> Failures are visible and get fixed. False passes accumulate silently and
> rot the test suite's credibility. By the time you find them, you don't
> know which other "passes" are also lying.

This project has been bitten before by stubs and "not implemented" placeholders
that made the "tests remaining" counter hit zero while hundreds of cases were
actually empty. This document is the structural defence against that
recurrence. Discipline alone is insufficient — the incentive gradient pushes
toward false greenness under pressure. The harness must make stubs *louder*,
not quieter.

## The fundamental rule

**The grammar does not contain placeholder productions.** Constructs that
aren't implemented don't have rules. Attempts to parse them *fail*, loudly,
with a clear "no rule" outcome. Failing is honest; passing-via-stub is a lie.

Specifically forbidden in the grammar source:

- Atoms like `unimplemented`, `todo`, `tbd`, `stub`, `placeholder`,
  `not_yet_handled`, `raw` appearing as values on the RHS of any production.
- "Catch-all" productions that match arbitrary token sequences with bare `_`
  on the RHS (e.g., `expr(unimplemented) --> [_].`).
- `\+ \+ Goal` or `Goal ; true` idioms in suspicious positions that allow
  silent success.

The anti-stub linter (described below) enforces these mechanically.

## Forbidden in expected terms

- The same placeholder atom list as above appearing in any `expected.term`
  file under a `meaningful` or `expected-divergent` status entry.
- Wildcards (`_`) at positions where a concrete value is required by the
  AST shape.

A `meaningful` entry whose `expected.term` contains a placeholder is a
contradiction. The corpus validator refuses to accept it.

## The status taxonomy is load-bearing

`pending` / `scaffolded` / `meaningful` are not bureaucratic. They are the
mechanism by which incomplete work cannot masquerade as complete work.

- **`meaningful`** — and only `meaningful` — counts as coverage.
- Every other status is visible as such in every report.
- Moving between statuses is governed by checks the harness enforces (see
  the promotion bar in `CORPUS.md`).

## Metrics that resist gaming

Single-number metrics ("X% tests passing") are gameable. The dashboard
exposes a vector of numbers, with deltas per run:

```
meaningful:                   1247  (+3)
scaffolded:                     12  (-1)
pending:                        89  (-1)
expected_divergent:             23  (+0)
quarantined:                     2  (+0)
failing:                         0  (+0)
unclassified_disagreements:      0  (+0)

# Derived
meaningful_pct_of_total:     91.4%  (+0.2)
round_trip_clean:           100.0%  (+0.0)
differential_agreement:      99.7%  (+0.0)
```

A run where `meaningful` doesn't increase but `scaffolded` does is *visibly*
not progress. A run that "fixes" failures by demoting them to `scaffolded`
or `quarantined` is *visibly* sleight of hand.

The loop's success criterion is "`meaningful` increases; nothing else
degrades." Not "tests pass."

## Differential coverage is the main protection

Even with the metric design above, the deepest protection is that
`meaningful` requires *differential agreement with the engine*. A stub
grammar rule that "accepts" anything can't produce an AST term that
round-trips, can't match a specific expected term, and can't survive the
engine cross-check telling the harness what the query actually does.

This is why the engine harness's reliability is non-negotiable. It's the
oracle that makes stubs impossible to disguise. If the engine harness is
broken or unavailable, no entry can promote to `meaningful` — promotion is
blocked, not silently skipped.

## Negative tests are mandatory coverage

Without rejected-construct tests, an over-permissive grammar (or a
stub-grammar that accepts anything) looks identical to a correct one. For
every feature area, the corpus contains both positive tests (constructs
that parse to specific terms) and negative tests (constructs that the
grammar must reject — and the engine must also reject).

`corpus-validate` checks that every `tags` group has at least one negative
test alongside its positive tests, and warns when this ratio degrades.

## Anti-stub linter

A meta-test, runs as part of every harness invocation. Heuristic, intended
to over-flag rather than under-flag — false positives prompt review (good);
false negatives are the failure mode being prevented (bad).

Checks:

1. **Grammar source scan**: forbidden atoms in any production's RHS;
   suspicious always-succeed idioms; productions consisting solely of
   `[_]` or equivalent.
2. **Expected term scan**: forbidden atoms appearing in any
   `expected.term` for entries with status `meaningful` or
   `expected-divergent`.
3. **Wildcard scan**: bare `_` in positions where the AST schema requires
   concrete values.
4. **Round-trip enforcement**: every `meaningful` entry must pass round-trip
   (parse → term → generate → re-parse → same term). The linter doesn't
   run round-trip itself, but checks that the last successful round-trip
   timestamp per entry is no older than the last grammar change.
5. **Negative test ratio**: every feature tag group has at least one
   negative test. Below a threshold (say 1 negative per 10 positive),
   emit a warning.

The linter is a first-class part of CI. Linter failures block builds.
Linter warnings show in the dashboard.

## Pending registry

Sometimes you legitimately want to record "we know about this construct;
we haven't tackled it yet" without having a half-built grammar rule.

That goes in the `pending` status, not in a stub. A `pending` corpus entry
has:

- `query.sql` — the construct
- `meta.toml` — `status = "pending"`, notes explaining what's known
- `engine_verdict.json` — what the engine does with it

But *no* `expected.term` and *no* grammar rule. Pending entries are
counted separately, surface in the dashboard, and constitute a queue of
known-unhandled work. Working on a pending entry means: adding a grammar
rule, authoring the expected term, and running the promotion check —
atomically, in one change. Halfway-done work doesn't get committed as
`scaffolded`; it stays on a branch.

## Quarantine, not deletion

When a previously-`meaningful` entry starts failing for reasons not yet
understood — engine behaviour discovered to differ from previous capture,
grammar bug surfaced by another change — the right move is *quarantine*,
not deletion or demotion to `scaffolded`.

Quarantined entries:

- Are excluded from the active passing/failing count.
- Are counted separately and visibly in the dashboard.
- Carry a `[quarantine]` block in `meta.toml` with reason, date opened,
  and tracking reference.
- Surface as concerning in reports if older than N days (suggested: 14).

This prevents one nasty bug from blocking everything else while preserving
visibility — the bug is *in the report*, not *swept under it*.

## The loop's instruction

Claude Code's iteration loop is instructed not as "make tests pass" but
as:

> Advance the `meaningful` count. Do not allow `scaffolded`, `quarantined`,
> or `failing` to grow. If a change increases `scaffolded` to make `failing`
> shrink, that is not progress — revert and try again.

The harness output every iteration provides the numbers needed to check
this. The success criterion is mechanical, not judgemental.

## Audit trail

Every status change on every entry is recorded with a timestamp in the
entry's `meta.toml` change history (or in a separate `history.log` per
entry if `meta.toml` gets noisy):

```toml
[[history]]
at = "2026-05-22T14:33:21Z"
from = "scaffolded"
to = "meaningful"
by = "claude-code"
reason = "Promotion checks passed."
```

Demotions (`meaningful` → `quarantined`, etc.) are particularly worth
tracking. If a single feature area shows a pattern of meaningful entries
later being quarantined, that's evidence the original work was actually
scaffolding in disguise — and a signal to audit that feature's coverage
more carefully.
