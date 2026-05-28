# Engine harness

HTTP/JSON wrapper around the live DBISAM engine. The "engine harness"
described in `dbisam-dcg-project/ARCHITECTURE.md`.

## What it does

Single endpoint that takes a SQL string and returns a structured
accept/reject/error verdict, sourced from the real DBISAM server via
the MrsFlow native client (`mrsflow_cli::exportmaster::Client`).

This is the project's **oracle** — the thing the differential harness
compares grammar decisions against.

## Build

```
cargo build --release
```

Depends on `../../../../MrsFlow/mrsflow-cli` (path dep). Requires the
`exportmaster` Cargo feature, which pulls in `blowfish`, `md-5`, `cbc`,
`flate2`. No system libraries needed.

## Run

```
DIBDOG_EM_HOST=rivsem04 \
DIBDOG_EM_USER=<user> \
DIBDOG_EM_PASS=<pass> \
./target/release/dibdog-engine-harness
```

Listens on `127.0.0.1:38120` by default. Override with `DIBDOG_HARNESS_BIND`.

**Credentials policy**: never put them in any file in this repo. The
binary reads them from env vars at startup. Local shell history is OK;
files that go to GitHub are not.

## Endpoints

### `GET /health`

```
{"ok":true,"target":"<hostname>"}
```

### `POST /verdict`

Request:
```
{"sql":"select count(*) from product"}
```

Response is one of:

```
{"verdict":"accepted","bytes":<N>}

{"verdict":"rejected",
 "reqcode":"0x<XXXX>",
 "table":"<offending-table>"        # 0x2b02 only
 "catalog":"<catalog>",              # 0x2ead only
 "message":"<engine error message>", # 0x2ead only
 "code_a":<u32>,                     # 0x2ead only — likely error class
 "code_b":<u32>}                     # 0x2ead only — likely 1-based char pos

{"verdict":"error","detail":"<infrastructure failure>"}
```

`bytes` on the accepted path is the size of the raw response body —
a coarse sanity check, not authoritative row-count.

The rejection-shape fields are decoded from the DBISAM response
Pack stream — see `../../docs/reqcodes.md` for the full catalogue of
known reqcodes and unit layouts.

## How accept/reject is decided

The DBISAM native protocol embeds engine rejections **inside** the
response body, not at the transport layer. `query_raw` returns
`Ok(bytes)` for both accepted and rejected SQL — the difference is
the body header's `reqcode` field (u16 LE at offset +1):

- `0x0000` — accepted; cursor response follows
- `0x2b02` — rejected; "table not found" (decoded → `table` field)
- `0x2ead` — rejected; parse / syntax error (decoded → `catalog`,
  `message`, `code_a`, `code_b` fields)
- (other non-zero values exist; treated as rejected with only the
  bare `reqcode` field surfaced until their layouts are catalogued)

See `mrsflow-cli/src/exportmaster/response.rs` for the body header
layout, `mrsflow-cli/src/exportmaster/wire.rs` for the Pack-stream
walker, and `../../docs/reqcodes.md` for the rejection catalogue.

## Smoke test

```
./smoke.sh
```

Hits both endpoints with a fixed query matrix. Expected output is
recorded in `smoke.expected.txt` for diffing.

## Known issues

- **Stale buffer bleed across queries**: after a rejection, the next
  query can read residual bytes from the prior response. Observed:
  an INSERT-into-nothing query coming back with `0x2b02` and a
  payload referencing the *previous* query's offending table name.
  The harness mitigates by dropping the client and reconnecting after
  every non-accepted response. Upstream fix to mrsflow's cursor
  cleanup would let us keep the connection across rejections. Not
  blocking for the DCG project's needs.
- **No DML transaction wrap yet**: per ARCHITECTURE.md, mutable
  queries should run inside a savepoint that's rolled back. Currently
  every query is sent as-is. Safe enough for SELECT-only corpus work;
  must be added before DML enters the corpus.
