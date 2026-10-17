vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local I, C, N =
  require("image_tools.workflow.insert"),
  require("image_tools.workflow.clipboard"),
  require("image_tools.workflow.naming")
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/naming"
vim.fn.mkdir(tmp, "p")
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
local serial = 0
local function buffer()
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/paper-" .. serial .. ".md")
  vim.bo.filetype = "markdown"
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ actual = a, expected = b }))
end
eq(
  N.resolve({ file_name = "photo-%Y" }, { document = "paper.md", timestamp = 12345, kind = "clipboard" }),
  os.date("photo-%Y", 12345)
)
local function run(paths, opts)
  local done, failure, outputs
  I.files(paths, opts, function(err, values)
    failure, outputs, done = err, values, true
  end)
  assert(vim.wait(2000, function()
    return done
  end))
  return failure, outputs
end
buffer()
local failure, outputs = run({ fixture, fixture }, {
  file_name = function(ctx)
    eq(ctx.kind, "file")
    eq(ctx.source_name, "fixture.png")
    eq(ctx.extension, "png")
    return ctx.document_name .. "_figure"
  end,
})
assert(not failure, failure)
eq(vim.fs.basename(outputs[1]), "paper-1_figure.png")
eq(vim.fs.basename(outputs[2]), "paper-1_figure-1.png")
buffer()
failure, outputs = run({ fixture }, {
  filename = "explicit.png",
  file_name = function()
    error("filename must take precedence")
  end,
})
assert(not failure, failure)
eq(vim.fs.basename(outputs[1]), "explicit.png")
buffer()
local calls = 0
failure = run({ fixture, fixture }, {
  directory = "rollback",
  file_name = function()
    calls = calls + 1
    return calls == 1 and "first" or "../outside"
  end,
})
assert(failure)
eq(vim.fn.glob(tmp .. "/rollback/*", false, true), {})
eq(vim.api.nvim_buf_line_count(0), 1)
local executable = tmp .. "/pngpaste"
vim.fn.writefile({ "#!/bin/sh", 'cp "$IMAGE_TOOLS_ROOT/tests/fixtures/fixture.png" "$1"' }, executable)
assert(vim.uv.fs_chmod(executable, 493))
buffer()
local select, time = vim.ui.select, os.time
local choices, choose
vim.ui.select = function(items, _, callback)
  choices, choose = items, callback
end
os.time = function()
  return 12345
end
local done
C.paste({
  pngpaste = executable,
  process = "select",
  file_name = function(ctx)
    eq(ctx.kind, "clipboard")
    eq(ctx.timestamp, 12345)
    eq(ctx.extension, "png")
    return ctx.document_name .. "_clipboard"
  end,
}, function(err, paths)
  failure, outputs, done = err, paths, true
end, { macos = true })
os.time = function()
  return 54321
end
choose(choices[1])
assert(vim.wait(2000, function()
  return done
end))
assert(not failure, failure)
eq(vim.fs.basename(outputs[1]), "paper-4_clipboard.png")
vim.ui.select, os.time = select, time
print("naming: date patterns, function context, precedence, collisions, rollback and captured time passed")
