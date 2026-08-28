# vendor/

Third-party code, committed verbatim so `node renderer.js` needs no network
or `npm install` (the build environment is offline by design).

## railroad.js

- **Project**: railroad-diagrams by Tab Atkins Jr.
- **Source**: https://github.com/tabatkins/railroad-diagrams (branch `gh-pages`)
- **File**: `railroad.js` (the ES-module build), unmodified.
- **License**: CC0 1.0 (public domain) — see the header inside the file.

The renderer imports the default export (the no-`new` constructor functions)
and feeds it the extracted EBNF IR. To update, re-fetch the same file and
re-run `node renderer.js`; no code change should be needed unless the
library's public API changes.
