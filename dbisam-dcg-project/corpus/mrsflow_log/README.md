# mrsflow_log — dynamically-harvested corpus entries

Corpus entries captured at runtime from the mrsflow Exportmaster
native client. Distinct from `power_bi_observed/`, which is static
extraction from .pq/.m source files.

## How they got here

`mrsflow_cli::exportmaster::Client::query_raw` (in
`../../../MrsFlow/mrsflow-cli/src/exportmaster/client.rs`) now
checks the `MRSFLOW_SQL_LOG` environment variable. When set to a
file path, every call to `query_raw` appends one JSON line:

```json
{"ts":"<RFC 3339 UTC>","sql":"<the SQL string>"}
```

Any tool that uses the mrsflow Exportmaster native client honours
this — the Dibdog engine harness, `em_smoke`, future mrsflow CLI
invocations against M files. The hook fires AFTER M-language
string concatenation and parameter interpolation, so this is what
the engine actually sees on the wire.

`../../tools/harvest-mrsflow-log.sh <log>` reads such a log file,
deduplicates against the existing corpus, and writes the new
queries as `pending` entries under this directory with provenance
`mrsflow-runtime-log`.

## Versus `power_bi_observed/`

| Aspect                  | power_bi_observed/  | mrsflow_log/        |
| ----------------------- | ------------------- | ------------------- |
| Source                  | .pq / .m files      | runtime log file    |
| Extraction              | grep + dedup        | live capture        |
| Sees concatenation      | no                  | yes                 |
| Sees interpolated params| no                  | yes                 |
| Provenance              | power-bi-observed   | mrsflow-runtime-log |

If a query is harvested both statically AND dynamically, the
runtime harvester skips it (the static entry already exists).

## What's not here

True production workloads — most .pq / .m files in the wild use
`Odbc.Query("DSN=Exportmaster", ...)`, not `Exportmaster.Query(...)`.
Running them through mrsflow on Linux currently fails because there
is no DBISAM Linux ODBC driver. A follow-up task captures the
PQ-to-Exportmaster translator that would let mrsflow run the
original .m files unmodified.

## Status

Initial dynamic harvest (this slice): 16 entries, mostly hand-crafted
DBISAM-construct probes routed through the harness. As the project
grows and more workloads execute against the mrsflow client with
`MRSFLOW_SQL_LOG` set, this directory accumulates real material.
