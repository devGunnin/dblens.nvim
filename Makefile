NVIM ?= nvim

.PHONY: test lint format

# `MiniTest.run` quits with 0 or 1 itself. The pcall is for the case it never gets that far:
# a spec that fails to load raises during collection, and an uncaught error there hangs headless
# nvim instead of failing the run.
test:
	$(NVIM) --headless --noplugin -u tests/minit.lua -c "lua local ok, err = pcall(MiniTest.run) if not ok then vim.api.nvim_err_writeln(tostring(err)) vim.cmd('silent! 1cquit') end"

lint:
	stylua --check .
	luacheck lua tests

format:
	stylua .
