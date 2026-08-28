# tools/mcp

An MCP server that exposes the DCG as a SQL checker, so an agent (or a
person) can ask "is this valid DBISAM SQL?" without a Dibdog checkout, a
Scryer install, or knowledge of how to invoke either.

It answers a question the bare grammar cannot: not just *does this
parse*, but *which documented over-accepts does it walk into* — shapes
the DCG admits that the live engine is known to reject.

Deployed at `https://miami.ram-int.uk/dibdog/`; see `DEPLOY.md`.

## The two pieces

```
check.pl     the checker. Scryer + the DCG. Knows nothing about MCP.
src/main.rs  the server. MCP over HTTP. Knows nothing about SQL.
```

The split is deliberate: `check.pl` is usable on its own, and the grammar
work stays in Prolog where the grammar lives.

### check.pl

Parses one statement and reports verdict, AST, canonical regeneration,
round-trip stability, and divergence warnings.

```
scryer-prolog -g main check.pl -- query.sql
```

Output is one `key=value` per line, terminated by a lone `end`; exit 0
accepted, 1 rejected, 2 invocation error.

### Why a process per check

The server runs `check.pl` once per request rather than keeping a warm
long-lived Scryer and feeding it jobs. That costs ~0.3s instead of ~10ms,
and it is a deliberate trade.

A warm worker needs a framed protocol over the child's **piped stdin**,
and Scryer's piped-stdin behaviour is not stable across versions:

```
printf 'abcdefghij' | scryer-prolog -g main readback.pl
  8dffd72d  → [a,b,c,d,e,f,g,h,i,j]
  e3df91e2  → [a,eof]           # one char, then end_of_file

scryer-prolog -g main readback.pl < in.txt
  both      → [a,b,c,d,e,f,g,h,i,j]
```

On the newer build the framed protocol silently desynchronises and every
check degenerates to a cold start anyway. (See mthom/scryer-prolog#1472
for the wider `get_char`/EOF trouble.) Reading the SQL from a *file*
behaves identically on both, and uses the same `phrase_from_file/2` path
as every other tool in this repo.

The point is not that one version is broken. It is that the fast design's
correctness has to be re-established on every Scryer install, on every
machine, forever — and 0.3s is not worth that bet for an interactive
checker. It also removes two footguns the framed protocol had: a required
trailing newline (Scryer's stdin is line-buffered), and a client that
must write raw bytes (a Windows text-mode client sends `25\r\n` as the
count line, which Scryer reads as `['2','5','\r']`).

### The warnings

Four rules, each detecting a shape from `docs/DIVERGENCES.md` that the
grammar accepts and the engine rejects:

| Code | Divergence | Detected by |
| --- | --- | --- |
| `DIV8-CLAUSE-ORDER` | §8 clause ordering | modifiers are held in source order, so it is a subsequence test against WHERE → GROUP BY → HAVING → ORDER BY → TOP |
| `DIV7-HAVING-NO-GROUP` | §7 HAVING restrictions | `having` present, `group_by` absent |
| `DIV6-UNION-IN-SUBQUERY` | §6 UNION asymmetry | bare `union/2` inside an `IN` subselect (UNION ALL is fine there) |
| `DIV3-ARG-TYPE` | §3 type mismatch | all-literal function args whose type shape matches no `function_arg_shape/2` fact |

The schema-dependent divergences (§1 table existence, §2 column belongs
to table) are **deliberately absent**. They cannot be decided without a
catalog, and guessing at them would make the tool untrustworthy in the
one place it most needs to be believed. The server says so explicitly in
its output rather than letting silence read as approval.

## Limits, and why they exist

The cost of a check is driven by **failure, not length** — a failing
parse backtracks:

| input | result | time |
| --- | --- | --- |
| 2784-char real corpus query | accepted | 0.27s |
| 3000-char malformed | rejected | 12s |
| 8000-char malformed | rejected | 172s |

`parse_statement_diag/2` (the furthest-failure position) is separately
about O(n^2.1). Its docstring notes it "runs only on already-rejected
input", which is fine for a local tool but not for a service where the
caller picks the length. Hence three limits:

- `check.pl` skips the position diagnostic above 2000 chars, reporting
  the rejection without a caret. The largest real corpus query is 2785
  chars, so ordinary work never sees this.
- The server caps input at 8192 chars.
- The server times a check out at 30s and kills the Scryer process.

Valid SQL of any realistic size is unaffected.

## The server

MCP over Streamable HTTP: one endpoint, JSON-RPC by POST, answered with
`application/json`. No SSE stream is offered because the server never
pushes — every tool call is strictly request/response, which is the
spec's JSON response mode.

- `GET /` — health probe, no auth, reveals nothing but existence.
- `POST /` — JSON-RPC. Requires `Authorization: Bearer <token>`.

One tool, `check_sql`, taking a single `sql` string.

Configuration is entirely by environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DIBDOG_MCP_BIND` | `127.0.0.1:8791` | bind address |
| `DIBDOG_MCP_TOKEN` | — | bearer token, or… |
| `DIBDOG_MCP_TOKEN_FILE` | — | …a file to read it from |
| `DIBDOG_CHECK_PL` | `check.pl` | path to check.pl |
| `DIBDOG_SCRYER` | `scryer-prolog` | Scryer binary |
| `DIBDOG_MCP_WORKERS` | `2` | request threads |
| `DIBDOG_MCP_ALLOWED_ORIGINS` | — | comma-separated Origins to admit |

The server refuses to start without a token. Tokens never live in repo
files.

By default any request carrying an `Origin` header is refused — the MCP
spec's DNS-rebinding guidance, and ordinary MCP clients are not browsers
and send none. A browser-based client is the exception, hence
`DIBDOG_MCP_ALLOWED_ORIGINS`.
