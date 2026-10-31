vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local uv, move = vim.uv, require("image_tools.workflow.move")
local root = assert(uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/move"
vim.fn.mkdir(root .. "/Figures", "p")
local source, target = root .. "/Figures/old.png", root .. "/Figures/new space.png"
assert(uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", source))
local function write(name, lines)
  vim.fn.writefile(lines, root .. "/" .. name)
end
write("live.md", { '![kept](<Figures/old.png> "title") ![[Figures/old.png|label]]', "`![code](Figures/old.png)`" })
write("refs.md", { "![a][id] ![b][ID]", '[id]: <Figures/old.png> "keep title"', "[id]: ignored.png" })
write("paper.tex", { "\\includegraphics[", "width=5cm]{\\detokenize{Figures/old}} % keep", "\\caption{caption}" })
write("note.typ", { '#image("Figures/old.png", width: 50%, alt: "keep")' })
write("page.html", { [[<img alt="src='wrong'" src='Figures/old.png' width=20><img src=Figures/old.png>]] })
-- An unopened CRLF document keeps its line endings and final newline.
vim.fn.writefile({ "![crlf](Figures/old.png)\r", "" }, root .. "/crlf.md", "b")
vim.cmd.edit(root .. "/live.md")
vim.bo.filetype = "markdown"
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "unsaved text" })
local opts = require("image_tools.config").resolve({ auto_preview = false, root = root })
opts.project_root = root
local function plan(extra)
  local done, result, failure
  move.plan(source, target, vim.tbl_extend("force", opts, extra or {}), function(err, value)
    done, failure, result = true, err, value
  end)
  assert(
    vim.wait(5000, function()
      return done
    end, 1),
    "Move planning timed out"
  )
  return result, failure
end
local p, err = plan()
assert(p, err)
assert(#p.changes == 6, vim.inspect(p.changes))
assert(uv.fs_stat(source) and not uv.fs_stat(target), "Planning never moves files")
local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local truncated, failure = plan({ max_scan_lines = 1 })
assert(not truncated and failure:find("incomplete"), tostring(failure))
local stale = assert(plan())
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "changed after preview" })
local ok, message = move.apply(stale)
assert(not ok and message:find("changed since preview"), tostring(message))
vim.api.nvim_buf_set_lines(buf, 0, -1, false, before)
stale = assert(plan())
write("refs.md", { "changed on disk" })
ok, message = move.apply(stale)
assert(not ok and message:find("changed on disk"), tostring(message))
write("refs.md", { "![a][id] ![b][ID]", '[id]: <Figures/old.png> "keep title"', "[id]: ignored.png" })
-- Fail after at least one disk replacement: everything is restored.
p = assert(plan())
local rename, count = uv.fs_rename, 0
uv.fs_rename = function(from, to)
  if from:match("%.tmp$") then
    count = count + 1
    if count == 2 then
      return nil, "injected write failure"
    end
  end
  return rename(from, to)
end
ok, message = move.apply(p)
uv.fs_rename = rename
assert(not ok and message:find("injected write failure"), tostring(message))
assert(uv.fs_stat(source) and not uv.fs_stat(target))
assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
assert(vim.fn.readfile(root .. "/crlf.md", "b")[1] == "![crlf](Figures/old.png)\r", "Rollback preserves exact bytes")
-- Re-plan because restored files have new revisions.
p = assert(plan())
ok, message = move.apply(p)
assert(ok, message)
assert(not uv.fs_stat(source) and uv.fs_stat(target))
assert(vim.bo[buf].modified)
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:find('![kept](<Figures/new%20space.png> "title")', 1, true), text)
assert(text:find("![[Figures/new space.png|label]]", 1, true))
assert(text:find("`![code](Figures/old.png)`", 1, true) and text:find("unsaved text", 1, true))
assert(vim.fn.readfile(root .. "/live.md")[1]:find("Figures/old.png", 1, true), "Live buffers are not silently saved")
local refs = vim.fn.readfile(root .. "/refs.md")
assert(refs[1] == "![a][id] ![b][ID]" and refs[2] == '[id]: <Figures/new%20space.png> "keep title"')
assert(refs[3] == "[id]: ignored.png", "Only the first definition is rewritten")
assert(vim.fn.readfile(root .. "/paper.tex")[2] == "width=5cm]{Figures/new space.png} % keep")
assert(vim.fn.readfile(root .. "/note.typ")[1] == '#image("Figures/new space.png", width: 50%, alt: "keep")')
assert(
  vim.fn.readfile(root .. "/page.html")[1]
    == [[<img alt="src='wrong'" src='Figures/new%20space.png' width=20><img src=Figures/new%20space.png>]]
)
assert(vim.fn.readfile(root .. "/crlf.md", "b")[1] == "![crlf](Figures/new%20space.png)\r")
assert(not move.apply(p), "Plans can only be applied once")
-- Collision and UI cancellation leave the image unchanged.
source, target = target, root .. "/Figures/final.png"
write("Figures/final.png", { "do not overwrite" })
local collision, collision_err = plan()
assert(not collision and collision_err:find("already exists"))
uv.fs_unlink(target)
if vim.env.IMAGE_TOOLS_SELECTION_ROOT then
  vim.opt.rtp:prepend(vim.env.IMAGE_TOOLS_SELECTION_ROOT)
  local selection = require("selection_tools")
  local open, picker = selection.open, nil
  selection.open = function(options)
    picker = open(options)
    return picker
  end
  local completed, cancelled
  move.move(source, target, opts, function(e)
    completed, cancelled = true, e
  end)
  assert(vim.wait(5000, function()
    return picker ~= nil
  end, 1))
  assert(uv.fs_stat(source) and not uv.fs_stat(target), "Diff UI precedes mutation")
  picker:close()
  assert(completed and cancelled == "Cancelled")
  selection.open = open
else
  print("move review: skipped (set IMAGE_TOOLS_SELECTION_ROOT)")
end
assert(uv.fs_stat(source) and not uv.fs_stat(target))
assert(#vim.fn.glob(root .. "/**/*.image-tools-*", false, true) == 0, "No transaction files remain")
print(
  "move: destination-only edits, shared definitions, live buffers, CRLF, stale plans, rollback, collisions and review passed"
)
