vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local D, C, T =
  require("image_tools.document"), require("image_tools.document.syntax_cache"), require("image_tools.document.typst")
local tmp = assert(vim.uv.fs_realpath(assert(vim.env.IMAGE_TOOLS_TEST_TMP)))
local opts, checks = { max_scan_lines = 10000, treesitter = false, math = { enabled = false } }, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function buffer(ft, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, tmp .. "/cache-" .. ft .. "-" .. checks)
  vim.bo[buf].filetype = ft
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end
local original_get = vim.api.nvim_buf_get_lines
local calls = {}
vim.api.nvim_buf_get_lines = function(buf, first, last, ...)
  calls[#calls + 1] = { first, last }
  return original_get(buf, first, last, ...)
end
for _, ft in ipairs({ "tex", "typst" }) do
  local lines = {}
  for i = 1, 10000 do
    lines[i] = "Ordinary content without image calls"
  end
  local buf = buffer(ft, lines)
  calls = {}
  check(not D.at_line(buf, 10000, opts), "No image in " .. ft)
  local fetched = 0
  for _, call in ipairs(calls) do
    fetched = fetched + call[2] - call[1]
  end
  check(
    ft == "tex" and fetched <= 128 and calls[1][1] >= 9872
      or ft == "typst" and #calls == 1 and calls[1][2] == 10000 and calls[1][1] == 9999,
    "Plain line performs bounded local reads in " .. ft
  )
end
-- Warm candidate syntax reuses checkpoints; dynamic resolution is never cached.
local lines = {}
for i = 1, 300 do
  lines[i] = "ordinary"
end
lines[1] = "/* comment"
lines[129] = "*/ #figure("
lines[257] = 'image("relative.png"),'
lines[258] = ")"
lines[300] = '#image("/relative.png")'
local buf = buffer("typst", lines)
check(D.at_line(buf, 257, opts) == tmp .. "/relative.png", "Context spans both checkpoints")
local reference = T.scan(original_get(buf, 0, 257, false))[1]
check(reference and reference.src == "relative.png", "Cached lexer agrees with full lexer")
calls = {}
check(D.at_line(buf, 257, opts) == tmp .. "/relative.png", "Repeated candidate resolves")
check(#calls == 1 and calls[1][1] == 256, "Warm candidate does not rescan prefix")
check(
  D.at_line(buf, 300, vim.tbl_extend("force", opts, { root = "/private/tmp/new-root" }))
    == "/private/tmp/new-root/relative.png",
  "Root changes remain visible"
)
check(D.at_line(
  buf,
  300,
  vim.tbl_extend("force", opts, {
    resolve = function()
      return "/private/tmp/custom.png"
    end,
  })
) == "/private/tmp/custom.png", "Resolver changes remain visible")
vim.api.nvim_buf_set_lines(buf, 128, 129, false, { "still inside comment" })
check(not D.at_line(buf, 257, opts), "Prefix edit invalidates cached lexical state")
vim.api.nvim_buf_set_lines(buf, 128, 129, false, { "*/ #figure(" })
check(D.at_line(buf, 257, opts) == tmp .. "/relative.png", "Restoring prefix recovers result")
vim.api.nvim_buf_set_lines(buf, 256, 257, false, { 'image("replacement.png"),' })
check(D.at_line(buf, 257, opts) == tmp .. "/replacement.png", "Candidate edit invalidates parsed result")
-- Negatives inside raw blocks are cached, then invalidated by edits.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```typst", '#image("a.png")' })
check(not D.at_line(buf, 2, opts), "Raw block excludes candidate")
calls = {}
check(not D.at_line(buf, 2, opts) and #calls == 1, "Negative candidate syntax is cached")
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "ordinary" })
check(D.at_line(buf, 2, opts) == tmp .. "/a.png", "Raw fence edit invalidates negative result")
local markdown = buffer("markdown", { "```md", "![x](a.png)" })
check(not D.at_line(markdown, 2, opts), "Markdown fence context")
vim.api.nvim_buf_set_lines(markdown, 0, 1, false, { "ordinary" })
check(D.at_line(markdown, 2, opts) == tmp .. "/a.png", "Markdown fence invalidation")
vim.fn.mkdir(tmp .. "/one", "p")
vim.fn.mkdir(tmp .. "/two", "p")
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
vim.uv.fs_copyfile(fixture, tmp .. "/one/a.png")
vim.uv.fs_copyfile(fixture, tmp .. "/two/a.png")
local tex = buffer("tex", { "\\graphicspath{{one/}}", "\\includegraphics{a}" })
check(D.at_line(tex, 2, opts) == tmp .. "/one/a.png", "Cached graphicspath resolves")
vim.api.nvim_buf_set_lines(tex, 0, 1, false, { "\\graphicspath{{two/}}" })
check(D.at_line(tex, 2, opts) == tmp .. "/two/a.png", "Graphicspath edit invalidates context")
vim.uv.fs_unlink(tmp .. "/two/a.png")
check(not D.at_line(tex, 2, opts), "Removing target is not hidden by syntax cache")
vim.uv.fs_copyfile(fixture, tmp .. "/two/a.png")
check(D.at_line(tex, 2, opts) == tmp .. "/two/a.png", "Creating target is not hidden by negative resolution")
-- Bounded query eviction and detach/re-attach preserve correctness.
local simple = buffer("markdown", lines)
local visits = 0
local function scan(part, state)
  visits = visits + #part
  return { total = (state.total or 0) + #part }, { total = (state.total or 0) + #part }
end
check(C.query(simple, 300, "test", {}, scan).total == 300, "Checkpoint query result")
local before = visits
check(C.query(simple, 300, "test", {}, scan).total == 300 and visits == before, "Repeated query skips scanner")
for row = 1, 140 do
  C.query(simple, row, "test", {}, scan)
end
check(C.query(simple, 300, "test", {}, scan).total == 300, "Evicted query reuses checkpoints correctly")
-- Editing, inserting and deleting in the suffix preserve earlier checkpoints/results.
C.query(simple, 257, "test", {}, scan)
C.query(simple, 300, "test", {}, scan)
vim.api.nvim_buf_set_lines(simple, 290, 291, false, { "edited" })
before = visits
check(
  C.query(simple, 257, "test", {}, scan).total == 257 and visits == before,
  "Suffix edit preserves an earlier query"
)
check(
  C.query(simple, 300, "test", {}, scan).total == 300 and visits - before == 44,
  "Suffix edit scans only from the preserved checkpoint"
)
vim.api.nvim_buf_set_lines(simple, 256, 256, false, { "inserted" })
before = visits
check(
  C.query(simple, 301, "test", {}, scan).total == 301 and visits - before == 45,
  "Insertion on a checkpoint boundary retains the exact prefix"
)
vim.api.nvim_buf_set_lines(simple, 128, 257, false, {})
before = visits
check(
  C.query(simple, 172, "test", {}, scan).total == 172 and visits - before == 44,
  "Deletion invalidates shifted queries and later checkpoints"
)
vim.cmd("bunload! " .. simple)
vim.fn.bufload(simple)
vim.api.nvim_buf_set_lines(simple, 0, -1, false, lines)
check(C.query(simple, 300, "test", {}, scan).total == 300, "Unload allows cache recreation")
vim.api.nvim_buf_delete(simple, { force = true })
vim.api.nvim_buf_get_lines = original_get
print("syntax cache: " .. checks .. " assertions passed")
