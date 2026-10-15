-- Run from the repository with Neovim's clean headless Lua runner.
local root = vim.env.IMAGE_TOOLS_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(root)
local D = require("image_tools.document")
local opts = { max_scan_lines = 10000, treesitter = false }
local fixture = root .. "/tests/fixtures/fixture.png"
local function measure(run, count, before)
  local values = {}
  for i = 1, count do
    if before then
      before(i)
    end
    local start = vim.uv.hrtime()
    run(i)
    values[i] = (vim.uv.hrtime() - start) / 1e6
  end
  table.sort(values)
  return string.format("p50=%.3f p95=%.3f ms", values[math.ceil(count * 0.5)], values[math.ceil(count * 0.95)])
end
for _, size in ipairs({ 1000, 10000 }) do
  for _, ft in ipairs({ "markdown", "tex", "typst" }) do
    local image = ft == "markdown" and ("![x](" .. fixture .. ")")
      or ft == "tex" and ("\\includegraphics{" .. fixture .. "}")
      or ('#image("' .. fixture .. '")')
    local lines = {}
    for row = 1, size do
      lines[row] = row >= size - 100 and image or "ordinary text"
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = ft
    vim.api.nvim_buf_set_name(buf, "/private/tmp/benchmark-" .. size .. "." .. ft)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local cold = measure(
      function()
        assert(D.at_line(buf, size, opts))
      end,
      20,
      function(i)
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "cold " .. i })
      end
    )
    local warm = measure(function()
      assert(D.at_line(buf, size, opts))
    end, 100)
    local edit = measure(function(i)
      vim.api.nvim_buf_set_lines(buf, size - 2, size - 1, false, { "edit " .. i })
      assert(D.at_line(buf, size, opts))
    end, 100)
    vim.api.nvim_buf_set_lines(buf, size - 2, size - 1, false, { image })
    local movement = measure(function(i)
      assert(D.at_line(buf, size - 100 + i, opts))
    end, 100)
    print(string.format("%s %d: cold %s; warm %s; tail edit %s; movement %s", ft, size, cold, warm, edit, movement))
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end
