# grammar

The DBISAM DCG, written in Scryer-Prolog.

## Current scope (slice #5)

- **Lexical**: identifiers (letter/underscore + alnum/underscore),
  integer literals, single-quoted string literals (no escapes yet),
  whitespace.
- **Comments**: NOT implemented. Deferred until a corpus entry
  forces the surface-syntax decision (`--` line? `/* */` block?).
- **Statement**: bare `SELECT <column-list> FROM <table>` only.
  No WHERE, no ORDER BY, no TOP, no UNION, no JOIN, no subqueries —
  each lands in a later slice.

## AST shape

```
select_statement(Columns, identifier(TableAtom))
  where Columns = [identifier(Atom), ...]
```

## Case handling

- Keywords (`SELECT`, `FROM`) are case-insensitive and **structural** —
  they do not appear in the AST.
- Identifiers (column/table names) preserve case as written. So
  `select code from CUSTOMER` and `SELECT code FROM CUSTOMER`
  produce identical AST terms.

## Round-trip discipline

The generator (`generate_statement/2`) emits a CANONICAL form —
uppercase keywords, single spaces, no trailing whitespace.
Generated SQL is therefore NOT byte-equal to the original input,
but re-parsing yields the same AST. This is what CORPUS.md's
"Promotion bar" criterion 3 requires (term-equivalence, not
byte-equivalence).

## Anti-stub compliance

- No placeholder atoms (`unimplemented`, `todo`, `_` in
  load-bearing positions).
- No catch-all productions matching `[_]` or similar.
- Constructs outside this slice's scope (TOP, UNION, WHERE, paren
  projections, UPDATE, …) **have no rule** and will fail to parse.
  The grammar harness reports them as `failed`, the differential
  harness sees they're still `pending` corpus entries, and the
  dashboard correctly does not increment `meaningful`. Future
  slices add the missing rules.

## Files

- `dcg.pl` — single file containing lexical + statement DCGs and
  the canonical generator. Will be split when scope grows; the
  `README.md` in the project root sketches a per-category layout
  for the eventual organisation.

## Public predicates

| Predicate                          | Purpose                       |
| ---------------------------------- | ----------------------------- |
| `statement(-Term)//`               | DCG; parse one statement      |
| `parse_statement(+Chars, -Term)`   | `phrase(statement(T), Chars)` |
| `generate_statement(+Term, -Chars)`| canonical-form emission       |
| `roundtrip_term(+Term, -Term2)`    | generate + re-parse           |
