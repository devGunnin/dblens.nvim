# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.4.0] - 2026-08-15

### Added

- **A connections manager.** `:DbLensConnections` (`<leader>dc`) is no longer just a picker: it
  lists every connection dblens knows about with its engine, target, LOCKED/EDIT default, where
  its password comes from, and whether it could be opened RIGHT NOW. A flagged row carries the
  reason under it — `$PGPASSWORD_PROD is not set`, a host with the port glued on, whatever
  validation refused. `<CR>` connects, `e` edits, `dd` deletes after a confirmation, `a` adds,
  `D` runs discovery, `R` re-checks. The health check resolves the REFERENCE and never opens the
  database; a `password_cmd` is deliberately not run for it (running one to draw a list could
  raise a passphrase prompt), so those rows report as unchecked and are proved on connect.
  Deleting removes the connection from the file, drops a live session on it and clears the saved
  session, so it cannot be restored back into existence.
- **Hiding, instead of losing the session.** `q` in any dblens window and `<leader>dd` toggling
  off now HIDE: the windows go and your layout comes back, the instance stays. Toggling on again
  re-shows the same connection and mode, the same tree expansion, every result tab with its
  filter, sort, search and page, and the SQL buffer as you left it — the same buffers, no
  reconnect, no second UI. A query running when you hide keeps running and its rows land in their
  tab. `:DbLensClose` is now the deliberate teardown, and leaving Neovim still releases
  everything.
- **Editing a saved connection** (`e` in the manager): the add form's questions, answered with
  what the connection holds today, written back in place. It reaches an entry validation refuses
  as well as a usable one, because that is the entry that needs fixing.

### Fixed

- **A misconfigured connection no longer errors on every start.** A connection whose secret
  cannot resolve, or whose config is malformed, is now skipped with ONE quiet, dismissable line
  naming the reason and pointing at the manager — never an error on every open, and never during
  session restore. A saved session naming a connection that no longer exists is simply nothing to
  restore, silently. Connections the loader refuses are reported as one line ("2 connections need
  attention"), not one error each. Secrets are resolved only when actually connecting; the
  manager's health flag resolves the reference to a boolean and surfaces no error.
- **An entry the loader refuses can be seen and deleted.** It used to be dropped from the list
  entirely: not listed, not connectable, not removable by name, and shouting on every start. It
  is now listed with its reason, editable and deletable — and deleting or adding a connection
  leaves every other stored entry byte-for-byte as it was, instead of quietly dropping the ones
  that failed validation.
- **The add form refuses the mistake that caused this.** A host typed as `host:port` is split
  into host and port (and a host that disagrees with a separately given port is refused);
  `password_env` must be a variable NAME, so `.env` is refused with what to do instead (a `.env`
  FILE is `:DbLensDiscover`'s input) and so is a password typed as a value; read-only is the
  first and default access answer, and anything but an explicit read-write choice leaves the
  connection LOCKED.

### Security

- Unchanged where it counts: a discovered connection is still session-only and is now REFUSED by
  the store rather than silently skipped, a password value is still never written to disk, the
  manager shows a password's SOURCE and never its value, the connections file is still written
  `rw-------`, and the argv option-injection defenses are untouched. The file writer additionally
  refuses to rewrite a connections file that holds a plaintext password, rather than authoring
  one itself.

## [1.3.0] - 2026-08-15

### Added

- **Discovery reads project-prefixed `.env` variable groups.** A group is recognised under
  whatever prefix a project puts on it, not only the bare `PG*` / `MYSQL_*` names:
  `TACTICA_POSTGRES_DB` / `_USER` / `_PASSWORD` is one connection, and a standalone
  `TACTICA_DB_PORT` is the port it answers on here — the shape almost every Python and Django
  repository has, and one that produced nothing usable before. The generic `<P>_DB_*` and
  `<P>_DATABASE_*` spellings are read the same way, several prefixes in one file are several
  connections, and a group is deduplicated against a URL describing the same host, port and
  database. Nothing is invented: an absent host is `localhost`, an absent port the engine's
  default, a group naming no database is not a connection, and a group whose variables name no
  engine is offered only when a URL beside it or a port only one engine uses says which it is.
- **Driver-suffixed and `jdbc:` URL schemes.** `postgresql+psycopg`, `postgresql+psycopg2`,
  `postgresql+asyncpg`, `mysql+pymysql`, `mysql+mysqldb`, `mariadb+pymysql`, `mssql+pyodbc`,
  `cockroachdb+psycopg` and `sqlite+pysqlite` are reduced to the engine they name, and a leading
  `jdbc:` is stripped and the rest read by the ordinary rules. A driver-specific spelling
  (`jdbc:sqlserver://host;databaseName=x`) yields no database and is dropped by validation rather
  than turned into an invented target.
- **A URL pointing at a compose service now also offers the connection this machine can reach.**
  `postgresql+psycopg://postgres:postgres@db:5432/tactica` names a host only a sibling container
  can reach; when the same file publishes a host port for it, the `localhost` candidate is offered
  beside it, and the provenance line tells them apart. Both are offered — only the user knows
  whether the stack is up.
- **Multi-column sorting in the grid.** `s` still cycles the column under the cursor ascending →
  descending → unsorted and replaces the whole sort; `S` ADDS that column as the next sort key,
  cycling and then dropping that one key while leaving the others in place; `gs` clears them all.
  The header marks every key with an arrow (ASCII with `ui.icons = false`) and, once there is more
  than one, its position, and the winbar lists the keys in order. It is one server-side `ORDER BY`
  built by the existing paging path, every column name quoted by the dialect, and any change
  re-reads from page 1 so the page on screen still means what it says. Sort, filter and paging
  compose into one statement, and an export still carries the grid's whole sort.

### Security

- A password read out of a prefixed group is treated exactly like one from a `DATABASE_URL`: held
  in memory for the session that found it, never written into a spec and never persisted. The
  discovery model is unchanged — no auto-connect, discovered connections open LOCKED, nothing
  found is executed, and the argv and quoting defenses are untouched.

### Changed

- `sql.page`'s `order_by` is a LIST of `{ column, desc }` keys rather than a single key. Internal
  API; the mssql builder now shares `common.order_keys` with the other engines instead of
  repeating it.

## [1.2.0] - 2026-08-15

### Added

- **Foreign-key navigation** (`gf` in the grid): follow the cell under the cursor to the row it
  references. The target comes from `column.fk`, which every adapter already fetched and three
  views already displayed; nothing was navigating it. The referenced table opens filtered to the
  referenced row, with `<- table.column` in the winbar saying where the view came from. A NULL
  cell references nothing and says so, a column carrying several references asks which, and a key
  spanning several columns follows the one under the cursor and states that it did. It is a read
  throughout: the predicate is built and quoted here, and the row is fetched by the same paged
  SELECT a browse uses.
- **Reverse foreign-key navigation** (`gF` in the grid): the rows in OTHER tables whose foreign key
  points at the row under the cursor. `fk.referencing` inverts the same metadata `gf` reads,
  through the same resolution rules, so a relationship is described in one place. The columns of
  tables the tree never expanded are read first, which is what makes "no loaded table references
  this" mean it; several referencing tables ask which one, a composite key matches on its own
  column and says so, and a NULL key or a table with no single-column primary key is reported
  rather than guessed at. A read like `gf`: the key value reaches the WHERE through the same
  per-dialect quoting as `F`.
- **Several results open at once.** `t` in the tree opens a table in a new result tab,
  `<localleader>t` in the editor runs a statement into one, and `gt` / `gT` / `gc` / `gl` step,
  close and list them; the winbar names the open results once there is more than one. Each tab
  owns its whole view — result, filter, sort, search, page — AND its own race guard: a query
  started in one tab lands in that tab whatever is on screen when it finishes, and two queries
  completing out of order cannot cross. Closing a tab stops what it was running; closing the last
  one empties it. `ui.results.max_tabs` (default 8) caps them, because each holds a whole result.
- **Format the SQL buffer** (`<localleader>f`, visual mode for the selected lines, or
  `:DbLensFormat` with or without a range). dblens does not format SQL itself: it hands the text
  to `sqlfluff`, `pg_format` or `sqlformat` — detected in that order, or whatever `format.command`
  names as an argv ARRAY — spawned directly with the SQL on stdin. No shell, no session, no
  client, so the formatter can only reprint the text, never run it. The buffer is replaced only on
  success; a formatter that fails, times out or prints nothing leaves it alone and says why, and
  with none installed the message names what to install.
- **Import a CSV into a table** (`I` in the tree, or `:DbLensImport`). EDIT mode only: a LOCKED
  connection is refused before a file is even asked for. The path is expanded without any shell,
  the file is parsed by dblens to RFC 4180 (quoted fields, embedded commas, newlines and doubled
  quotes), and CSV columns are matched to table columns by header name — a name the table does not
  have is refused, never dropped or guessed at. Every value becomes a quoted literal, so a cell
  holding `'); DROP TABLE x;--` is imported as that string. The row count, the mapping and a
  sample of the generated `INSERT`s are confirmed first, and the run is ONE transaction: if any
  row fails, nothing is imported and the failing row is named. `import.max_rows` and
  `import.max_bytes` refuse rather than importing part of a file.
- **Filter from the cell under the cursor**: `F` filters to it, `!` filters it out, `C` clears the
  filter. The value is quoted for the dialect by the same helpers the CRUD statements use and the
  predicate then goes through the same `check_predicate` vetting as a typed one — a cell holding
  `'; DROP TABLE t; --` is compared as data. A NULL cell gives `IS NULL` / `IS NOT NULL`.
- **Jump to a page**: `[P` first, `]P` last, `gp` to a number. `paging.goto_page` had been written
  and asserted since 1.0 with no caller and no key. The last page needs the row count and says so
  when it does not have one yet.
- **Run straight from the history and snippet pickers**: `<C-r>` (or `<C-CR>`) runs the selected
  statement, `<CR>` still puts it in the editor. It runs through `app.run_sql`, so a stored write
  on a LOCKED connection is refused and a destructive one still confirms, exactly as if typed.
- **Export a whole table from the tree** (`X` in the sidebar), and **`.sql` INSERT statements** as
  a third export format beside CSV and JSON, generated by the same `mutate.insert_text` that
  "yank row as INSERT" uses.
- **Search inside the loaded result**: `g/` highlights every matching cell, `gn` / `gN` step
  through them and the winbar shows `1/17`. Matching is over the underlying values, so a hit
  inside a value the grid clipped at `ui.grid.max_col_width` is found — which the buffer's own `/`
  cannot do, because it only ever sees the drawn text.
- `export.max_rows` (default 1,000,000): the bound on a streamed export. It becomes the `LIMIT` of
  the one statement the export reads with, so the file is one snapshot of the table.
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

### Changed

- **Export writes the whole result, not the page on screen.** `X` in the grid re-reads a browsed
  table with its filter and sort applied and streams it to the file, so the row count in the
  notification is the row count in the file. Rows are written to a temp file beside the target and
  renamed into place only once the run completed, so a cancelled (`<C-c>`) or failed export leaves
  whatever was there before untouched, and an existing file is confirmed before it is replaced.
- **A table export is ONE statement in ONE client invocation**, so the file is a consistent
  snapshot rather than a stitch of separate reads, and it is bounded by that statement's `LIMIT`
  instead of by `max_bytes` — a result larger than the client byte cap now exports rather than
  being killed part-way. `Session:stream` is the new path: the client's output is decoded and
  written as it arrives, so nothing holds the result in memory. A sort is completed by the primary
  key, so rows that sort equal come out in the same order every time.
- **An export format is no longer guessed with a silent CSV fallback.** `.csv`, `.json` and `.sql`
  are recognised; anything else is an error naming the three, instead of a `.tsv` quietly written
  as CSV.
- The `?` overlay does not fit an 80x24 screen in any pane — the grid lists 44 bindings and even
  the sidebar's list outgrows the 18 rows that size leaves. It scrolls there (`j`/`k`), the footer
  says so, and nothing is dropped or cut off the right edge. It fits from about 100x33.
- **A CSV export quotes the empty string and leaves NULL empty.** Both were written as an empty
  field, so a table holding `''` came back from its own export as NULL. Quoting is the only thing
  that tells the two apart in CSV — the convention sqlite3, psql and `COPY ... CSV` follow, and
  what the new import reads back, so a table exported and imported into a fresh one is the same
  table.
- **A filter is refused for a backslash only where a backslash may escape.** MySQL and MariaDB read
  one inside a literal differently depending on `NO_BACKSLASH_ESCAPES`, which dblens cannot see, so
  the refusal stands there. SQLite, PostgreSQL, DuckDB and SQL Server have no such escape, so `F`
  on a Windows path or a regex now filters instead of being refused for a reason that did not
  apply. A bare backslash outside a literal is still refused everywhere — that is psql's `\!`.

### Fixed

- **A CSV cell could execute SQL on PostgreSQL, and the import reported success.** Literals were
  quoted by doubling `'` and leaving `\` alone, which is correct only while the server has
  `standard_conforming_strings = on` — a per-database/role setting dblens never read, and every
  run spawns a fresh `psql`. With it off, a cell ending in `\` escaped its own closing quote and
  the rest of the row was parsed as SQL: proved live on 16.15, where a cell holding
  `\'); DROP TABLE victim; --` DROPPED the table and the user was told `imported 1 row(s)`.
  Literals are now written per engine so no server setting can re-frame them: `E'…'` with both
  `\` and `'` escaped on PostgreSQL and DuckDB, where that syntax means one thing in either mode;
  `'…'` with `\` doubled on MySQL/MariaDB, whose adapter now CLEARS `NO_BACKSLASH_ESCAPES` from
  the session `sql_mode` rather than assuming it is unset; `'…'` doubling `'` only elsewhere. The
  PostgreSQL adapter also pins `standard_conforming_strings=on` on every connection, not just
  locked ones. One quoter backs filter-from-cell, `gf`/`gF`, grid cell edits, CSV import and
  `.sql` export, so all of them carried it and all of them are fixed. A hostile-value × engine ×
  escaping-mode matrix now judges every emitted literal with an independent decoder, and the
  round trip is proved live on PostgreSQL with the setting both ON and OFF, on MySQL and MariaDB
  with `NO_BACKSLASH_ESCAPES` both set and clear, and on SQLite and DuckDB.
- **`gf` and `gF` wrote their result into whatever tab was on screen.** Both have to load
  metadata before they can build a predicate — the target table's columns for `gf`, every loaded
  relation's for `gF` — and both then read the active tab at that moment. Switching tabs during
  the round trip replaced the tab switched TO and left the tab the key was pressed in untouched,
  contradicting the per-tab guarantee stated here and in `:h dblens-results`. The initiating tab
  is captured at the keystroke and passed through, as every other async path already did; a
  navigation whose tab has since been closed is dropped instead of fetching for it.
- **A NUL byte in a CSV gave a raw traceback and no message.** It flowed past `csv.parse` to an
  assertion inside a scheduled callback, so the import failed with nothing the user could read.
  It is refused at the file boundary now, naming the line like the other parse errors.
- **An import numbered the failing row two different ways.** A queue-time failure named the file
  row, a commit-time one named the queue ordinal (one less). Both name the file row.
- **A confirmation prompt could be answered twice**, and `require('dblens').format(from, to)`
  called directly with an out-of-range `from` tripped an assertion instead of clamping.
- **Export silently wrote only the current page.** `X` on a 4,000-row table wrote a 100-row file
  and reported "exported 100 row(s)" — true, which is what made it easy to miss — and a query
  result truncated at `max_rows` was written short with a success message and no mention of
  `state.grid.truncated`, while the README claimed the whole result. Every export now writes the
  full row set or states exactly why it could not: the `export.max_rows` cap, the `max_bytes`
  client cap, or a query that cannot be re-read safely (several statements, or one that writes).
  A short file is reported as a WARNING and, where the format has a comment syntax, carries the
  reason as a trailing line.
- **A streamed export was not a consistent read of the table.** It re-read the table page by
  page, each page its own client process with no ordering tying them together, so a row deleted
  between two pages shifted every later row up: the file quietly lost a row it had never read and
  kept one that no longer existed, and still reported "exported N row(s)" with no warning.
  Measured live on PostgreSQL, a 200-row export with one concurrent `DELETE` wrote 199 rows,
  including the deleted one and missing one that existed throughout. An export is now one
  statement, so there is nothing to stitch: what lands during the run belongs to the next export.
- **A capped CSV or JSON export left no mark in the file itself.** Only `.sql` has a comment
  syntax, so the notification — which is transient, while the file is not — was the only record
  that the file was short. A capped export of a format that cannot say so writes a
  `<name>.INCOMPLETE` beside it, and a later complete export removes a stale one.
- **A `.sql` export for MySQL/MariaDB did not say which SQL mode it was escaped for.** The same
  file replays differently with and without `NO_BACKSLASH_ESCAPES`; it now carries a comment
  naming the assumption.
- **PostgreSQL paired a composite foreign key by the cross product.** The catalog query joined
  `key_column_usage` to `constraint_column_usage` on the constraint name alone, so each source
  column of a two-column key matched BOTH target columns and `gf` could filter the referenced
  table on the other column's target. The pairing is positional now, through
  `referential_constraints`; a column carrying two foreign keys also stops duplicating its row.
- **A schema-qualified DuckDB foreign key resolved to a broken name.** `REFERENCES "sch"."t"(x)`
  unquoted to the single name `sch"."t`, and `gf` reported the referenced table was not loaded.
  The target is split at the delimiter, and a schema the metadata named is used to resolve it.
- **The overwrite prompt asked about readability, not existence.** A file that exists but cannot
  be read was replaced with no confirmation.
- **A jump past the end of an uncounted table said only `0 rows`.** With no row count there is no
  last page to clamp against, so `gp 500` lands on an empty page; it now says the page is past the
  end and how to get back.
- **Counting a table from the tree applied the grid's WHERE to it.** `app.count_rows` read
  `state.grid.filter`, so browsing `orders WHERE status = 'shipped'` and then pressing `c` on
  `customers` counted `customers WHERE status = 'shipped'` — an error on an unknown column, or a
  wrong count cached in the catalog and rendered in the tree as that table's own. The predicate is
  passed in now, and only an unfiltered count is written to the catalog: a filtered total belongs
  to one view of one table, not to the table.
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
