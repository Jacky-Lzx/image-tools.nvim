vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local I = require("image_tools.workflow.insert")
local tmp = assert(vim.env.IMAGE_TOOLS_TEST_TMP) .. "/insert"
vim.fn.mkdir(tmp, "p")
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function buffer(name, line)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/" .. name .. ".md")
  vim.bo.filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line or "原始内容" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return buf
end
local function run(paths, opts)
  local done, err, outputs = false
  I.files(paths, opts, function(e, o)
    done, err, outputs = true, e, o
  end)
  assert(
    vim.wait(2000, function()
      return done
    end),
    "Import timeout"
  )
  return err, outputs
end
local buf = buffer("copy")
local err, outputs = run({ fixture, fixture }, { filename = "space ] % 图.png" })
check(not err and #outputs == 2, err)
check(outputs[1]:find("space ] %% 图.png", 1) ~= nil, "Requested name preserved")
check(outputs[2]:find("space ] %% 图%-1.png") ~= nil, "Collision gets suffix")
check(vim.fn.readblob(outputs[1]) == vim.fn.readblob(fixture), "Copy bytes unchanged")
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check(#lines == 3, "Batch order")
local options = { max_scan_lines = 1000 }
check(require("image_tools.document").at_line(buf, 2, options) == outputs[1], "Escaped link resolves")
check(require("image_tools.document").at_line(buf, 3, options) == outputs[2], "Second link resolves")
-- Undo must remove the batch as one edit, leaving imported resources reusable.
vim.cmd("undo")
check(
  vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "原始内容" }),
  "Batch undo preserves previous edits"
)
check(vim.uv.fs_stat(outputs[1]) ~= nil, "Undo retains resource")
for _, strategy in ipairs({ "insert_before", "insert_after", "insert_line_before", "insert_line_after" }) do
  buf = buffer(strategy, "你尾")
  err = run({ fixture }, { mode = "reference", insert_strategy = strategy })
  check(not err, err)
  lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if strategy == "insert_before" then
    check(lines[1]:sub(-6) == "你尾", strategy)
  elseif strategy == "insert_after" then
    check(lines[1]:sub(1, 3) == "你" and lines[1]:sub(-3) == "尾", "UTF8 not split")
  elseif strategy == "insert_line_before" then
    check(lines[2] == "你尾", strategy)
  else
    check(lines[1] == "你尾" and #lines == 2, strategy)
  end
end
-- Deferred filename prompt: edits and window switching cannot redirect import.
buf = buffer("deferred")
local input, original = nil, vim.ui.input
vim.ui.input = function(_, cb)
  input = cb
end
local done
I.files({ fixture }, { prompt_for_file_name = true }, function(e)
  err, done = e, true
end)
assert(vim.wait(500, function()
  return input ~= nil
end))
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "added" })
local other = buffer("other")
input("deferred")
assert(vim.wait(2000, function()
  return done
end))
check(not err, err)
check(#vim.api.nvim_buf_get_lines(other, 0, -1, false) == 1, "Current buffer untouched")
check(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:match("deferred.png"), "Extmark follows edited source row")
-- Cancellation, traversal and a late source failure leave no imported assets/text.
for _, name in ipairs({ false, "../escape" }) do
  buf = buffer("cancel" .. tostring(name))
  input, done = nil, nil
  I.files({ fixture }, { prompt_for_file_name = true, directory = "cancel" }, function(e)
    err, done = e, true
  end)
  assert(vim.wait(500, function()
    return input ~= nil
  end))
  input(name or nil)
  check(done and err ~= nil, "Prompt fails/cancels")
  check(#vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 1, "No text on cancellation")
end
vim.ui.input = original
buf = buffer("rollback")
err = run({ fixture, tmp .. "/missing.png" }, { directory = "rollback" })
check(err ~= nil, "Missing second source fails")
check(#vim.fn.glob(tmp .. "/rollback/*", false, true) == 0, "Earlier resource rolled back")
check(#vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 1, "Batch text not partially inserted")
buf = buffer("readonly")
done, err = false, nil
local cancel = I.files({ fixture }, { directory = "readonly" }, function(e)
  err, done = e, true
end)
vim.bo[buf].modifiable = false
assert(vim.wait(2000, function()
  return done and err ~= nil
end))
check(#vim.fn.glob(tmp .. "/readonly/*", false, true) == 0, "Readonly target rolls back assets")
cancel()
check(I.relative(tmp .. "/Pictures/a.png", tmp .. "/docs") == "../Pictures/a.png", "Sibling path")
-- Optional content reuse never makes an existing file transaction-owned.
buf = buffer("dedup")
err, outputs = run({ fixture, fixture }, { directory = "dedup", deduplicate = true })
check(not err and outputs[1] == outputs[2], "Batch dedup reuses identical bytes")
local existing = outputs[1]
check(#vim.fn.glob(tmp .. "/dedup/*", false, true) == 1, "One deduplicated resource")
buffer("dedup-rollback")
err = run({ fixture, tmp .. "/missing.png" }, { directory = "dedup", deduplicate = true })
check(err and vim.uv.fs_stat(existing), "Rollback preserves reused pre-existing file")
buffer("dedup-new-rollback")
err = run({ fixture, fixture, tmp .. "/missing.png" }, { directory = "dedup-new", deduplicate = true })
check(err and #vim.fn.glob(tmp .. "/dedup-new/*", false, true) == 0, "Rollback removes only new deduplicated assets")
local binary_a, binary_b = tmp .. "/binary-a.png", tmp .. "/binary-b.png"
for path, data in pairs({ [binary_a] = "a\0b", [binary_b] = "a\0c" }) do
  local fd = assert(vim.uv.fs_open(path, "w", 438))
  assert(vim.uv.fs_write(fd, data, 0))
  vim.uv.fs_close(fd)
end
buffer("dedup-binary")
err, outputs = run({ binary_a, binary_b, binary_a }, { directory = "binary", deduplicate = true })
check(
  not err and outputs[1] ~= outputs[2] and outputs[1] == outputs[3],
  "Same-sized binary content hashes distinguish different bytes and reuse identical bytes"
)
vim.fn.mkdir(tmp .. "/symlink", "p")
vim.uv.fs_symlink(fixture, tmp .. "/symlink/existing.png")
buffer("dedup-symlink")
err, outputs = run({ fixture }, { directory = "symlink", deduplicate = true })
check(not err and outputs[1] ~= tmp .. "/symlink/existing.png", "Dedup does not reuse symlinks")
local content = require("image_tools.workflow.content")
local find, stopped, pending_hash = content.find, false, nil
content.find = function(_, _, _, _, cb)
  pending_hash = cb
  return function()
    stopped = true
  end
end
buffer("cancel-hash")
done = false
cancel = I.files({ fixture }, { directory = "cancel-hash", deduplicate = true }, function(e)
  err, done = e, true
end)
assert(vim.wait(2000, function()
  return pending_hash ~= nil
end))
cancel()
check(stopped and done and err, "Cancellation stops pending content inspection")
pending_hash(nil, existing)
check(#vim.fn.glob(tmp .. "/cancel-hash/*", false, true) == 0, "Late hash completion cannot publish assets")
content.find = find
print("insert: " .. count .. " assertions passed")
