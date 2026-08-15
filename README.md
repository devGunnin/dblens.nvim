# dblens.nvim

**A fast, safe database viewer for Neovim — SQLite, PostgreSQL, MySQL, MariaDB, DuckDB and SQL
Server, browsed and queried with the CLI clients you already have.**

dblens gives you a schema tree, a paged result grid and a SQL scratch buffer in one tab page, and
drives six engines through the command-line clients you already have installed. There is no
compiled component and no server: every query is a one-shot client process, decoded through a
record protocol chosen so that a SQL `NULL` is never confused with the text `NULL`. Every
statement goes through a single gate that enforces read-only connections, a confirmation preview,
and a `count(*)` guard proving a row-targeted edit matches exactly one row — and that treats
anything it cannot prove is a read as a write.

## Contents

- [Showcase](#showcase)
- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Quickstart](#quickstart)
- [Supported databases](#supported-databases)
- [Connections](#connections)
- [Discovery](#discovery)
- [Configuration](#configuration)
- [Commands](#commands)
- [Keymaps](#keymaps)
- [Safety model](#safety-model)
- [Transactions](#transactions)
- [Completion](#completion)
- [Health](#health)
- [Highlight groups](#highlight-groups)
- [API](#api)
- [Status](#status)
- [Limitations](#limitations)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Showcase

```text
┌─ dblens ────────────────────────────────────────────────────────────────────┐
│ schema              │ SELECT id, sku, qty FROM inventory WHERE qty < 10     │
│ ▾ public            │───────────────────────────────────────────────────────│
│   ▸ customers       │ id │ sku      │ qty │ warehouse                       │
│   ▾ inventory   PK  │────┼──────────┼─────┼─────────────────────────────────│
│     • id      int   │  4 │ SKU-2201 │   3 │ EU-WEST                         │
│     • sku     text  │ 11 │ SKU-0087 │   7 │ US-EAST                         │
│     • qty     int   │ 19 │ SKU-3340 │   2 │ APAC                            │
│   ▸ orders          │                                                       │
│ ▸ analytics         │                                                       │
├──────────────────────┴───────────────────────────────────────────────────────┤
│ prod · LOCKED · query ok (3 rows, 42ms)                                      │
└────────────────────────────────────────────────────────────────────────────────┘
```

Schema tree, paged grid and SQL editor in one tab. `LOCKED` in the status line means every
statement above ran inside a read-only transaction, refused by the database itself if it tried to
write — see [Safety model](#safety-model).

## Supported databases

| Engine | `kind` | Client | LOCKED enforced by | Strength | Verified |
| --- | --- | --- | --- | --- | --- |
| SQLite | `sqlite` | `sqlite3` >= 3.34 | the file's open mode (`-readonly`) plus `-safe` | **strong** | live, 3.53 |
| DuckDB | `duckdb` | `duckdb` | the file's open mode (`-readonly`) plus `-safe` | **strong** | live, 1.5.5 |
| PostgreSQL | `postgres` | `psql` | a pinned read-only transaction + session default | **strong** | live, 18.4 |
| MySQL | `mysql` | `mysql` | a read-only transaction + read-only session | **strong** | live, 8.4 |
| MariaDB | `mariadb` | `mariadb` | a read-only transaction + read-only session | **strong** | live, 11.8 |
| SQL Server | `mssql` | `sqlcmd` | **dblens's own classifier** — see below | **best-effort (beta)** | live, 2022 |

"Strength" is the one thing that is not the same across engines, so dblens states it everywhere it
matters: `:checkhealth dblens`, the `:DbLensAdd` picker, and this table.

**SQL Server is the exception, and it is not a small one.** SQL Server has no read-only
transaction and no read-only connection mode, so a LOCKED `mssql` connection is enforced by
dblens's classifier rather than by the engine — a bug in that classifier is a write, not a
prompt. Every other engine's LOCKED mode is refused by the engine itself, where no classifier
mistake can produce a write.

That classifier is a **blocklist of write verbs**, and dblens does not claim it is complete: it is
a lexer, not SQL Server's parser, so an administrative statement it has not been taught about
classifies as a read. `mssql` is therefore marked **best-effort (beta)** rather than strong, and
that word is deliberate — it will not be promoted by adding more verbs, because no blocklist over
a language this size can be proven exhaustive.

**On SQL Server, connect as a read-only SQL login.** That is the only hard boundary, the server
enforces it, and it is what dblens recommends for anything past an accidental keystroke — the
recipe is in [SQL Server: a weaker lock](#sql-server-a-weaker-lock), which you should read before
pointing a locked `mssql` connection at anything you care about.

## Requirements

- Neovim >= 0.10
- The client for each database you want to reach:
  - SQLite -> `sqlite3` >= 3.34, for the `-safe` flag that refuses `.shell`, `.load` and ATTACH
  - DuckDB -> `duckdb` (the single static binary from duckdb.org)
  - PostgreSQL -> `psql`
  - MySQL -> `mysql`
  - MariaDB -> `mariadb` (MariaDB's own client; `mysql` is only a compatibility symlink and a
    MariaDB-only machine may not have it)
  - SQL Server -> `sqlcmd` (Microsoft's `mssql-tools18`, or `go-sqlcmd`)

No compiled dependencies. A missing client only makes that one database kind unavailable;
`:checkhealth dblens` reports which ones it found.

## Install

The plugin works with no `setup{}` call at all — the commands, the default keymaps and the
default configuration are all applied on load. Call `setup{}` only to change something.

**lazy.nvim**

```lua
require('lazy').setup({
  { 'devGunnin/dblens.nvim' },
})
```

**packer**

```lua
use 'devGunnin/dblens.nvim'
```

There is no published tag yet, so both snippets install the default branch. Pin a commit if you
want a fixed version.

Then `:DbLens` to open, `:DbLensAdd` to add your first connection.

## Quickstart

1. `:DbLens` in a project that has a database — with nothing configured, dblens offers what it
   finds in it (see [Discovery](#discovery)); pick one and it opens read-only. Or `:DbLensAdd` to
   name a connection yourself: pick a kind, name it, fill in its fields. A `sqlite` or `duckdb`
   connection needs only a file path.
2. `:DbLens` — opens on that connection (or asks, with more than one configured). The schema tree
   is on the left; `:DbLensTables` jumps straight to a table by name.
3. `<CR>` on a table in the tree opens it in the grid (`o` does the same). To run your own SQL,
   `:DbLensQuery` (`<leader>dq`) focuses the editor; `<CR>` runs the statement under the cursor.
4. Every connection opens **LOCKED**: reads work, writes are refused by the database itself.
   `:DbLensWrite` (`<leader>dw`) unlocks it to edit a cell (`e`) or run your own write — every
   write still shows its exact SQL and asks first. `:DbLensLock` locks it again.

`:checkhealth dblens` any time something looks wrong — see [Troubleshooting](#troubleshooting).

## Features

**Browse**

- Workspace discovery: the databases the project in front of you has — a gitignored
  `db/dev.sqlite3`, a compose service, a `DATABASE_URL` — offered with their provenance, read-only
  and on demand ([Discovery](#discovery)).
- Schema tree: connection -> schema -> table/view -> columns, indexes, constraints.
- Primary key, foreign key, NOT NULL and type shown per column.
- **Follow a foreign key** (`gf`) from the cell under the cursor to the row it references, and
  see where you came from in the winbar.
- **Find the rows that reference this one** (`gF`): the same metadata read the other way round,
  so you can go from a customer to their orders. Tables the tree has not expanded are read first,
  so "nothing references this" means it, and several referencing tables ask which one.
- **Filter to the cell under the cursor** (`F`), or away from it (`!`), with the value quoted for
  the dialect rather than retyped. `C` clears the filter.
- Jump to the first, last, or an arbitrary page (`[P`, `]P`, `gp`).
- **Search the loaded result** (`g/`, then `gn` / `gN`), matching the underlying values, so a hit
  inside a value the grid clipped is still found and highlighted.
- **Several results open at once**: `t` in the tree opens a table in a new result tab,
  `<localleader>t` runs a statement into one, and `gt` / `gT` / `gc` / `gl` move between them,
  close one, or list them. Each tab keeps its own filter, sort, search and page — and its own
  race guard, so a slow query in one tab can never land its rows in another.
- `SHOW CREATE TABLE` / `sqlite_schema` DDL where the server has it, reconstructed from the
  catalog where it does not (PostgreSQL).
- Row counts on demand, and a schema reload.

**Query**

- SQL scratch buffer: run the statement at the cursor, the visual selection, or the whole
  buffer. Multiple statements run in order and stop at the first error.
- `EXPLAIN` and, where the server supports it, `EXPLAIN ANALYZE`.
- Cancel a running query.
- Query history and named snippets, persisted to disk. `<CR>` in either picker puts the statement
  in the editor; `<C-r>` runs it straight away, through the same gate as one you typed.
- Schema-aware completion: keywords, tables, views, and columns qualified by table name or
  FROM/JOIN alias. Works through `omnifunc`, nvim-cmp or blink.cmp.
- **Format the SQL** (`<localleader>f`, or `:DbLensFormat`) with a formatter you already have —
  `sqlfluff`, `pg_format` or `sqlformat`, detected in that order, or whatever `format.command`
  names. It is spawned as an argv array with the SQL on stdin: a text tool over text, never a
  shell string and never anything that could execute the statement. With none installed it says
  which to install and leaves the buffer alone.

**Edit**

- Edit a cell, insert a row (by editing the generated `INSERT`), delete a row.
- Every change is previewed as the exact SQL that will run before it runs.
- Yank a cell, a row as CSV, as JSON, or as an `INSERT`.
- **Import a CSV into a table** (`I` in the tree, or `:DbLensImport`) — EDIT mode only, refused on
  a LOCKED connection. The file is parsed by dblens (RFC 4180: quoted fields, embedded commas,
  newlines and quotes), mapped to the table's columns by header name, and every value becomes a
  QUOTED literal — a cell holding `'); DROP TABLE x;--` is imported as that string. The row count,
  the mapping and a sample of the generated `INSERT`s are shown for confirmation first, and the
  run is ONE transaction: if any row fails, nothing is imported and the failing row is named.
- Export to CSV, JSON or `.sql` `INSERT` statements — the whole result from the grid (`X`), or a
  whole table from the tree (`X`). A table export is ONE statement in one client invocation, so
  the file is a SNAPSHOT: a write that lands while it runs belongs to the next export, never to
  half of this one. Rows are written as the client emits them, the file is renamed into place only
  once the run completes, and a run stopped by the `export.max_rows` cap says so loudly instead of
  writing a short file that looks complete.

**Safety**

- **A connection is LOCKED by default** and enforced by the server: every run is sent inside a
  read-only transaction, so no statement in it can turn write access back on. `:DbLensWrite`
  (`<leader>dw`) opens it for editing; `:DbLensLock` locks it again.
- Confirmation gate for destructive statements (on by default), optionally for all writes.
- Row-targeted edits carry a `count(*)` guard that must return exactly 1.
- Planner row estimate shown before a single destructive ad-hoc statement, where the adapter
  can produce one without running it.
- Deferred-batch transaction mode with a pending-changes view.
- A plaintext password is refused in a connection spec.

**Extras**

- Server-side sort and WHERE filter on a browsed table, with paging.
- `:checkhealth dblens`.
- A `statusline()` segment: connection, LOCKED/EDIT, transaction state, running query.
- Highlights derived from your colorscheme, re-derived on `:colorscheme`. Every group is
  documented and override-able, including the pane chrome.
- Three icon sets: plain Unicode (default), Nerd Font, or ASCII.
- LOCKED and EDIT never look alike: calm and plain versus warm and bold, with an icon each.
- Empty panes say what is missing and name the key that fixes it, read from your own bindings.
- which-key group labels when which-key is installed, and nothing extra when it is not.
- The sidebar yields width on a narrow terminal so the grid stays readable at 80x24.

## Connections

A connection is a table with a `name`, a `kind`, the fields that kind requires, and optionally
`read_only`.

| `kind` | Aliases | Required | Optional |
| --- | --- | --- | --- |
| `sqlite` | `sqlite3` | `path` | `create` |
| `duckdb` | `duck` | `path` | `create` |
| `postgres` | `postgresql`, `pg`, `psql` | `database` | `host`, `port`, `user`, `sslmode` |
| `mysql` | — | `database` | `host`, `port`, `user` |
| `mariadb` | `maria` | `database` | `host`, `port`, `user` |
| `mssql` | `sqlserver`, `sql-server`, `tsql`, `sqlcmd` | `database` | `host`, `port`, `user`, `trust_server_certificate` |

`mariadb` used to be an alias for `mysql` and is now its own kind, because MariaDB ships the
`mariadb` client rather than `mysql`. An existing `kind = 'mariadb'` connection keeps working and
now drives that binary; set `clients.mariadb = 'mysql'` if your machine only has the symlink.

### In `setup{}`

```lua
require('dblens').setup({
  connections = {
    -- sqlite: needs `path`. `create = true` allows opening a file that does not exist yet,
    -- and needs `read_only = false` with it: a locked connection cannot create one.
    { name = 'app', kind = 'sqlite', path = '~/src/app/db.sqlite3' },

    -- postgres: needs `database`; host/port/user optional, `sslmode` passed through as PGSSLMODE.
    {
      name = 'prod',
      kind = 'postgres',
      host = 'db.internal',
      port = 5432,
      user = 'analyst',
      database = 'shop',
      password_env = 'PGPASSWORD_PROD',  -- read from the environment at connect time
      read_only = true,
    },

    -- mysql: needs `database`; host/port/user optional.
    {
      name = 'reporting',
      kind = 'mysql',
      host = '127.0.0.1',
      port = 3306,
      user = 'report',
      database = 'metrics',
      password_cmd = { 'pass', 'show', 'db/reporting' },  -- first line of stdout is the password
    },

    -- mariadb: same fields as mysql, driven through the `mariadb` client.
    { name = 'wiki', kind = 'mariadb', host = 'db.internal', user = 'wiki', database = 'wiki' },

    -- duckdb: needs `path`, like sqlite, with the same `create` + `read_only = false` pairing.
    { name = 'analytics', kind = 'duckdb', path = '~/data/warehouse.duckdb' },

    -- mssql: needs `database`. `trust_server_certificate` is for a dev server whose certificate
    -- is self-signed; ODBC Driver 18 encrypts by default and verifies it.
    -- A LOCKED mssql connection is best-effort (beta): the lock is dblens's own classifier, not
    -- the engine. Connect as a read-only SQL login for a boundary the server enforces.
    {
      name = 'crm',
      kind = 'mssql',
      host = 'sql.internal',
      port = 1433,
      user = 'reader',
      database = 'crm',
      password_env = 'MSSQL_READER_PASSWORD',
      read_only = true,
    },
  },
})
```

### Interactively

`:DbLensAdd` asks for the kind, a name, the adapter's fields, where the password comes from
(none / environment variable / command) and whether the connection is read-only, then saves it
to the connections file. `:DbLensRemove {name}` deletes it again. Connections declared in
`setup{}` are read-only to the picker and the form — remove those in `setup{}`.

### Passwords

**dblens refuses to store a plaintext password.** A spec carrying a `password`, `pass` or `pwd`
key fails validation with an error naming the connection. A spec carries a *reference* instead:

- `password_env = 'VARNAME'` — read from that environment variable when the connection opens.
- `password_cmd = { 'pass', 'show', 'db/prod' }` — argv whose first line of stdout is the
  password. If the command fails, its output is never shown, because that output is the secret.

Either way the value is resolved into memory at connect time, handed to the client through
`PGPASSWORD` / `MYSQL_PWD` (never argv, which would show in the process list), and dropped when
the session closes. It is never written back, logged, or persisted. Omitting both is correct for
SQLite and for ambient auth (`.pgpass`, peer, socket).

The connections file is written `rw-------`. `:checkhealth dblens` reports whether a connection
has a password reference, never which variable and never its value.

## Discovery

`:DbLensDiscover` looks through the project you are in and offers the databases it appears to
have. Opening dblens with no connection configured does the same thing instead of telling you to
add one, so a repository with a database in it is one keystroke from open.

The workspace is the git repository the working directory is in, or the working directory itself.
Three things are read there:

| Source | What is found |
| --- | --- |
| Database files | `*.db` `*.sqlite` `*.sqlite3` `*.sqlite2` `*.duckdb` `*.ddb`, by a bounded walk of the project — **including gitignored ones**, which is what a dev database usually is. The file's magic header decides between SQLite and DuckDB; an ambiguous `.db` with no header is treated as SQLite. |
| `docker-compose*.yml`, `compose*.yml` | Services whose image is postgres/mysql/mariadb/mssql, with the host port they publish and the user, database and password from their `environment`. `${VAR}` is resolved from the `.env` beside the compose file. A service that publishes no host port is not offered — nothing could connect to it. |
| `.env`, `.env.*` | Every value that parses as a connection URL (`postgres://`, `postgresql://`, `mysql://`, `mariadb://`, `sqlite:///…`, `duckdb://…`), plus a `PG*` or `MYSQL_*` variable group that names a database. `.env.example` and friends are skipped: they hold placeholders. |

Each candidate shows where it came from, so you can tell a real database from a guess:

```text
db/dev.sqlite3          (sqlite, file)
app-db                  (postgres, localhost:5433/shopdb, from docker-compose.yml)
DATABASE_URL            (postgres, localhost:5432/appdb, from .env)
Add manually…           the :DbLensAdd form
Rescan                  look through the project again
```

The scan is bounded and asynchronous: at most `discovery.max_depth` levels deep and
`discovery.max_entries` directory entries, skipping `.git`, `node_modules`, `vendor`, `target`,
`dist`, `build`, `.venv`, `__pycache__` and the other heavy directories, a few directories per
tick so the editor stays responsive, and cancellable with the usual cancel key. It never follows a
symlink, so it cannot read anything outside the project — and a database file that a `.env`
*names* outside the project (`sqlite:///../elsewhere.db`) is dropped rather than offered, so the
same boundary holds however the path was written.

### What discovery does not do

- **It never connects on its own.** Nothing is scanned until you open dblens or run
  `:DbLensDiscover`, nothing is connected until you pick a candidate, and `setup{}` starts
  nothing. With exactly one candidate the picker starts on it — you still press `<CR>`.
- **A discovered connection opens LOCKED**, like every other connection: the database itself
  refuses writes until you `:DbLensWrite`.
- **It executes nothing it finds.** Discovery reads files. A `docker-compose.yml` is parsed, never
  run; a `.env` is read, never sourced.
- **What a workspace file says is untrusted.** A candidate is validated before it is offered, and
  a value that a database client would read as an *option* rather than as data (a host, user,
  database or path starting with `-`) is refused, so a cloned repository cannot steer the client
  dblens spawns. Anything dropped is reported alongside what was found.
- **A discovered password is never written anywhere.** A password parsed out of a `DATABASE_URL`
  or a compose file is held in memory for that editor session only, and a discovered connection is
  **session-only**: it is never added to the connections file, so the file cannot receive a secret
  discovery read. To keep one, `:DbLensAdd` it, which asks where its password comes from
  (`password_env` / `password_cmd`) rather than storing one.

Turn the offer-on-open off with `discovery = { auto = false }`; `:DbLensDiscover` still works.

## Configuration

Every option, with its default. All of it is optional.

```lua
require('dblens').setup({
  -- Connections declared here. Read-only: the picker and :DbLensRemove cannot edit them.
  connections = {},

  -- Files. Omit to derive from stdpath('data') .. '/dblens'.
  connections_file = nil,  -- default: stdpath('data')/dblens/connections.json
  history_file     = nil,  -- default: stdpath('data')/dblens/history.json
  state_file       = nil,  -- default: stdpath('data')/dblens/session.json

  page_size  = 100,               -- rows fetched per page when browsing a table
  max_rows   = 2000,              -- cap on rows rendered from a query; truncates the result, never the SQL
  max_bytes  = 16 * 1024 * 1024,  -- cap on bytes read from a client process before it is killed
  timeout_ms = 30000,             -- per-statement timeout

  safety = {
    confirm_destructive = true,   -- preview + confirm UPDATE/DELETE/DROP/TRUNCATE/ALTER/...
    confirm_write       = false,  -- also gate non-destructive writes (INSERT/CREATE/...)
    read_only_default   = true,   -- applied to connections that do not set `read_only` themselves
  },

  discovery = {
    auto        = true,           -- opening dblens with NO connection offers what a scan finds
    max_depth   = 6,              -- how deep into the project the scan walks
    max_entries = 20000,          -- directory entries examined before the scan stops and says so
  },

  format = {
    -- {} detects sqlfluff, pg_format or sqlformat, in that order. An argv ARRAY picks one, e.g.
    -- { 'sqlfluff', 'format', '--dialect', 'postgres', '-' }. Never a shell string: it is spawned
    -- directly, is handed the SQL on stdin, and only reformats text.
    command = {},
  },

  import = {
    max_rows  = 10000,            -- rows one CSV import may insert; past it the import is refused
    max_bytes = 16 * 1024 * 1024, -- largest CSV file that will be read at all
  },

  export = {
    max_rows   = 1000000,         -- hard cap on a streamed export; reaching it STOPS it and says so
  },

  history = {
    enabled     = true,           -- record executed statements
    max_entries = 500,            -- oldest entries drop past this
  },

  session = {
    restore   = false,            -- reconnect to the last session when dblens opens
    auto_save = true,             -- remember the open connection and table (see Limitations)
  },

  completion = {
    enabled      = true,
    keyword_case = 'upper',       -- 'upper' | 'lower' | 'keep' (follow the case being typed)
    min_chars    = 1,             -- minimum prefix before the unqualified list is offered
  },

  ui = {
    border = 'rounded',           -- border for every dblens float
    statusline = true,            -- draw the line between panes as a rule, not the buffer name
    icons  = true,                -- true = plain Unicode, 'nerd' = Nerd Font glyphs, false = ASCII
    winbar = true,                -- status winbar above each pane
    sidebar = {
      width    = 34,
      position = 'left',          -- 'left' | 'right'
    },
    results = {
      height   = 0.55,            -- share of the main column given to results; fraction, 0 < h < 1
      max_tabs = 8,               -- results open at once; each tab holds a whole result set
    },
    grid = {
      max_col_width = 40,         -- widest a column renders before truncation; minimum 4
      null_display  = 'NULL',     -- how SQL NULL is drawn (and typed, to set a cell to NULL)
      separator     = '│',        -- column separator
      truncation    = '…',        -- marker appended to a clipped cell
      chunk_size    = 200,        -- rows highlighted per tick, so a wide result never blocks a redraw
    },
    float = {
      max_width  = 0.8,           -- float size as a share of the editor
      max_height = 0.8,
    },
    spinner = {
      frames   = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
      interval = 80,              -- milliseconds per frame
    },
    highlights = {},              -- overrides merged over the derived groups, e.g. { DbLensNull = { fg = '#666' } }
  },

  clients = {
    sqlite   = 'sqlite3',         -- binary (or path) for each database kind
    duckdb   = 'duckdb',
    postgres = 'psql',
    mysql    = 'mysql',
    mariadb  = 'mariadb',         -- MariaDB's own client; `mysql` is only a symlink
    mssql    = 'sqlcmd',          -- mssql-tools18 or go-sqlcmd
  },

  -- Per-scope action -> lhs overrides. `false` disables a binding. See the keymap tables below
  -- for the action names; an unknown action is an error, not a silent no-op.
  keymaps = {
    -- Per action: a key, a list of keys, or false to drop that binding.
    -- A whole scope can be `false` to bind nothing in it -- `global = false` is the escape
    -- hatch for the twelve `<leader>d*` maps.
    global  = {},                 -- e.g. { toggle = '<leader>D', txn_begin = false }
    sidebar = {},
    results = {},
    editor  = {},
  },
})
```

`setup{}` rejects unknown keys and type changes, naming the full dotted path — a typo is an
error, not a silently ignored option. That includes keymaps: an unknown action name, or an
override that is not a key, a list of keys or `false`, fails at `setup{}` rather than when the
pane it belongs to is first opened.

## Commands

| Command | What it does |
| --- | --- |
| `:DbLens [name]` | Open dblens, optionally on a named connection (completes names) |
| `:DbLensClose` | Close dblens and restore the previous layout |
| `:DbLensToggle` | Toggle dblens |
| `:DbLensConnections` | Open dblens if needed, then pick a connection |
| `:DbLensQuery` | Focus the SQL editor |
| `:DbLensTables` | Find a table |
| `:DbLensHistory` | Browse query history |
| `:DbLensSnippets` | Browse saved snippets |
| `:DbLensAdd` | Add a connection interactively |
| `:DbLensDiscover` | Find databases in this project and offer them (see [Discovery](#discovery)) |
| `:DbLensRemove {name}` | Remove a saved connection (completes names) |
| `:DbLensWrite` | Open the active connection for editing |
| `:DbLensLock` | Lock the active connection read-only |
| `:DbLensBegin` | Begin a transaction |
| `:DbLensCommit` | Commit the transaction |
| `:DbLensRollback` | Roll back the transaction |
| `:DbLensPending` | Show the pending changes |
| `:DbLensImport` | Import a CSV file into a table (EDIT mode only, previewed, one transaction) |
| `:DbLensFormat` | Format the SQL buffer, or the `:'<,'>` range, through the detected formatter |
| `:DbLensRestore` | Reopen the last saved session |
| `:DbLensHelp` | Show every binding for the current pane |

Every command runs the same handler as its binding, so the two cannot drift apart.

## Keymaps

Every binding is declared in one table and can be remapped or disabled per scope through
`keymaps` in `setup{}`. `?` shows the live list inside the tree and the grid (the SQL editor uses
`<localleader>?`, so its backwards search still works). The overlay is generated from that table,
so it can never describe a key that is not bound.

With [which-key](https://github.com/folke/which-key.nvim) installed the `<leader>d` prefix is
labelled `dblens` automatically; every binding's description comes from the same table.

### Global

| lhs | Action | Description |
| --- | --- | --- |
| `<leader>dd` | `toggle` | Toggle dblens |
| `<leader>dc` | `connections` | Pick a connection |
| `<leader>dq` | `query` | Focus the SQL editor |
| `<leader>dt` | `tables` | Find a table |
| `<leader>dh` | `history` | Query history |
| `<leader>ds` | `snippets` | Saved snippets |
| `<leader>dw` | `write_toggle` | Lock / unlock for editing |
| `<leader>dl` | `lock` | Lock the connection |
| `<leader>dB` | `txn_begin` | Begin transaction |
| `<leader>dC` | `txn_commit` | Commit transaction |
| `<leader>dR` | `txn_rollback` | Roll back transaction |
| `<leader>dP` | `txn_pending` | Show pending changes |

### Sidebar

| lhs | Action | Description |
| --- | --- | --- |
| `<CR>` | `select` | Expand, or open the table |
| `<Tab>` | `toggle_node` | Expand / collapse |
| `zM` | `collapse_all` | Collapse everything |
| `/` | `find` | Find a table |
| `o` | `open` | Open the table in the grid |
| `t` | `open_tab` | Open the table in a new result tab |
| `c` | `row_count` | Count rows |
| `D` | `ddl` | Show the DDL |
| `X` | `export` | Export the table to a file |
| `I` | `import` | Import a CSV into the table |
| `R` | `refresh` | Reload the schema |
| `?` | `help` | This help |
| `q` | `close` | Close dblens |

### Results grid

| lhs | Action | Description |
| --- | --- | --- |
| `<CR>` / `K` | `detail` | Row detail |
| `]p` | `next_page` | Next page |
| `[p` | `prev_page` | Previous page |
| `[P` | `first_page` | First page |
| `]P` | `last_page` | Last page |
| `gp` | `goto_page` | Go to page N |
| `s` | `sort` | Sort by this column |
| `f` | `filter` | Filter rows (WHERE) |
| `F` | `filter_cell` | Filter to this value |
| `!` | `filter_not_cell` | Filter out this value |
| `C` | `clear_filter` | Clear the filter |
| `R` | `refresh` | Re-run the query |
| `gf` | `follow_fk` | Go to the referenced row |
| `gF` | `find_referencing` | Find rows referencing this one |
| `gt` | `next_tab` | Next result tab |
| `gT` | `prev_tab` | Previous result tab |
| `gc` | `close_tab` | Close this result tab |
| `gl` | `tab_list` | List the open results |
| `g/` | `search` | Search the result |
| `gn` | `next_match` | Next match |
| `gN` | `prev_match` | Previous match |
| `e` | `edit_cell` | Edit this cell |
| `i` | `insert_row` | Insert a row |
| `dd` | `delete_row` | Delete this row |
| `y` | `yank_cell` | Yank the cell |
| `Y` | `yank_row` | Yank the row as CSV |
| `gy` | `yank_json` | Yank the row as JSON |
| `gi` | `yank_insert` | Yank the row as INSERT |
| `X` | `export` | Export to a file |
| `?` | `help` | This help |
| `q` | `close` | Close dblens |

### SQL editor

| lhs | Mode | Action | Description |
| --- | --- | --- | --- |
| `<CR>` | n | `run` | Run the statement |
| `<CR>` | x | `run_selection` | Run the selection |
| `<localleader>r` | n | `run_all` | Run the whole buffer |
| `<localleader>t` | n | `run_new_tab` | Run into a new result tab |
| `<localleader>e` | n | `explain` | EXPLAIN the statement |
| `<localleader>E` | n | `explain_analyze` | EXPLAIN ANALYZE |
| `<C-c>` | n | `cancel` | Cancel the query |
| `<localleader>f` | n | `format` | Format the buffer |
| `<localleader>f` | x | `format_selection` | Format the selection |
| `<localleader>s` | n | `save_snippet` | Save as a snippet |
| `<localleader>h` | n | `history` | Query history |
| `<localleader>?` | n | `help` | This help |
| `<localleader>q` | n | `close` | Close dblens |

## Safety model

### What LOCKED guarantees, and what it does not

Read this before pointing dblens at a database you care about. LOCKED is the default for every
connection.

It does **not** mean the same thing on every engine. On five of the six it is the engine that
refuses the write; on SQL Server there is nothing in the engine to refuse it with, and everything
below marked "strong" does not apply there — see [SQL Server: a weaker
lock](#sql-server-a-weaker-lock).

On SQLite, DuckDB, PostgreSQL, MySQL and MariaDB, LOCKED **does** guarantee:

- **no accidental write** — nothing you did not mean to run reaches the database;
- **no write through any ordinary SQL statement**, however it is spelled. It is the *database
  engine* that refuses it — a read-only transaction on PostgreSQL, MySQL and MariaDB, the file
  handle's open mode on SQLite and DuckDB — not dblens reading your SQL;
- **no second statement.** Every framing trick that stacked one (a `;` inside a comment, a bare
  `\r`, a nested block comment, a Unicode line separator) is refused unparsed, by a byte scan.
  (This one is a scan for `;`, so it does not carry to T-SQL, which needs no separator at all.)

LOCKED **does not** guarantee:

- **protection from someone who both holds write credentials and deliberately calls a
  write-capable extension.** `SELECT dblink_exec('dbname=app …','INSERT …')` runs its `INSERT` in
  a **second** PostgreSQL backend, outside dblens's read-only transaction — and it is a single
  statement beginning with `SELECT`, so neither the transaction nor the one-statement rule reaches
  it. `postgres_fdw`, `lo_export`, `pg_read_file` and a MySQL shell UDF are the same shape.

dblens refuses [the known names](#side-channels-a-best-effort-refusal-not-a-boundary) while
locked. That is **best-effort and explicitly not a security boundary**: a `SECURITY DEFINER`
wrapper called `refresh_cache()` walks straight through it, and nothing on the client side can
tell the difference, because only the server knows what a function does.

**If your threat model is a deliberate user rather than a slip of the keyboard, connect as a
[database read-only role](#a-database-read-only-role-the-hard-boundary).** That is the only hard
boundary, and the server is the one enforcing it.

Compared honestly: this is what a client-side read-only mode can be. dblens's is stronger than
parsing your SQL and hoping — the server refuses the write — but no client can constrain what a
function does once it is running inside the server.

### How it is enforced

**A connection is LOCKED unless you unlock it, and locked is enforced by the database server.**
Every connection opens locked; only an explicit `read_only = false` (or
`safety.read_only_default = false`) opens one for editing. While locked, dblens sends every run
inside a **server-side read-only transaction**, so the engine refuses every write however the
statement is spelled:

| | what a locked run sends, and what opens the connection |
| --- | --- |
| SQLite | nothing extra — `sqlite3 -readonly` is the file handle's open mode, so a write answers `attempt to write a readonly database`. `-safe` refuses `.shell`, `.load`, `.import` and ATTACH |
| DuckDB | nothing extra — `duckdb -readonly` is the file's open mode, so a write answers `Cannot execute statement of type "INSERT" … attached in read-only mode`. `-safe` is added too, and is **not** decoration: under `-readonly` alone, `COPY (SELECT 1) TO '/tmp/x.csv'` still wrote the file. Read-only covers the database; `-safe` covers the filesystem |
| PostgreSQL | `BEGIN READ ONLY; DECLARE … CURSOR …;` around the run, plus `PGOPTIONS=-c default_transaction_read_only=on`. A write answers `cannot execute … in a read-only transaction` |
| MySQL / MariaDB | `START TRANSACTION READ ONLY;` around the run, plus `--init-command=SET SESSION TRANSACTION READ ONLY`. A write answers `ERROR 1792 … Cannot execute statement in a READ ONLY transaction` |
| SQL Server | there is no such switch. LOCKED is best-effort (beta) here — see [SQL Server: a weaker lock](#sql-server-a-weaker-lock), and connect as a [read-only SQL login](#connect-as-a-read-only-sql-login) for a boundary the server enforces |

On MySQL and MariaDB **both** the transaction and the session switch are load-bearing, and
neither alone is enough. Inside a bare `START TRANSACTION READ ONLY`, `CREATE TABLE` and
`DROP TABLE` **succeed** — verified live on MySQL 8.4 and MariaDB 11.8, because DDL commits the
transaction implicitly and then runs outside it. `SET SESSION TRANSACTION READ ONLY` is what
refuses those. The transaction is what a `SET` in the same run cannot undo:
`SET default_transaction_read_only = off; INSERT …` and `SET SESSION TRANSACTION READ WRITE;
INSERT …` both used to land a row on a `read_only` connection, and inside an open read-only
transaction they cannot, because a `SET` retargets only LATER transactions. (PostgreSQL will let
`SET TRANSACTION READ WRITE` escalate a read-only transaction until it has taken a snapshot,
which is why the `DECLARE … CURSOR` is there — it takes one and returns nothing.)

This is the guarantee because the alternative is not one. dblens used to decide read-only by
lexing the SQL itself, and four independent reviews broke it — nested block comments (`/* /* */`
closes the comment everywhere except PostgreSQL), MySQL's executable `/*!…*/` comments, backslash
escaping, which depends on the server's `sql_mode` rather than on the dialect, and a bare `\r`,
which ends a `--` comment for psql. A Lua reimplementation of five dialects' lexers will always
disagree with the real parser somewhere, and every disagreement is a bypass. The server's own
parser cannot disagree with itself.

Reads are unaffected: `SELECT`, `EXPLAIN`, catalog queries and paging all work normally on a
locked connection.

### SQL Server: a weaker lock

> **`mssql` locked mode is best-effort, and beta.** dblens does not claim it blocks every write on
> SQL Server, and it will not make that claim later: the lock is a blocklist of verbs over a
> language dblens does not parse, so an administrative or DBCC statement it has not been taught
> about is a write rather than a refusal. **For a hard read-only boundary on SQL Server, connect
> as a read-only SQL login** ([recipe below](#connect-as-a-read-only-sql-login)) — the server
> enforces that one, the way it does on the other five engines.

**A LOCKED `mssql` connection is enforced by dblens, not by SQL Server.** Everything above rests
on the engine refusing the write. SQL Server gives no way to ask for that:

- there is no read-only transaction — `BEGIN TRANSACTION` has no `READ ONLY` mode;
- there is no read-only connection mode. `sqlcmd -K ReadOnly` sets `ApplicationIntent`, which only
  routes to a readable secondary in an availability group. dblens passes it on a locked
  connection because it is the truthful thing to declare, **not** because it enforces anything:
  verified live on SQL Server 2022 that an `INSERT` sent under it lands.

So on `mssql`, LOCKED is four client-side refusals, and a bug in any of them is a write rather
than a prompt:

1. **the classifier** — anything dblens cannot prove is a read is refused as a write. This is the
   layer that is only best-effort on every other engine, and here it is the boundary.
2. **the T-SQL juxtaposition rule** — T-SQL ends a statement at whitespace, so
   `SELECT 1 DROP TABLE t` is *two* statements with no `;` in it (verified live: the table was
   dropped). The one-statement byte scan cannot see that, so on this dialect a write verb
   anywhere but the head of the statement is treated as opening a new one — **including one
   followed by `(`**. `EXEC('…')` is T-SQL's dynamic-SQL *statement*, not a function call, and
   treating it as a call was a hole: `SELECT 1 EXEC('COMMIT TRANSACTION DROP TABLE t')`
   classified as a read and ran on a locked connection (verified live on 2022 — `INSERT`,
   `TRUNCATE`, `DROP TABLE`, `CREATE DATABASE` and a server-level `CREATE LOGIN` all landed).
   The cost of the rule, paid on this engine only: an ordinary `SELECT REPLACE(a,'x','y')` is
   refused while locked, as is an unquoted column named after a non-reserved write verb (`copy`,
   `replace` used bare). Quote the name, or unlock, and it works. On every other engine
   `SELECT REPLACE(...)` is an ordinary read.
3. **`GO` and the `:` commands** — `GO` is a sqlcmd *batch* separator, so what follows it runs as
   its own batch: a second statement no framing rule sees (verified live — `SELECT 1 / GO / DROP
   TABLE t` dropped the table), and `sqlcmd -X1` does not stop it. dblens refuses `GO`, `EXIT`,
   `QUIT`, `ED`, `LIST` and any `:`-command at the head of a line, in both LOCKED and EDIT mode,
   because none of them is SQL.
4. **the side-channel name check, string literals included** — on this engine only, because
   `EXEC('…')` can turn a quoted string into code. A locked `mssql` read whose literal names
   `xp_cmdshell`, `OPENROWSET` or `dblink` is refused for that reason.

**What none of that covers:** anything the classifier does not recognise as a write. It is a
lexer, not SQL Server's parser, and on this engine there is no second layer that refuses.

That is not hypothetical. `SELECT 1 DBCC TRACEON(3999,-1)` classified as a *read*, ran clean on a
LOCKED connection and flipped a global trace flag from 0 to 1 — server-wide, across databases, and
still set on a brand-new connection. It survived the rolled-back wrap below because DBCC is not
transactional, so the trailing `ROLLBACK` had nothing to undo. `DBCC FREEPROCCACHE` and `DBCC
DROPCLEANBUFFERS` landed the same way; `BACKUP`, `RESTORE`, `DENY` and `CHECKPOINT` reached the
server and were saved only by the wrap.

dblens now refuses the administrative verbs it knows — `DBCC`, `BACKUP`, `RESTORE`, `DENY`,
`CHECKPOINT`, `RECONFIGURE`, `KILL`, `SHUTDOWN`, `WRITETEXT`, `UPDATETEXT`, `DISABLE`, `ENABLE`
and `RECEIVE`, on top of the ordinary write verbs — and every payload above is refused at the gate
(re-verified live on 2022: the trace flag stays 0). **Read that as defence in depth, not as a
completeness claim.** T-SQL has more state-changing verbs than dblens knows about, and the next
one dblens has not been taught behaves exactly the way `DBCC` did. This is why `mssql` is
best-effort and stays best-effort. If that matters to you, the next section is the answer.

Underneath those, a locked run is wrapped in `SET XACT_ABORT ON; BEGIN TRANSACTION; … IF
@@TRANCOUNT > 0 ROLLBACK TRANSACTION;`. That is a **net, not a guarantee**, and its limit was
measured rather than assumed:

- a write that got past the classifier is undone — an `INSERT` and a `DROP TABLE` inside the wrap
  both left the database unchanged, because SQL Server DDL is transactional;
- a `GO` alone does not escape it either: the transaction survives the batch boundary on the same
  connection, so the trailing `ROLLBACK` still reaches the write;
- but anything that **commits the wrap away** escapes it and what follows runs in autocommit —
  `… GO … INSERT … COMMIT TRANSACTION`, and `EXEC('COMMIT TRANSACTION INSERT …')` with no `GO`
  at all. The classifier refuses both; the wrap alone never stopped them.

The wrap therefore ends by checking the transaction is still open and failing the batch when it
is not, so a run that committed its own net away is reported as an error instead of a success.
Where the net simply holds, `sqlcmd` exits 0 and dblens reports success for a write that was
rolled back: the safe failure, not a correct one.

#### Connect as a read-only SQL login

That is the boundary SQL Server does have, it is the only one, and on this engine it is the
recommended way to run dblens rather than a hardening extra. The server refuses the write, so no
classifier gap — the DBCC one above included — can produce one:

```sql
CREATE LOGIN dblens_ro WITH PASSWORD = '…';
CREATE USER dblens_ro FOR LOGIN dblens_ro;

-- either the role, which covers every table and view in the database:
ALTER ROLE db_datareader ADD MEMBER dblens_ro;
-- or, narrower, just what this user should see:
GRANT SELECT ON SCHEMA::dbo TO dblens_ro;

DENY EXECUTE TO dblens_ro;   -- also blocks the procedures below
```

Point the connection at it and keep `read_only = true`: the login is what makes the write
impossible, and dblens's own lock stays on as the layer that catches the keystroke before it is
sent.

```lua
{ name = 'crm', kind = 'mssql', host = 'sql.internal', user = 'dblens_ro',
  database = 'crm', password_env = 'MSSQL_RO_PASSWORD', read_only = true },
```

Two more things differ on `mssql` and are worth knowing before you trust a cell:

- **`NULL` is ambiguous.** `sqlcmd` prints SQL `NULL` as the four characters `NULL` and has no
  null-marker option (`mysql` has `--xml`, `psql` has `-P null=…`), so a real `NULL` and the
  string `'NULL'` arrive as the same bytes. Every other engine dblens drives distinguishes them.
- **control characters in values are flattened.** dblens passes `sqlcmd -k1`, which replaces them
  with a space. That is deliberate: without it a value holding a newline split the record and a
  value holding `0x1F` split the row. A flattened cell beats a corrupted grid.
- **no EXPLAIN.** A SQL Server plan needs `SET SHOWPLAN_ALL ON` as its own batch, and dblens sends
  one statement per client invocation. Running EXPLAIN (`<localleader>e`) on an `mssql` connection
  says so rather than sending something else.

**Unlocking is a deliberate act, and the only way to write.** `:DbLensWrite` (`<leader>dw`) puts
the active connection in EDIT mode: the next run spawns without the read-only switch and without
the transaction wrap, so the ordinary write paths work — still behind the confirmation gate
below. `:DbLensLock` puts it back, and the very next run is refused by the server again. The
sidebar, the results winbar and `statusline()` all say `LOCKED` or `EDIT`. Locking is refused
while a transaction queue is pending, because a locked connection cannot commit it: commit or
roll back first.

**The classifier decides whether you are asked, not whether it is allowed.** dblens still reads
the statement to work out whether it is a write and whether it is destructive, and that is what
drives the confirmation prompt and the early "connection X is read-only" message. It is
best-effort: a miss now costs a prompt on a writable connection, not a table. It is still biased
closed — a single statement led by `SELECT`, `WITH`, `VALUES`, `TABLE`, `SHOW`, `DESCRIBE`, a
reporting `PRAGMA` or a non-`ANALYZE` `EXPLAIN` counts as a read, and anything else is a write —
so `WITH d AS (DELETE …) SELECT …`, `COPY … FROM PROGRAM`, `DO $$ … $$`, `CALL`, `SELECT … INTO`,
`PRAGMA user_version = 42` and `SELECT 1; DROP TABLE t` all prompt.

Where a write verb is a *name* it is left alone: `SELECT REPLACE(a,'x','y')`, `SELECT TRUNCATE(x,2)`,
a column called `comment` and an unquoted non-ASCII identifier are ordinary reads. A write verb
only counts when it sits where a nested statement could begin.

`EXPLAIN ANALYZE` is classified by the statement *inside* it, because on PostgreSQL and MySQL it
**runs** that statement — as are `DESCRIBE ANALYZE` and `DESC ANALYZE`, which are MySQL synonyms
for it. `EXPLAIN ANALYZE DELETE …` is therefore a destructive write, with the float saying
plainly that it will run. Plain `EXPLAIN` only plans, and stays a read.

**Client meta-commands never reach a client.** `psql` runs `\!` as a shell command in the middle
of a statement, `sqlite3 -batch` honours `.shell`, and the `mysql` client honours a bare `system`
or `source` at the head of a line even in batch mode — `system` shells out and `source` reads and
executes a file on *your* machine. None of these is SQL, so a read-only connection does not touch
them and no client flag turns them off (`--skip-named-commands` still honours them at the head of
a line). dblens refuses them itself, on every connection: a statement starting with `.`, an
unquoted `\`, or a line beginning `system`/`source`/`tee`/`pager`/`edit`/`connect`/`delimiter`.
A column with one of those names can still be used by quoting it. sqlite3 is additionally run
with `-safe`, MySQL with `--local-infile=0`.

**A locked connection runs exactly one statement.** On PostgreSQL and MySQL the read-only
transaction holds against everything *inside* it, but a statement can still END or REPLACE it and
write in a new one — `ROLLBACK; SET default_transaction_read_only = off; BEGIN; INSERT …` on
PostgreSQL, `START TRANSACTION READ WRITE; INSERT …` on MySQL. Every escape of that shape needs a
**second** top-level statement. So while locked, dblens refuses any input it cannot prove is
exactly one:

- a `;` anywhere but as the final character;
- any control byte other than tab and newline (`\r`, `\v`, `\f`, `NUL`, `0x1C`–`0x1F`, …);
- a Unicode line or paragraph separator (`U+0085`, `U+2028`, `U+2029`).

That check is a byte scan, not a parse. The defence before it was the classifier's statement
count, and a bare `\r` — which psql reads as the end of a `--` comment and the classifier did not
— hid a stacked `DROP TABLE` from it and dropped the table on a locked connection. Teaching the
lexer about `\r` would only move the gap to the next character; refusing every framing closes the
class. The two layers together are the model: **the read-only transaction makes one statement
unescapable, and the single-statement rule makes a second statement unreachable.** SQLite needs
neither for writes — `-readonly` is the file handle's open mode — but the rule applies there too.

The refusal names the mode and the way out: multi-statement scripts are an EDIT-mode feature,
reached with `:DbLensWrite` (`<leader>dw`) and still behind the confirmation gate. Ordinary reads
are unaffected — multi-line SQL, comments, tabs and a trailing `;` all pass. The cost is exact
and deliberate: while locked, a statement carrying a `;` inside a string literal or a quoted
identifier (`SELECT ';'`, a column named `a;b`) is refused as well, because proving *that* one is
a single statement would mean trusting the lexer again.

### Side channels: a best-effort refusal, not a boundary

Some functions do their work **outside** the transaction dblens opened — in a second database
backend, or on the server's filesystem. A read-only transaction does not govern either. All of
these are one statement led by `SELECT`, so every layer above passes them:

| named while locked | what it reaches |
| --- | --- |
| `dblink…` (the whole family), `postgres_fdw…` | a second database session, whose transaction dblens cannot make read-only |
| `lo_import`, `lo_export`, `pg_read_file`, `pg_read_binary_file`, `pg_ls_dir`, `pg_stat_file` | the PostgreSQL server's filesystem |
| `LOAD_FILE` | the MySQL / MariaDB server's filesystem |
| `sys_exec`, `sys_eval` | a shell on the MySQL / MariaDB server, via a UDF |
| `xp_cmdshell`, `sp_execute_external_script`, `sp_OACreate`, `sp_OAMethod` | a command on the SQL Server host |
| `OPENROWSET`, `OPENDATASOURCE`, `OPENQUERY`, `BULK`, `xp_dirtree`, `xp_subdirs`, `xp_fileexist`, `xp_fixeddrives`, `xp_regread` | another data source, or the SQL Server host's filesystem |

The SQL Server names matter more than the rest: on every other engine there is a read-only
transaction behind this list, and on SQL Server there is not. DuckDB is absent for the same
reason SQLite is — a locked DuckDB connection runs `-safe`, so the *engine* refuses every
filesystem reach (`COPY … TO`, `read_csv`, `INSTALL`), and a name list would duplicate a
guarantee that is already enforced.

A LOCKED connection refuses a statement naming one of them, and says which name it objected to.
Unlock to run it. This is measurable, not decorative — verified live on PostgreSQL 16: inside
dblens's read-only wrap `lo_export` *wrote* a file on the server and `pg_read_file` *read* one,
and `dblink_exec` landed a row in the table. All three are now refused.

**And it is a name check, so treat it as raising the bar, never as a boundary.** A
`SECURITY DEFINER` wrapper, a rename, or a copy in another schema is not caught — verified live:
`SELECT refresh_cache('…')`, a one-line wrapper around the same `dblink_exec`, still landed its
row on a LOCKED connection. No client-side check can close that; a function name says nothing
about what the function does. `tests/spec/side_channel_spec.lua` pins that limitation as a test
case rather than pretending it away.

Only quoting matters: a *quoted* identifier or a string literal holding one of these names is
data, so `SELECT "dblink_log" FROM audit` is an ordinary read. EDIT mode never applies the check —
an unlocked connection can write with a plain `INSERT`, so refusing there would only break a
legitimate `dblink` query.

Already covered by the layers above, and confirmed as such: `COPY … TO/FROM PROGRAM` (`COPY` is a
write verb), `SELECT … INTO OUTFILE`/`DUMPFILE` and `LOAD DATA INFILE` (refused as writes). SQLite
needs no name list: `-safe` refuses `writefile()`, `.load` and `ATTACH` at the client (verified on
3.53), and `-readonly` is the file handle's open mode.

### A database read-only role (the hard boundary)

The only guarantee that holds against a user who *has* write credentials is not to give the
connection write credentials. dblens uses whatever role you point it at, so this is a change to
your database, not to your config: create a read-only role and put it in the connection's `user`.

```sql
-- PostgreSQL
CREATE ROLE dblens_ro LOGIN PASSWORD '…' NOSUPERUSER NOCREATEDB NOCREATEROLE;
GRANT CONNECT ON DATABASE app TO dblens_ro;
GRANT USAGE ON SCHEMA public TO dblens_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dblens_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO dblens_ro;
```

```sql
-- MySQL / MariaDB. No FILE privilege, so LOAD_FILE and INTO OUTFILE fail; no CREATE
-- ROUTINE, so a shell UDF cannot be installed.
CREATE USER 'dblens_ro'@'%' IDENTIFIED BY '…';
GRANT SELECT, SHOW VIEW ON app.* TO 'dblens_ro'@'%';
```

SQLite has no roles: `-readonly` is already the open mode, and the file's own permissions
(`chmod a-w app.db`) are the layer under it.

Verified live on PostgreSQL 16, as that role: a plain `INSERT` is `permission denied for table`;
`lo_export` and `pg_read_file` are `permission denied for function`; and a direct `dblink_exec`
over the server's own socket is refused with *"Non-superusers must provide a password in the
connection string"* — the peer-auth escape closes with the superuser bit.

**One thing a read-only role still does not cover, so it is worth knowing.** A `SECURITY DEFINER`
function runs with its **owner's** privileges — that is what it is for. The same
`refresh_cache()` wrapper wrote its row as `dblens_ro` too, because a superuser owns it and
PostgreSQL grants `EXECUTE` to `PUBLIC` by default. That is a privilege escalation the database
already contains, reachable by every role and by every client. If it matters to you, take the
grant back:

```sql
REVOKE EXECUTE ON FUNCTION refresh_cache(text) FROM PUBLIC;
```

Verified: after that the same call is `permission denied for function refresh_cache`, and no row
lands.

**The confirm gate.** `UPDATE`, `DELETE`, `REPLACE`, `MERGE`, `DROP`, `TRUNCATE`, `ALTER`,
`RENAME`, `GRANT` and `REVOKE` are destructive; other writes are not. With
`safety.confirm_destructive = true` (the default) a destructive statement is shown in a preview
float — the exact SQL, the verb and target, and a flag when it affects a whole object with no
`WHERE` — and runs only when you confirm. `safety.confirm_write = true` extends the same gate to
non-destructive writes. The two are evaluated per class, so a script holding both an `INSERT` and
a `DROP` is gated by both settings. An unconfirmed write is refused by the session, not merely
undrawn.

Before a single destructive ad-hoc statement, adapters that can estimate without executing
(`caps.estimate_rows`: PostgreSQL via `EXPLAIN (FORMAT JSON)`, MySQL and MariaDB via `EXPLAIN`)
show the planner's row estimate. SQLite, DuckDB and SQL Server cannot, and say so; a failed
estimate says why.

**The exactly-one-row guard.** A cell edit or a row delete builds a `WHERE` from the primary
key, or — when the table has none — from every column in the displayed row. Either way the
change carries a guard: `SELECT count(*) FROM <table> WHERE <same predicate>`. The session runs
the guard first and refuses the change unless it returns exactly 1, reporting how many rows the
predicate actually matched. That is what makes editing a table without a primary key safe: an
ambiguous predicate is refused, never applied to several rows. The preview tells you which of
the two identifications is in use. An `INSERT` targets no existing row and carries no guard.

In transaction mode the guard is emitted **into** the committed batch, immediately before the
change it guards, so it is re-checked against the database as the transaction sees it rather
than as it was at queue time. A guard that no longer matches exactly one row aborts the whole
batch. Outside a transaction the guard and the write are still two separate client invocations,
so a concurrent writer between them is not excluded — the guard bounds mistakes, not races.

**Connection paths are never shell-evaluated.** A `path` is expanded with `~` and `$VAR`
substitution only. A backtick, a wildcard, `$(`, a `~user` form dblens cannot expand correctly,
or a leading `-` is rejected when the connection is validated, and always as a reported error
rather than a raise, so a bad `connections.json` names its problem instead of taking `:DbLens`
down. `password_cmd` is the one field of a connection that is a command by declaration: it is
argv run with no shell, and it is checked only for being a runnable argv.

**Filters are vetted by an allow-list.** A `WHERE` typed into the results filter is checked
before it is spliced into a statement. Rejected: a comment (which would comment out the
`LIMIT`/`OFFSET` appended after it), an unclosed quote, any punctuation outside the SQL operator
set — which drops `;` and a bare `\` together, so psql's `\!` never reaches the client — and a
write verb where a nested statement could begin. A backslash *inside a literal* is rejected only
on MySQL and MariaDB, where `NO_BACKSLASH_ESCAPES` decides what it means; the other four accept
it, so a Windows path or a regex filters normally there. What makes that safe is that no dialect
is left guessing about its own server: dblens emits a PostgreSQL/DuckDB literal as `E'…'`, which
means the same thing whatever `standard_conforming_strings` is set to, and it pins
`standard_conforming_strings=on` and clears `NO_BACKSLASH_ESCAPES` on the connections it opens. `REPLACE(…)`, a column called `comment` and non-ASCII identifiers are accepted; a
column named after a SQL verb can also be quoted. The filter bar is still raw SQL: the check
stops it escaping the statement, it does not stop an expensive or volatile function call.

## Transactions

CLI clients are one-shot processes, so a transaction cannot be held open across calls the way a
socket session could. dblens therefore *defers*.

Transaction mode needs a writable connection: on a LOCKED one `<leader>dB` and `<leader>dC` are
refused, and since every connection is locked by default that is the first thing you meet — unlock
with `<leader>dw` first.

While transaction mode is on (`<leader>dB`), every change you make is **queued, not sent**. A
queued change is **not visible to the server**, to other clients, or to a re-run of the same
query — the grid marks it as pending rather than pretending it landed, and the winbar and
`statusline()` show `TXN n pending`. `<leader>dP` lists the queue.

`<leader>dC` commits: the whole queue is replayed, in order, inside one client invocation
wrapped in `BEGIN; ...; COMMIT;`, with each change's row guard emitted immediately before it.
Atomicity comes from the client's own flags — `sqlite3 -bail`, `psql -v ON_ERROR_STOP=1`, and
the mysql client's default abort — because without them `sqlite3` prints the error, *skips* the
failing statement and still runs the trailing `COMMIT`.

If a statement fails, nothing landed, the report names which change failed (and says so plainly
when the failure was a guard that no longer matches one row), and the queue is kept so you can
fix and retry. If the commit is instead **interrupted** — a timeout, `<C-c>`, or the output cap
— the outcome is not known, so the queue is discarded rather than kept: replaying it could apply
a committed `INSERT` twice or re-run a `DELETE` whose guard has already been spent. dblens says
so and tells you to check the table.

`<leader>dR` rolls back, which is free: nothing was ever sent. It discards the queue and leaves
transaction mode.

Consequences worth knowing:

- A queued `UPDATE` does not affect a later queued statement's view of the data, because the
  server sees them all for the first time at commit.
- Committing runs the queue against the database *as it is at commit time*, not as it was when
  you queued it.
- Beginning a transaction while one is already open is refused, so a stray keypress cannot
  discard a queue by restarting it.

## Completion

Schema-aware SQL completion in the scratch buffer, on by default. It offers keywords, tables and
views, and columns; `users.` or an alias from a `FROM` / `JOIN` clause narrows the list to that
table's columns, with type, `PK`, `NOT NULL` and foreign-key target shown. Dots inside string
literals and comments are never read as qualifiers.

It is wired up three ways, all from the same engine:

- `omnifunc` — always set on the scratch buffer, so `<C-x><C-o>` works with nothing installed.
- **nvim-cmp** — a `dblens` source is registered and added to the buffer automatically.
- **blink.cmp** — a `dblens` source provider is registered and added for the buffer's filetype.

Both plugins are optional; a missing one is not an error.

## Health

`:checkhealth dblens` reports the Neovim version; the dblens version, whether the configuration
loaded or was refused, where its files live and the resolved limits; each database client and its
version; **what LOCKED means per engine**, as a warning wherever it is best-effort rather than
enforced by the server; every connection with its kind, access and whether it has a password
reference; any global keymap it took over from another plugin; which SQL formatter
`:DbLensFormat` would use; and which optional integrations are installed. It never resolves a
password.

## Highlight groups

Every group links to a standard group, so dblens follows your colorscheme, including a live
`:colorscheme` change. All links are set with `default = true`, so a colorscheme defining a
`DbLens*` group wins; `ui.highlights` in `setup{}` wins over both.

| Group | Links to | |
| --- | --- | --- |
| `DbLensNormal` | `Normal` | |
| `DbLensTitle` | `Title` | bold |
| `DbLensDim` | `Comment` | |
| `DbLensAccent` | `Identifier` | |
| `DbLensBorder` | `FloatBorder` | |
| `DbLensMatch` | `Search` | |
| `DbLensError` | `DiagnosticError` | |
| `DbLensWarn` | `DiagnosticWarn` | |
| `DbLensCursorLine` | `CursorLine` | pane chrome |
| `DbLensWinBar` | `Normal` | pane chrome, winbar background |
| `DbLensSchema` | `Directory` | tree |
| `DbLensTable` | `Normal` | tree |
| `DbLensView` | `Type` | tree |
| `DbLensColumn` | `Normal` | tree |
| `DbLensDataType` | `Comment` | tree |
| `DbLensIcon` | `Special` | tree |
| `DbLensChevron` | `Comment` | tree |
| `DbLensPK` | `Special` | tree, bold |
| `DbLensFK` | `Type` | tree |
| `DbLensNN` | `Comment` | tree |
| `DbLensIndex` | `Constant` | tree |
| `DbLensHeader` | `Title` | grid, bold |
| `DbLensRule` | `NonText` | grid |
| `DbLensNull` | `Comment` | grid, italic |
| `DbLensNumber` | `Number` | grid |
| `DbLensBoolean` | `Boolean` | grid |
| `DbLensString` | `Normal` | grid |
| `DbLensDirty` | `DiffChange` | grid, pending change |
| `DbLensSortKey` | `Search` | grid |
| `DbLensSpinner` | `DiagnosticInfo` | status |
| `DbLensLocked` | `DiagnosticOk` | status, LOCKED |
| `DbLensEdit` | `DiagnosticWarn` | status, EDIT, bold |
| `DbLensTxn` | `DiagnosticInfo` | status |

## API

```lua
local dblens = require('dblens')

dblens.setup(opts)          -- configure; optional, safe to call twice
dblens.open(name)           -- open, optionally on a named connection
dblens.close()
dblens.toggle()
dblens.is_open()            -- boolean
dblens.restore()            -- reopen the last saved session
dblens.add_connection()     -- the :DbLensAdd form
dblens.remove_connection(name)
dblens.connection_names()   -- string[], sorted
dblens.statusline()         -- 'prod · LOCKED · TXN 2 pending · query…', '' when closed
```

`statusline()` is a plain string, so it drops straight into your statusline:

```lua
vim.o.statusline = "%f %= %{v:lua.require'dblens'.statusline()}"
```

## Status

**SQLite is verified live.** The plugin was developed and exercised against real `sqlite3`
databases; browsing, paging, sorting, filtering, editing, transactions and export all work
against a live file.

**PostgreSQL is verified live** against PostgreSQL 18.4: the safety gate, the CSV record
decoding (including values holding the bytes the previous framing used as separators), plain
`EXPLAIN`, and the transaction row guard were all exercised end to end.

**MySQL is verified live** against MySQL 8.4: the read-only transaction, the transaction row
guard, batch atomicity and `--xml` decoding — the XML output exists because the default tab
format cannot distinguish SQL `NULL` from the string `'NULL'`.

**DuckDB, MariaDB and SQL Server are verified live too** — DuckDB 1.5.5, MariaDB 11.8, SQL
Server 2022 — which is what the Verified column of the engine table above reports.

**The read-only guarantee is verified live on all six**, by `tests/spec/readonly_spec.lua`,
`single_statement_spec.lua` and `side_channel_spec.lua`. Each sends its escape payloads to a real
server on a locked connection and asserts the table did not change, with a writable control that
does change so the assertion cannot pass vacuously. A server-backed engine needs
`DBLENS_TEST_<KIND>_PORT` (plus `_HOST` `_USER` `_PASSWORD` `_DB` `_CLIENT`, and `_TRUST_CERT`
for SQL Server) and skips with a note when there is none.

**Where that verification actually runs.** CI installs `sqlite3` and `duckdb`, so those two live
groups run on every push; the `postgres`, `mysql`, `mariadb` and `mssql` groups run only where a
maintainer supplies a server, and skip with a note in CI. Catalog queries, DDL reconstruction and
error reporting have much thinner live coverage everywhere — please report what you hit.

## Limitations

- A result is capped at `max_rows` rows for rendering; the SQL is never rewritten, so the client
  still does the full work. Client output is capped at `max_bytes`.
- Sorting and filtering apply to a browsed table only. For a query result, put `ORDER BY` /
  `WHERE` in the query.
- Foreign-key navigation, forward (`gf`) and reverse (`gF`), follows ONE column of a composite
  key and says so, so the result may hold more rows than the single referenced one. Reverse
  navigation sees the loaded schema only: it reads the columns of tables that were never
  expanded, but a schema that has not been listed at all is not searched.
- The `?` overlay no longer fits an 80x24 screen in ANY pane — the grid lists 44 bindings and
  even the sidebar's list is taller than the 18 rows that size leaves. It scrolls there (`j`/`k`),
  and the footer says so; nothing is dropped or cut off the right edge. It fits from about
  100x33.
- A `.sql` export replays TEXT faithfully. A binary/BLOB column does not survive it: the value
  reaches dblens through the client's text output, where a NUL byte truncates it, so the INSERT
  carries what the grid shows rather than the bytes in the table. Use the engine's own dump tool
  for binary columns.
- A `.sql` export for MySQL/MariaDB escapes backslashes for the default SQL mode, which is the
  wrong escaping under `NO_BACKSLASH_ESCAPES`. The file says which mode it was written for in a
  comment at the top.
- A `.sql` export for PostgreSQL/DuckDB writes `E'…'` literals, so the file replays the same
  whatever `standard_conforming_strings` is set to. That syntax is not portable to the other
  engines.
- SQLite exposes no schema level (attached databases are out of scope) and has no
  `EXPLAIN ANALYZE` or row estimate.
- PostgreSQL and SQL Server have no native DDL statement, so `D` shows a DDL reconstructed from
  the catalog. It is meant to be read, not replayed.
- Every call spawns a fresh client process, so an affected-row count has to ride along in the
  same invocation. An adapter with no affected-rows query (PostgreSQL, DuckDB) reports none.
- Outside a transaction the exactly-one-row guard and the write it guards are two separate
  client invocations, so a concurrent writer between them is not excluded.
- `sqlite3 -ascii` escapes control bytes into caret notation on output, so a cell holding one
  reads back as `^_` rather than the byte. Framing is unaffected; the cell value is not exact.
- On PostgreSQL a value that is exactly the single byte `0x1D` is indistinguishable from `NULL`,
  because that is the NULL marker psql prints unquoted. Every other value round-trips.
- An unrecognised statement verb is treated as a write. On a read-only connection that means a
  dialect feature dblens does not know about is refused rather than run.
- A LOCKED connection is not a sandbox around a user who already holds write credentials. The
  side-channel refusal matches names and a `SECURITY DEFINER` wrapper defeats it; a database
  [read-only role](#a-database-read-only-role-the-hard-boundary) is the hard boundary. Both are
  spelled out, with what each does and does not cover, in the safety model above.
- **SQL Server's locked mode is best-effort (beta)**, enforced by dblens rather than the engine:
  a verb blocklist over a language dblens does not parse, so it cannot be proven complete against
  every administrative statement. Connect as a
  [read-only SQL login](#connect-as-a-read-only-sql-login) for a hard boundary, and read
  [SQL Server: a weaker lock](#sql-server-a-weaker-lock) first.

## Troubleshooting

Start with `:checkhealth dblens` — it reports the Neovim version, every database client it found
(and its version), each connection's kind and access, and which optional integrations are
installed. Most of the below shows up there first.

- **"unknown database kind"** — a `kind` in `setup{}` or the connections file is misspelled, or
  not one of the six; see the [Connections](#connections) table for the accepted spellings.
- **A client is not found** — `:checkhealth dblens` names the binary it looked for. Install it, or
  point `clients.<kind>` at it in `setup{}` if it is not on your `PATH`.
- **A "connection `X` is read-only" message on a run that looks like a read** — that message comes
  from a best-effort classifier that decides whether to prompt, not whether a write is allowed; see
  [Safety model](#safety-model). It should never refuse a genuine `SELECT` — if it does, that is
  worth reporting.
- **A write is refused with a database error, not a dblens prompt** — that is the read-only
  transaction or file mode doing its job on a LOCKED connection, working as intended. Unlock with
  `:DbLensWrite` (`<leader>dw`) to write.
- **A `password_cmd` fails silently** — dblens never shows a `password_cmd`'s output, because that
  output is the secret; check the command runs and prints the password as its first line outside
  dblens.
- **Keymaps do not match what is documented** — `?` (`<localleader>?` in the SQL editor) always
  shows the live bindings for the current pane, generated from your actual `keymaps` overrides.
- **which-key does not label `<leader>d`** — that only happens with
  [which-key](https://github.com/folke/which-key.nvim) installed; dblens does nothing without it.

Still stuck? Open an issue with the output of `:checkhealth dblens` and your Neovim version.

## Contributing

Issues and pull requests are welcome. A change to plugin behaviour needs a MiniTest case under
`tests/spec/`; a change to a keymap or a config option needs the README and vimdoc tables kept in
sync — `tests/spec/keymaps_spec.lua` and `tests/spec/commands_spec.lua` fail the suite when they
drift from `lua/dblens/keymaps.lua`, the single source of truth for bindings.

```sh
make test    # MiniTest, headless
make lint    # stylua --check, luacheck
make format  # stylua
```

CI runs both against Neovim stable and nightly; see `.github/workflows/ci.yml`.

## License

[MIT](LICENSE).
