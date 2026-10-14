vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.opt.rtp:append(assert(vim.env.IMAGE_TOOLS_PARSER_ROOT))
vim.g._ts_force_sync_parsing = true -- deterministic ranges; production remains asynchronous
local TS, D = require("image_tools.document.treesitter"), require("image_tools.document")
local count, ranges = 0, {}
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local parse = vim.treesitter.query.parse
vim.treesitter.query.parse = function(...)
  local query = parse(...)
  return {
    captures = query.captures,
    iter_captures = function(_, node, buf, first, last)
      ranges[#ranges + 1] = { first, last }
      return query:iter_captures(node, buf, first, last)
    end,
  }
end
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = "typst"
local lines = {}
for i = 1, 50 do
  lines[i] = "normal text"
end
lines[1], lines[50] = '#image("a.png")', '#image("b.png")'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
check(TS.query(buf, 1, "typst").candidates[1].src == "a.png", "First image indexed")
check(vim.deep_equal(ranges[1], { 0, 1 }), "Target line bounds capture traversal")
check(TS.query(buf, 50, "typst").candidates[1].src == "b.png", "Later target extends prefix")
check(vim.deep_equal(ranges[2], { 1, 50 }), "Only unindexed suffix traversed")
TS.query(buf, 1, "typst")
check(#ranges == 2, "Previous target is a cache hit")
vim.api.nvim_buf_set_lines(buf, 49, 50, false, { '#image("c.png")' })
check(TS.query(buf, 50, "typst").candidates[1].src == "c.png", "Tail edit changes cached path")
check(ranges[3][1] > 0 and ranges[3][2] == 50, "Tail edit retains valid prefix")
TS.query(buf, 1, "typst")
check(#ranges == 3, "Tail edit preserves earlier target cache")
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "```typst" })
local syntax = TS.query(buf, 51, "typst")
check(not syntax or #syntax.candidates == 0, "New enclosing raw context invalidates earlier captures")
local before = #ranges
check(not D.at_line(buf, 51, { max_scan_lines = 10 }), "Out of limit rejected before query")
check(#ranges == before, "Rejected request performs no index traversal")
vim.api.nvim_buf_delete(buf, { force = true })
vim.treesitter.query.parse = parse
print("incremental treesitter: " .. count .. " assertions passed")
