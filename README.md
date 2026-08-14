# dblens.nvim

A database viewer for Neovim. dblens gives you a schema tree, a paged result grid and a SQL
scratch buffer in one tab page, and drives SQLite, PostgreSQL and MySQL through the `sqlite3`,
`psql` and `mysql` command-line clients you already have installed. There is no compiled
component and no server: every query is a one-shot client process, decoded through a record
protocol chosen so that a SQL `NULL` is never confused with the text `NULL`. Every statement
goes through a single gate that enforces read-only connections, a confirmation preview, and a
`count(*)` guard proving a row-targeted edit matches exactly one row — and that treats anything
it cannot prove is a read as a write.

## Requirements

- Neovim >= 0.10
- The client for each database you want to reach:
  - SQLite -> `sqlite3` >= 3.34, for the `-safe` flag that refuses `.shell`, `.load` and ATTACH
  - PostgreSQL -> `psql`
  - MySQL / MariaDB -> `mysql`

No compiled dependencies. A missing client only makes that one database kind unavailable;
`:checkhealth dblens` reports which ones it found.

## Install

The plugin works with no `setup{}` call at all — the commands, the default keymaps and the
default configuration are all applied on load. Call `setup{}` only to change something.

**lazy.nvim**

```lua
{ 'dblens/dblens.nvim' }
```

**packer**

```lua
use 'dblens/dblens.nvim'
```

Then `:DbLens` to open, `:DbLensAdd` to add your first connection.

## Features

**Browse**

- Schema tree: connection -> schema -> table/view -> columns, indexes, constraints.
- Primary key, foreign key, NOT NULL and type shown per column.
- `SHOW CREATE TABLE` / `sqlite_schema` DDL where the server has it, reconstructed from the
  catalog where it does not (PostgreSQL).
- Row counts on demand, and a schema reload.

**Query**

- SQL scratch buffer: run the statement at the cursor, the visual selection, or the whole
  buffer. Multiple statements run in order and stop at the first error.
- `EXPLAIN` and, where the server supports it, `EXPLAIN ANALYZE`.
- Cancel a running query.
- Query history and named snippets, persisted to disk.
- Schema-aware completion: keywords, tables, views, and columns qualified by table name or
  FROM/JOIN alias. Works through `omnifunc`, nvim-cmp or blink.cmp.

**Edit**

- Edit a cell, insert a row (by editing the generated `INSERT`), delete a row.
- Every change is previewed as the exact SQL that will run before it runs.
- Yank a cell, a row as CSV, as JSON, or as an `INSERT`; export the whole result to CSV or JSON.

**Safety**

- Per-connection `read_only`, refused at the session, not in the UI.
- Confirmation gate for destructive statements (on by default), optionally for all writes.
- Row-targeted edits carry a `count(*)` guard that must return exactly 1.
- Planner row estimate shown before a single destructive ad-hoc statement, where the adapter
  can produce one without running it.
- Deferred-batch transaction mode with a pending-changes view.
- A plaintext password is refused in a connection spec.

**Extras**

- Server-side sort and WHERE filter on a browsed table, with paging.
- `:checkhealth dblens`.
- A `statusline()` segment: connection, read-only, transaction state, running query.
- Highlights derived from your colorscheme, re-derived on `:colorscheme`.
- Three icon sets: plain Unicode (default), Nerd Font, or ASCII.

## Connections

A connection is a table with a `name`, a `kind` (`sqlite`, `postgres`, `mysql`; the aliases
`sqlite3`, `postgresql`, `pg`, `psql`, `mariadb` are accepted), the fields that kind requires,
and optionally `read_only`.

### In `setup{}`

```lua
require('dblens').setup({
  connections = {
    -- sqlite: needs `path`. `create = true` allows opening a file that does not exist yet.
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
    read_only_default   = false,  -- applied to connections that do not set `read_only` themselves
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
    icons  = true,                -- true = plain Unicode, 'nerd' = Nerd Font glyphs, false = ASCII
    winbar = true,                -- status winbar above each pane
    sidebar = {
      width    = 34,
      position = 'left',          -- 'left' | 'right'
    },
    results = {
      height = 0.55,              -- share of the main column given to results; fraction, 0 < h < 1
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
    postgres = 'psql',
    mysql    = 'mysql',
  },

  -- Per-scope action -> lhs overrides. `false` disables a binding. See the keymap tables below
  -- for the action names; an unknown action is an error, not a silent no-op.
  keymaps = {
    -- Per action: a key, a list of keys, or false to drop that binding.
    -- A whole scope can be `false` to bind nothing in it -- `global = false` is the escape
    -- hatch for the ten `<leader>d*` maps.
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
| `:DbLensConnections` | Open dblens, or pick a connection if it is already open |
| `:DbLensAdd` | Add a connection interactively |
| `:DbLensRemove {name}` | Remove a saved connection (completes names) |
| `:DbLensRestore` | Reopen the last saved session |

## Keymaps

Every binding is declared in one table and can be remapped or disabled per scope through
`keymaps` in `setup{}`. `?` shows the live list inside any dblens window.

### Global

| lhs | Action | Description |
| --- | --- | --- |
| `<leader>dd` | `toggle` | Toggle dblens |
| `<leader>dc` | `connections` | Pick a connection |
| `<leader>dq` | `query` | Focus the SQL editor |
| `<leader>dt` | `tables` | Find a table |
| `<leader>dh` | `history` | Query history |
| `<leader>ds` | `snippets` | Saved snippets |
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
| `c` | `row_count` | Count rows |
| `D` | `ddl` | Show the DDL |
| `R` | `refresh` | Reload the schema |
| `?` | `help` | This help |
| `q` | `close` | Close dblens |

### Results grid

| lhs | Action | Description |
| --- | --- | --- |
| `<CR>` / `K` | `detail` | Row detail |
| `]p` | `next_page` | Next page |
| `[p` | `prev_page` | Previous page |
| `s` | `sort` | Sort by this column |
| `f` | `filter` | Filter rows (WHERE) |
| `R` | `refresh` | Re-run the query |
| `e` | `edit_cell` | Edit this cell |
| `i` | `insert_row` | Insert a row |
| `dd` | `delete_row` | Delete this row |
| `y` | `yank_cell` | Yank the cell |
| `Y` | `yank_row` | Yank the row as CSV |
| `gy` | `yank_json` | Yank the row as JSON |
| `gi` | `yank_insert` | Yank the row as INSERT |
| `X` | `export` | Export the result to a file |
| `?` | `help` | This help |
| `q` | `close` | Close dblens |

### SQL editor

| lhs | Mode | Action | Description |
| --- | --- | --- | --- |
| `<CR>` | n | `run` | Run the statement at the cursor |
| `<CR>` | x | `run_selection` | Run the selection |
| `<localleader>r` | n | `run_all` | Run the whole buffer |
| `<localleader>e` | n | `explain` | EXPLAIN the statement |
| `<localleader>E` | n | `explain_analyze` | EXPLAIN ANALYZE |
| `<C-c>` | n | `cancel` | Cancel the running query |
| `<localleader>s` | n | `save_snippet` | Save as a snippet |
| `<localleader>h` | n | `history` | Query history |
| `?` | n | `help` | This help |
| `<localleader>q` | n | `close` | Close dblens |

## Safety model

**One gate.** Every statement dblens sends — a browsed page, a filter, ad-hoc editor SQL,
`EXPLAIN`, a cell edit, a committed batch — goes through `Session:run`, which puts it through
`Session:gate` before a client process exists. Read-only, the confirmation requirement and the
refusal of client meta-commands are enforced there, not in whichever part of the UI asked.

**The read proof fails closed.** A statement counts as a read only when dblens can *prove* it
is one: a single statement led by `SELECT`, `WITH`, `VALUES`, `TABLE`, `SHOW`, `DESCRIBE`, a
reporting `PRAGMA`, or an `EXPLAIN` that does not `ANALYZE`; with no write verb anywhere in it,
no `INTO`/`OUTFILE` redirect, no stacked second statement and no punctuation outside the set
that appears in real SQL operators. **Everything else is treated as a write**, including verbs
dblens does not recognise. So `WITH d AS (DELETE …) SELECT …`, `COPY … FROM PROGRAM`,
`DO $$ … $$`, `CALL`, `SELECT … INTO`, `PRAGMA user_version = 42` and `SELECT 1; DROP TABLE t`
are all writes, and all refused on a read-only connection.

`EXPLAIN ANALYZE` is classified by the statement *inside* it, because on PostgreSQL and MySQL it
**runs** that statement. `EXPLAIN ANALYZE DELETE …` is therefore a destructive write: refused on
a read-only connection, and gated by the destructive confirmation elsewhere, with the float
saying plainly that it will run. Plain `EXPLAIN` only plans, and stays a read.

**Client meta-commands never reach a client.** `psql` runs `\!` as a shell command in the middle
of a statement, and `sqlite3 -batch` still honours `.shell`. Neither is SQL, so no connection
flag covers them; the gate refuses any statement starting with `.` or containing an unquoted
`\`, on every connection. sqlite3 is additionally run with `-safe`, which refuses `.shell`,
`.load`, `.import` and `ATTACH` at the client.

**Read-only connections.** A connection with `read_only = true` (or every connection, with
`safety.read_only_default = true`) refuses every write and every commit, naming the connection.

**The confirm gate.** `UPDATE`, `DELETE`, `REPLACE`, `MERGE`, `DROP`, `TRUNCATE`, `ALTER`,
`RENAME`, `GRANT` and `REVOKE` are destructive; other writes are not. With
`safety.confirm_destructive = true` (the default) a destructive statement is shown in a preview
float — the exact SQL, the verb and target, and a flag when it affects a whole object with no
`WHERE` — and runs only when you confirm. `safety.confirm_write = true` extends the same gate to
non-destructive writes. The two are evaluated per class, so a script holding both an `INSERT` and
a `DROP` is gated by both settings. An unconfirmed write is refused by the session, not merely
undrawn.

Before a single destructive ad-hoc statement, adapters that can estimate without executing
(`caps.estimate_rows`: PostgreSQL via `EXPLAIN (FORMAT JSON)`, MySQL via `EXPLAIN`) show the
planner's row estimate. SQLite cannot, and says so; a failed estimate says why.

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
substitution only. A backtick, a wildcard or a leading `-` is rejected when the connection is
validated, so a hostile shared `connections.json` cannot run a command by being opened.

**Filters are vetted by an allow-list.** A `WHERE` typed into the results filter is checked
before it is spliced into a statement. Rejected: any write verb, a comment (which would comment
out the `LIMIT`/`OFFSET` appended after it), a backslash, an unclosed quote, and any punctuation
outside the SQL operator set — which drops `;` and `\` together. A column named after a SQL verb
can still be filtered on by quoting it. The filter bar is still raw SQL: the check stops it
escaping the statement, it does not stop an expensive or volatile function call.

## Transactions

CLI clients are one-shot processes, so a transaction cannot be held open across calls the way a
socket session could. dblens therefore *defers*.

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

`:checkhealth dblens` reports the Neovim version, whether the configuration loaded and where its
files live, each database client and its version, every connection with its kind, access and
whether it has a password reference, and which optional integrations are installed. It never
resolves a password.

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
| `DbLensOk` | `DiagnosticOk` | |
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
| `DbLensStatus` | `StatusLine` | status |
| `DbLensSpinner` | `DiagnosticInfo` | status |
| `DbLensReadOnly` | `DiagnosticWarn` | status |
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
dblens.statusline()         -- 'prod · read-only · TXN 2 pending · query…', '' when closed
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

**MySQL is implemented but was not exercised against a live server.** It implements the same
interface as the other two, and its statement builders, command construction and `--xml`
decoding are unit-tested — the XML output exists because the default tab format cannot
distinguish SQL `NULL` from the string `'NULL'` — but no `mysql` client or server was reachable.
Its transaction row guard in particular relies on MySQL aborting a scalar subquery that returns
two rows, which is reasoned from the documentation, not observed. Please report what you hit.

## Limitations

- A result is capped at `max_rows` rows for rendering; the SQL is never rewritten, so the client
  still does the full work. Client output is capped at `max_bytes`.
- Sorting and filtering apply to a browsed table only. For a query result, put `ORDER BY` /
  `WHERE` in the query.
- SQLite exposes no schema level (attached databases are out of scope) and has no
  `EXPLAIN ANALYZE` or row estimate.
- PostgreSQL has no native DDL statement, so `D` shows a DDL reconstructed from the catalog. It
  is meant to be read, not replayed.
- Every call spawns a fresh client process, so an affected-row count has to ride along in the
  same invocation. An adapter with no affected-rows query (PostgreSQL) reports none.
- Outside a transaction the exactly-one-row guard and the write it guards are two separate
  client invocations, so a concurrent writer between them is not excluded.
- `sqlite3 -ascii` escapes control bytes into caret notation on output, so a cell holding one
  reads back as `^_` rather than the byte. Framing is unaffected; the cell value is not exact.
- On PostgreSQL a value that is exactly the single byte `0x1D` is indistinguishable from `NULL`,
  because that is the NULL marker psql prints unquoted. Every other value round-trips.
- An unrecognised statement verb is treated as a write. On a read-only connection that means a
  dialect feature dblens does not know about is refused rather than run.

## Development

```sh
make test    # MiniTest, headless
make lint    # stylua --check, luacheck
make format  # stylua
```
