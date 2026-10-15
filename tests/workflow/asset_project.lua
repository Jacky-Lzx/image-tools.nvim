vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local uv = vim.uv
local root = vim.env.IMAGE_TOOLS_TEST_TMP .. "/project"
vim.fn.mkdir(root .. "/Figures/nested", "p")
vim.fn.mkdir(root .. "/chapters", "p")
vim.fn.mkdir(root .. "/node_modules", "p")
vim.fn.mkdir(root .. "/.git", "p")
root = assert(uv.fs_realpath(root))
local function write(path, lines)
  vim.fn.writefile(lines, root .. "/" .. path)
end
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
for _, name in ipairs({ "shared", "other", "unused", "nested/deep" }) do
  assert(uv.fs_copyfile(fixture, root .. "/Figures/" .. name .. ".png"))
end
assert(uv.fs_symlink(root .. "/Figures/unused.png", root .. "/Figures/link.png"))
assert(uv.fs_symlink(root, root .. "/loop"))
write("note.md", { "![shared](Figures/shared.png)", "![missing](Figures/missing.png)" })
write("chapters/second.md", { "![other][id]", "[id]: ../Figures/other.png", "`![skip](../Figures/unused.png)`" })
write("chapter.tex", { "\\includegraphics[", "width=5cm]{Figures/shared}", "\\includegraphics{Figures/nested/deep}" })
write("figure.typ", { '#image("Figures/shared.png")', '// image("Figures/unused.png")' })
write("node_modules/ignored.md", { "![ignored](../Figures/unused.png)" })
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, root .. "/note.md")
vim.bo[buf].filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![shared](Figures/shared.png)", "![missing](Figures/missing.png)" })
local assets = require("image_tools.workflow.assets")
local function run(extra)
  local done, message, result = false, nil, nil
  assets.check(
    vim.tbl_extend(
      "force",
      { scope = "project", max_scan_lines = 10000, insert = { root = root, directory = "Figures" } },
      extra or {}
    ),
    function(err, report)
      message, result, done = err, report, true
    end
  )
  assert(
    vim.wait(5000, function()
      return done
    end, 1),
    "Project inspection timed out"
  )
  assert(not message, message)
  return result
end
local before = vim.api.nvim_list_bufs()
local report = run()
assert(report.project_root == root and #report.documents == 4 and #report.missing == 1, vim.inspect(report))
assert(vim.deep_equal(report.unreferenced, { root .. "/Figures/unused.png" }), vim.inspect(report.unreferenced))
assert(#report.references[root .. "/Figures/shared.png"] == 3, "Shared references include all documents")
assert(report.references[root .. "/Figures/shared.png"][1].filename)
assert(vim.deep_equal(before, vim.api.nvim_list_bufs()), "Offline inspection releases unnamed scratch buffers")
assert(vim.api.nvim_get_current_buf() == buf, "Inspection preserves focus")
-- Live unsaved contents take precedence over the disk document.
local second = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(second, root .. "/chapters/second.md")
vim.bo[second].filetype = "markdown"
vim.api.nvim_buf_set_lines(second, 0, -1, false, { "![live](../Figures/unused.png)" })
report = run()
assert(vim.deep_equal(report.unreferenced, { root .. "/Figures/other.png" }))
assert(report.references[root .. "/Figures/unused.png"][1].filename == root .. "/chapters/second.md")
report = run({ max_scan_lines = 1 })
assert(report.truncated and #report.warnings > 0, "Truncated documents flag incomplete results")
report = run({ assets = { max_entries = 1 } })
assert(report.truncated and #report.warnings > 0, "Traversal budgets flag incomplete results")
report = run({ assets = { max_document_bytes = 1 } })
assert(report.truncated, "Oversized offline documents are skipped explicitly")
local completed, message = false, nil
assets.check({ scope = "project", project_root = root, max_scan_lines = 10000 }, function(err)
  message, completed = err, true
end)
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "changed" })
assert(vim.wait(2000, function()
  return completed
end, 1) and message, "Live edits reject stale reports")
completed = false
local cancel = assets.check({ scope = "project", project_root = root, max_scan_lines = 10000 }, function()
  completed = true
end)
cancel()
vim.wait(20)
assert(not completed, "Cancellation suppresses delivery")
-- Mutating a disk document after its enumeration is caught before publication.
local enumerate = require("image_tools.document").enumerate
require("image_tools.document").enumerate = function(buffer, opts, callback)
  return enumerate(buffer, opts, function(err, result)
    if opts._document_path == root .. "/chapter.tex" then
      write("chapter.tex", { "% changed after scan" })
    end
    callback(err, result)
  end)
end
completed, message = false, nil
assets.check({ scope = "project", project_root = root, max_scan_lines = 10000 }, function(err)
  message, completed = err, true
end)
assert(vim.wait(3000, function()
  return completed
end, 1) and message and message:find("changed on disk", 1, true), tostring(message))
require("image_tools.document").enumerate = enumerate
local held
require("image_tools.document").enumerate = function(buffer, opts, callback)
  if vim.api.nvim_buf_get_name(buffer) == "" then
    held = buffer
    return function() end
  end
  return enumerate(buffer, opts, callback)
end
completed = false
cancel = assets.check({ scope = "project", project_root = root, max_scan_lines = 10000 }, function()
  completed = true
end)
assert(vim.wait(2000, function()
  return held ~= nil
end, 1))
cancel()
assert(not vim.api.nvim_buf_is_valid(held) and not completed, "Mid-scan cancellation releases the offline buffer")
require("image_tools.document").enumerate = enumerate
local api = require("image_tools")
api.setup({ auto_preview = false, insert = { root = root } })
vim.cmd("ImageCheckAssets! " .. root)
assert(
  vim.wait(3000, function()
    return vim.fn.getqflist({ title = 0 }).title == "Image assets: " .. root
  end, 1),
  "Project command populates quickfix"
)
vim.cmd("cclose")
assert(uv.fs_stat(root .. "/Figures/unused.png"), "Project inspection never deletes assets")
print("Project assets: shared references, offline/live documents, limits, symlinks, races and cancellation passed")
