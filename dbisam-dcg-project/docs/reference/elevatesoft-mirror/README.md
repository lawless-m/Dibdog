# Elevate Software DBISAM SQL Reference — local mirror

Snapshot of the public DBISAM SQL Reference, hosted by Elevate Software.

- **Source**: https://www.elevatesoft.com/manual?action=topics&id=dbisam4&product=delphi&version=5&section=sql_reference
- **Edition**: DBISAM v4, Delphi v5 manual.
- **Captured**: 2026-05-26.
- **Method**: `wget`, one HTML file per topic, fetched from the section TOC.

## Files

- `index.html` — the SQL Reference table of contents.
- `<Topic_Name>.html` — one per topic listed in the TOC (26 in total).

Filenames mirror the `topic=` query-string parameter from the source URL, so
`SELECT_Statement.html` corresponds to
`...&action=viewtopic&topic=SELECT_Statement`.

## Status — NOT authoritative

This is the **documentation** leg of the three sources of truth in
`../../REFERENCES.md`. The docs are **known to disagree with the engine**
in places. When the docs and the live engine differ, the engine wins —
see `REFERENCES.md` §"Divergences" for how to record those.

Treat this mirror as the starting point for "what the language is *supposed*
to look like", not as ground truth.

## What is *not* mirrored

The SQL-reference topic pages cross-link to ~14 topics in other sections
of the DBISAM manual: e.g. `transactions`, `executing_sql_queries`,
`creating_altering_tables`, `encryption`, `data_types_null_support`,
`full_text_indexing`, `index_compression`, `buffering_caching`,
`dbisam_architecture`. Those are outside the SQL Reference section and were
not mirrored here. Pull them in individually if a divergence triage needs
them.

## Refreshing

To re-snapshot, see the wget invocations in commit history, or fetch
`index.html` again, extract the `topic=` parameters, and fetch each
`action=viewtopic` URL.
