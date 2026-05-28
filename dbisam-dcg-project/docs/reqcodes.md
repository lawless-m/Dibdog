# DBISAM rejection reqcodes — observed catalogue

Every non-accepted DBISAM response carries a `reqcode` in its body
header (u16 LE at offset +1). The engine harness decodes it plus the
Pack-stream payload to surface structured triage data. This file is
the running catalogue of what we have observed and what the layout is.

The wire framing is documented in
`../../MrsFlow/mrsflow-cli/src/exportmaster/response.rs` and the
generic `<u32 LE length><payload>` Pack unit format in `wire.rs`. Per
the response module's comments these reqcodes are the ones the
*server* emits.

## 0x0000 — accepted

Not a rejection. Response carries a cursor-response body. The engine
harness emits `{"verdict":"accepted","bytes":N}`.

## 0x2b02 — table not found

**When**: `SELECT … FROM <name>` where `<name>` is not a table the
engine can find in the current catalog.

**Pack stream layout** (units after the 7-byte body header):

| Index | Content                          |
| ----- | -------------------------------- |
| 0     | empty                            |
| 1     | empty                            |
| 2     | **offending table name** (ASCII) |
| 3+    | trailing empties / u32s          |

**Harness surface**: `{verdict:"rejected", reqcode:"0x2b02", table:"<name>"}`.

**Sample**:
```
sql:       select * from no_such_table
verdict:   {"verdict":"rejected","reqcode":"0x2b02","table":"no_such_table"}
```

## 0x2ead — parse / syntax error

**When**: the engine's parser couldn't make sense of the SQL.
Encompasses missing keywords, unexpected tokens, misspelled
keywords, and bare-SELECT-without-FROM (which DBISAM rejects even
though many other engines accept it for constant scans).

**Pack stream layout**:

| Index | Content                                                       |
| ----- | ------------------------------------------------------------- |
| 0     | empty                                                         |
| 1     | **catalog name** (ASCII, e.g. `NISAINT_CS`)                   |
| 2..4  | empty                                                         |
| 5     | **human-readable error message** (ASCII)                      |
| 6..7  | empty                                                         |
| 8     | u32 LE — error class (`code_a` — provisional mapping)         |
| 9     | u32 LE — 1-based character position in input SQL (`code_b`)   |
| 10+   | trailing empties / u32s                                       |

**Empirical `code_a` values** (provisional, subject to revision as
more rejection shapes come in):

| `code_a` | meaning (best guess)                |
| -------- | ----------------------------------- |
| 1        | Expected X but found Y              |
| 2        | Missing required keyword            |

**Empirical `code_b`**: 1-based byte position of the offending
token in the input SQL. Verified against
`select FOO from CUSTOMER` → `code_b = 8`, which is exactly the
1-based offset of 'F' (`select ` = 7 chars, F at position 8).

**Harness surface**:
```json
{"verdict":"rejected","reqcode":"0x2ead",
 "catalog":"NISAINT_CS","message":"...",
 "code_a":N,"code_b":M}
```

**Samples**:

```
sql:       select from where
message:   Missing FROM in SELECT SQL statement
code_a=2 code_b=1
```

```
sql:       selectt CODE from CUSTOMER
message:   Expected SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER,
           DROP, RENAME, EMPTY, OPTIMIZE, EXPORT, IMPORT, VERIFY,
           REPAIR, UPGRADE, START, ROLLBACK, or COMMIT but instead
           found selectt in SQL statement
code_a=1 code_b=1
```

The "Expected SELECT, INSERT, …" message above is also load-bearing
documentation for the grammar — it's the engine's own canonical
list of top-level statement keywords. Cross-reference against
`FOUNDATIONS.md` / `GRAMMAR.md` when settling the statement
top-level rule scope.

```
sql:       select FOO from CUSTOMER
message:   Expected column name but instead found FOO in SELECT SQL statement
code_a=1 code_b=8
```

**Important nuance**: the "Expected column name but instead found X"
message is **overloaded**. It also fires when `X` IS syntactically
a valid identifier but **isn't a column on the FROM-clause table**.
The engine validates column-table belonging at parse time, not at
execution time. Example:

```
sql:       select code from analysis      ← rejected (analysis has no `code`)
sql:       select code from CUSTOMER      ← accepted (CUSTOMER has CODE)
sql:       select code from product       ← accepted (product has CODE)
```

For DCG purposes this is engine-side schema validation, not a
syntactic constraint. The grammar should accept any identifier
where a column name belongs; rejecting unknown columns is the
engine's job.

This is filed against corpus entry 0205-mrsflowlog-2dbe086603d2.

```
sql:       this is not valid sql at all
message:   Expected SELECT, INSERT, UPDATE, ... but instead found
           this in SQL statement
code_a=1 code_b=1
```

## 0x2b05 — operational rejection during DDL / data operation

**When**: surfaces during `ALTER TABLE ... ADD <col> <type>`,
`CREATE [UNIQUE|NOCASE] INDEX ... ON ...`, `CREATE INDEX ...` and
similar DDL statements where the SYNTAX parses successfully but the
engine refuses to perform the operation. In our test environment
this fires when the target table doesn't exist or when the table
is in a state that disallows schema mutation (e.g., a SELECT-INTO
temp table).

**Pack stream layout**: not yet decoded; the harness emits just
`{verdict:"rejected", reqcode:"0x2b05"}` with no further detail.

**Sample**:
```
sql:       alter table no_such_canary add newcol integer
verdict:   {"verdict":"rejected","reqcode":"0x2b05"}
```

The distinction vs 0x2b02 (table-not-found at SELECT time) is that
0x2b05 fires for DDL operations on tables that may or may not
exist — the parse always succeeds, the schema operation gets
attempted, and only then does the engine surface a reqcode based on
whatever stopped it.

**See also**: `corpus/ddl/alter_table/0100-alter-table-add-column/`,
`corpus/ddl/create_index/0100-create-index-basic/`,
`corpus/ddl/create_index/0101-create-index-unique/`,
`corpus/ddl/create_index/0102-create-index-nocase/`.

## 0x2c18 — operational rejection during RENAME or maintenance

**When**: surfaces during `RENAME TABLE ... TO ...` and the
maintenance commands `OPTIMIZE TABLE`, `VERIFY TABLE`, `REPAIR
TABLE`, `UPGRADE TABLE` when the target can't undergo the requested
operation (typically: doesn't exist, or is in an exclusive-lock
state).

**Pack stream layout**: not yet decoded.

**Sample**:
```
sql:       RENAME TABLE no_such_a TO no_such_b
verdict:   {"verdict":"rejected","reqcode":"0x2c18"}
```

Both 0x2b05 and 0x2c18 are operational-error codes — they live in
the 0x2bxx / 0x2cxx ranges which appear to be the engine's
"can't-do-the-thing" channel, separate from the 0x2eXX parse-error
range that covers true syntactic rejection.

**See also**: `corpus/ddl/rename_table/0100-rename-table/`,
`corpus/ddl/maintenance/0101-optimize-table/`.

## Reqcodes not yet observed

We have not yet seen the engine emit anything other than 0x0000,
0x2b02, 0x2b05, 0x2c18, 0x2ead in normal corpus exercise. There are
presumably others — column-type mismatch, transaction-state
violation, constraint violation, lock contention, etc. Add them
here as the corpus grows and the harness encounters them. The
harness's default branch (unknown reqcode) returns just the bare
`reqcode` field — no decoder is wrong; future entries get richer
detail as their layouts are documented.

## Relationship to mrsflow's `response.rs` constants

`response.rs` documents three "cursor result codes" inside an
accepted response's Pack stream (`RESULT_OK 0x0000`,
`RESULT_NOT_READY 0x0003`, `RESULT_END_OF_CURSOR 0x2202`) plus one
server-pushed sentinel (`REQCODE_POLLING_SENTINEL 0x2C14`). Those
are **distinct** from the rejection reqcodes catalogued here — they
appear inside the body of an accepted (`reqcode = 0x0000`) response,
not as the body header's reqcode itself.
