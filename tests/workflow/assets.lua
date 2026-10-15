vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local root = vim.env.IMAGE_TOOLS_TEST_TMP .. "/assets"
vim.fn.mkdir(root .. "/Figures", "p")
root = assert(vim.uv.fs_realpath(root))
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
vim.uv.fs_copyfile(fixture, root .. "/Figures/used.png")
vim.uv.fs_copyfile(fixture, root .. "/Figures/unused.png")
vim.uv.fs_symlink(root .. "/Figures/used.png", root .. "/Figures/link.png")
local A = require("image_tools.workflow.assets")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, root .. "/note.md")
local function run(ft, lines)
  vim.bo[buf].filetype = ft
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local done, result, message
  A.check({ buf = buf, max_scan_lines = 10000 }, function(err, report)
    message, result, done = err, report, true
  end)
  assert(
    vim.wait(2000, function()
      return done
    end),
    "Asset check timeout"
  )
  assert(not message, message)
  return result
end
local report = run("markdown", { "![a][id] ![b](missing.png)", "[id]: Figures/used.png", "`![[Figures/unused.png]]`" })
assert(#report.missing == 1 and report.missing[1].lnum == 1)
assert(vim.deep_equal(report.unreferenced, { root .. "/Figures/unused.png" }), vim.inspect(report))
report = run("tex", {
  "\\includegraphics[",
  "width=5cm]{Figures/used}",
  "\\includegraphics{missing}",
  "% \\includegraphics{Figures/unused.png}",
})
assert(#report.missing == 1 and #report.unreferenced == 1, vim.inspect(report))
report = run("typst", { '#image("Figures/used.png") #image("missing.png")', '// image("Figures/unused.png")' })
assert(#report.missing == 1 and #report.unreferenced == 1, vim.inspect(report))
local completed, error
A.check({ max_scan_lines = 1000 }, function(err)
  completed, error = true, err
end)
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "changed" })
assert(vim.wait(1000, function()
  return completed
end) and error, "Stale inspection rejected")
completed = false
local cancel = A.check({ max_scan_lines = 1000 }, function()
  completed = true
end)
cancel()
vim.wait(20)
assert(not completed, "Cancellation suppresses delivery")
assert(vim.uv.fs_stat(root .. "/Figures/unused.png"), "Inspection preserves resources")
print("Asset inspection: Markdown/LaTeX/Typst, stale authority, symlinks and cancellation passed")
