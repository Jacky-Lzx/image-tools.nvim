vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local C, P = require("image_tools.workflow.clipboard"), require("image_tools.workflow.process")
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/process"
vim.fn.mkdir(tmp, "p")
local executable = tmp .. "/pngpaste"
vim.fn.writefile({ "#!/bin/sh", 'cp "$IMAGE_TOOLS_ROOT/tests/fixtures/fixture.png" "$1"' }, executable)
assert(vim.uv.fs_chmod(executable, 493))
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ actual = a, expected = b }))
end
local serial = 0
local function buffer(ft)
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/note-" .. serial .. ".txt")
  vim.bo.filetype = ft or "markdown"
  return buf
end
local function paste(opts)
  local done, failure, paths
  C.paste(vim.tbl_extend("force", { pngpaste = executable }, opts), function(err, outputs)
    failure, paths, done = err, outputs, true
  end, { macos = true })
  assert(vim.wait(5000, function()
    return done
  end))
  assert(not failure, failure)
  return paths
end
buffer()
local paths = paste({ process = { format = "png", resize = "80x80>" } })
local result = vim.system({ "magick", "identify", "-format", "%m %wx%h", paths[1] }):wait()
eq(result.stdout, "PNG 80x50")
buffer()
paths = paste({ process = { format = "jpg", command = { "magick", "$INPUT", "-resize", "40x40>", "$OUTPUT" } } })
result = vim.system({ "magick", "identify", "-format", "%m %wx%h", paths[1] }):wait()
eq(result.stdout, "JPEG 40x25")
eq(P.command({ command = { "tool", "$INPUT", "$OUTPUT" } }, "100% $INPUT.png", "a b.png"), {
  "tool",
  "100% $INPUT.png",
  "a b.png",
})
eq(pcall(P.validate, { format = "png", command = "magick - -" }), false)
eq(pcall(P.validate, { format = "avif", quality = 101 }), false)
local original, choices, choose = vim.ui.select
vim.ui.select = function(items, _, callback)
  choices, choose = items, callback
end
local buf = buffer("tex")
local done, failure, outputs
C.paste({ pngpaste = executable, process = "select" }, function(err, paths_out)
  failure, outputs, done = err, paths_out, true
end, { macos = true })
eq(#choices, 2)
eq(choices[1].format, "png")
eq(choices[2].format, "jpg")
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "edited" })
local other = buffer()
choose(choices[1])
assert(vim.wait(5000, function()
  return done
end))
assert(not failure, failure)
eq(vim.api.nvim_get_current_buf(), other)
eq(require("image_tools.document").at_line(buf, 5, { treesitter = false, max_scan_lines = 100 }), outputs[1])
buffer()
done = false
local cancel = C.paste({ pngpaste = executable, process = "select" }, function(err)
  failure, done = err, true
end, { macos = true })
cancel()
choose(choices[1])
vim.wait(20)
eq({ done, failure }, { true, "Cancelled" })
eq(vim.api.nvim_buf_line_count(0), 1)
eq(#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("image_tools.insert"), 0, -1, {}), 0)
vim.ui.select = original
print("processing: real resize/conversion, argv, filtered menus, captured context and cancellation passed")
