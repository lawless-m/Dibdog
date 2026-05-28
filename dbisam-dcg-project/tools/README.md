# tools

Project-wide tooling that doesn't fit the per-harness directories.
These are stand-ins for the formal tool surface listed in
`../CORPUS.md` §"Tooling commands".

## `corpus-promote.sh` + `promote-check.pl`

Proto `corpus-promote`. Runs all four CORPUS.md "Promotion bar"
checks for a single entry:

1. `expected.term` contains no placeholder atoms.
2. Grammar parses `query.sql` to a term `==` to `expected.term`.
3. Round-trip (term → generate → re-parse → term) stable.
4. Engine verdict agreement (engine accepts, grammar parses; OR
   both reject — though "both reject" needs a `[divergence]`
   block for honest `expected-divergent` status).

```
./tools/corpus-promote.sh <entry-path>
```

Exit 0 → all four pass; entry is ready for manual `status =
meaningful` in `meta.toml`. The script deliberately does NOT
mutate `meta.toml` — the human authors the audit-trail history
entry alongside the status change so the chain stays honest.

Exit 1 → at least one check failed; details printed.

Exit 2 → invocation error.

## When the formal tools land

These shell/Prolog scripts are minimal but stable. When the full
`corpus-promote` (and friends) ships, this directory either moves
under the canonical tool path or these scripts are deleted —
whichever is cleaner at the time.
