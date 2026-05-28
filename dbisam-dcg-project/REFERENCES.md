# References

Three sources of truth feed this project. They disagree. This document
catalogues them and describes how disagreements get recorded.

## The three sources

### 1. The engine (canonical)

The shipped DBISAM binary, the specific version embedded in our product.
When in doubt, the engine wins. This is what customers actually run; this
is what we have to match.

Accessed via the engine harness (`ARCHITECTURE.md`). All engine claims in
the corpus are reproducible by re-running the harness against the same
binary.

### 2. The disassembly

The reverse-engineered native protocol and parser code. Used to explain
*why* the engine behaves a certain way, especially in edge cases the engine
treats as accept-without-clarity or reject-with-cryptic-error.

The disassembly isn't a direct source for grammar rules — translating
disassembled code into a DCG would produce something faithful to *how* the
engine parses, not *what* the language is. The DCG should be the clean
expression of the language; the disassembly is the explanation when the
clean expression is unclear.

Disassembly notes live in `docs/disassembly/` (not included in this initial
bundle; populate from existing reverse-engineering work). They're
human-written observations, organised by topic:

- `docs/disassembly/lexer-numbers.md`
- `docs/disassembly/lexer-strings.md`
- `docs/disassembly/expression-precedence.md`
- etc.

### 3. The documentation

The official DBISAM manuals. Useful as a starting point and for
understanding intent. Not authoritative — the docs are known to disagree
with the engine in places.

Doc references in this project cite section numbers, not page numbers, for
stability across editions.

## Divergences

A divergence is any place where two or three of the sources disagree.
These are recorded in `docs/DIVERGENCES.md` (template included), one
entry per divergence, with stable IDs.

### Divergence entry template

```markdown
## DIV-0001: Trailing semicolons in SELECT statements

**Sources:**
- Docs (§4.3.2): SELECT statements terminated by semicolon.
- Engine: Accepts both with and without trailing semicolon.
- Disassembly (`lexer-statements.md`): Statement terminator is optional;
  end-of-input also terminates.

**Grammar decision:** Accept both. Generate without trailing semicolon
(canonical form).

**Affected corpus entries:** `0042-select-with-semi`,
  `0043-select-no-semi`.

**Status:** Resolved 2026-05-15.
```

### Divergence categories

Useful classifications for triage:

- **Docs wrong, engine right**: Most common. Docs describe an idealised
  language; engine implements something slightly different. Grammar follows
  engine.
- **Docs right, engine quirky**: Engine has a bug or undocumented quirk
  that became de facto behaviour. Grammar follows engine because we have
  to match what the customer's binary does.
- **Undocumented engine feature**: Engine accepts something the docs don't
  mention. Grammar accepts it; we describe it in `GRAMMAR.md`.
- **Documented but rejected**: Docs describe a feature the engine doesn't
  actually implement (probably dropped or never finished). Grammar
  rejects.
- **Ambiguous**: Engine accepts both X and Y syntaxes; docs only mention
  one. Disassembly may explain. Grammar accepts both.

The category goes in the divergence entry. Useful for the dashboard's
divergence inventory view.

## Workflow

When a corpus entry shows grammar/engine disagreement, the triage decision is:

1. Is this a grammar bug? (Grammar should match engine here.) → Fix grammar,
   not a divergence.
2. Is this a known-and-documented divergence? → Mark the entry
   `expected-divergent`, reference the divergence ID.
3. Is this a new divergence? → Add to `DIVERGENCES.md` with a new ID, then
   mark the entry as in (2).
4. Is this a corpus entry whose expected term was wrong? → Fix the expected
   term, not a divergence.

The harness drives this triage but the decision is human. The unclassified
disagreement count in the dashboard must hit zero before a build is green —
every disagreement has been categorised, even if the resolution is "documented
divergence."

## Things to capture from the disassembly work

Worth populating early, because they answer foundational questions:

- The lexical layer: exactly what characters can start an identifier,
  continue an identifier, terminate a number literal, etc.
- The keyword list, including any reserved-but-unused words.
- Operator precedence table as the parser actually implements it.
- The set of statement types the parser recognises (especially DDL and any
  oddities like `SET` statements, `OPTIMIZE`, etc.).
- Error codes and what triggers them (useful for the engine harness's
  reject categorisation).

These don't all need to be done before grammar work starts, but the
foundational ones (lexical layer, keyword list, operator precedence) should
be settled early because they ripple through everything.

## Versioning the references

The engine version is fixed (per `FOUNDATIONS.md`). Doc edition is fixed
to the one shipped with that engine version. Disassembly notes are
versioned in git like any other source.

If a reference itself is updated (we found a clearer disassembly insight,
the doc section number changed because we re-paginated), the divergence
entries citing it get updated too.
