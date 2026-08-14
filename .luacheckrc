std = 'luajit'
cache = true
read_globals = { 'vim' }

-- line length is owned by stylua
max_line_length = false

files['tests/'] = {
  read_globals = { 'MiniTest', 'describe', 'it', 'before_each', 'after_each' },
}
