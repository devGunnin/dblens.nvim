# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.0] - 2026-08-15

First release.

### Added

- Six database engines — SQLite, PostgreSQL, MySQL, MariaDB, DuckDB and SQL Server — driven
  through the command-line client for each, with no compiled component and no server.
- A schema tree, a paged and sortable/filterable result grid, and a SQL scratch buffer with
  schema-aware completion (`omnifunc`, nvim-cmp, blink.cmp), in one tab page.
- Query history and named snippets, `EXPLAIN` / `EXPLAIN ANALYZE` where the server supports it,
  and cell/row editing (edit, insert, delete) with CSV/JSON/INSERT export.
- A record protocol that never confuses a SQL `NULL` with the text `NULL`.
- Safety model: every connection opens **LOCKED** by default, enforced by a server-side read-only
  transaction (or the file's open mode on SQLite/DuckDB) on five of the six engines, and by
  dblens's own classifier — documented as best-effort, not a boundary — on SQL Server. A
  confirmation gate for destructive and, optionally, all writes; a `count(*)` guard proving a
  row-targeted edit matches exactly one row; refusal of known write-capable side channels while
  locked; and guidance to a database read-only role as the only hard boundary.
- Deferred-batch transaction mode with a pending-changes view, committed atomically.
- `:checkhealth dblens`, session restore, a `statusline()` segment, colorscheme-derived
  highlights, and three icon sets (Unicode, Nerd Font, ASCII).
- A single keymap registry driving bindings, the `?` help overlay, and the README/vimdoc tables,
  so none of the three can drift from what is actually bound; every action remappable or
  disable-able per scope through `setup{}`.
- 439 tests (`make test`), a stylua + luacheck lint pass (`make lint`), and CI across Neovim
  stable and nightly.
