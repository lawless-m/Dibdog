# The Loop

How Claude Code should iterate on this project. Read this before starting
work.

## The shape of an iteration

```
   ┌─────────────────────────────────────────────────┐
   │ 1. Read the current dashboard.                  │
   │ 2. Pick a unit of work (see "What to work on"). │
   │ 3. Make a focused change.                       │
   │ 4. Run the grammar harness.                     │
   │ 5. If green, run the differential harness.      │
   │ 6. Check the new dashboard.                     │
   │ 7. If meaningful went up and nothing else       │
   │    degraded: commit. Otherwise: revert and      │
   │    reconsider.                                  │
   └─────────────────────────────────────────────────┘
```

The success criterion is mechanical: did `meaningful` increase, and did
`scaffolded`, `quarantined`, `failing`, and `unclassified_disagreements`
all stay flat or decrease?

If yes: commit, move on.
If no: revert. Do not commit a change that makes the dashboard worse along
any of those axes, even if some specific test went green.

## What to work on

Priority order:

1. **`unclassified_disagreements`** — anything in this bucket blocks builds.
   Triage it first. Each disagreement resolves to either a grammar fix, a
   corpus expected-term fix, or a new entry in `DIVERGENCES.md`.

2. **`failing` tests** — entries previously `meaningful` that now fail.
   Either fix the regression or, if not understood, move to `quarantined`
   with a tracking note.

3. **`pending` entries with `provenance = "product-log"`** — production
   queries that don't yet have grammar support. Highest-value coverage.

4. **`pending` entries with `provenance = "power-bi-observed"`** — Power BI
   query coverage. Critical for the downstream driver use case.

5. **`scaffolded` entries** — these are visible debt. Promote them or
   demote them with a reason.

6. **Other `pending` entries**, prioritised by tag (gaps in feature
   coverage).

Don't pull work from lower priorities while higher-priority items remain.

## Granularity of changes

One conceptual change per commit. Examples of good unit-of-work:

- "Add grammar support for `BETWEEN ... AND ...` expressions."
- "Promote 12 scaffolded `SELECT` projection tests to `meaningful`."
- "Fix grammar's handling of escaped quotes in string literals; resolves
  4 differential disagreements."
- "Document `DIV-0017`: engine accepts comma after final SELECT column;
  grammar rejects. 3 corpus entries marked expected-divergent."

Examples of bad unit-of-work:

- "Improve grammar." (Too vague; impossible to verify.)
- "Make 100 tests pass." (Almost certainly means stubs.)
- "Refactor." (Should be a separate, no-functional-change commit.)

## Forbidden moves

- **Do not add productions to the grammar with placeholder atoms.** See
  `ANTI_STUBS.md`. If a construct isn't yet handled, leave it failing,
  not pseudo-passing.
- **Do not promote entries by editing `status` directly.** Use
  `corpus-promote`, which runs the four promotion checks. If they fail,
  the entry stays where it is.
- **Do not demote `meaningful` entries to `scaffolded`** to make a failure
  disappear. The right move is to fix the failure or quarantine the entry
  with a tracking note.
- **Do not commit grammar changes without re-running the differential
  harness.** Grammar changes can break round-trip on apparently unrelated
  entries.
- **Do not edit the corpus's `engine_verdict.json` files by hand.** They
  are derived; regenerate with `corpus-refresh-verdicts`.

## When stuck

If a disagreement can't be triaged, an expected term can't be authored
confidently, or the engine behaviour is genuinely confusing:

1. Capture the case as a `pending` corpus entry with detailed `notes`.
2. Open a question in `docs/QUESTIONS.md` (a running list of "needs
   human"), citing the entry ID.
3. Move on to the next unit of work.

Do not guess. Pending is honest; guessing produces scaffolded entries that
look meaningful and aren't.

## When the loop slows down

Symptoms that the harness setup needs investment, not the grammar:

- Engine harness queries are slow → check caching, check connection pooling.
- Test failures don't make the cause obvious → improve AST diff output.
- Promoting an entry to `meaningful` requires several manual steps →
  improve `corpus-promote`.
- Triaging disagreements requires reading large terms by eye → improve
  the disagreement triage tooling.

Time spent on tooling pays back across every subsequent iteration.

## End-of-session checklist

Before stopping:

- [ ] `corpus-validate` clean.
- [ ] Anti-stub linter clean.
- [ ] Grammar harness green.
- [ ] Differential harness has no unclassified disagreements.
- [ ] Dashboard committed (so deltas are accurate next session).
- [ ] `docs/QUESTIONS.md` updated with any new uncertainties.

## A note on the engine

The engine is the oracle but it is also a piece of software with bugs and
quirks. When engine behaviour seems wrong, the answer is *still* to match
the engine, because that's what customers experience. Document the
quirk in `DIVERGENCES.md`. Don't "fix" the grammar to be more correct than
the engine — that defeats the entire project.
