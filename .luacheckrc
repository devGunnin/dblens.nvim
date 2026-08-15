std = 'luajit'
cache = true
-- `vim` is writable: plugins legitimately set vim.bo/vim.wo/vim.o fields.
globals = { 'vim' }

-- line length is owned by stylua
max_line_length = false

files['tests/'] = {
  read_globals = { 'MiniTest', 'describe', 'it', 'before_each', 'after_each' },
}
