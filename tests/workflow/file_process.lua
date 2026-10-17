vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local uv, I = vim.uv, require("image_tools.workflow.insert")
local root = assert(uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/file-process"
vim.fn.mkdir(root, "p")
local fixture = root .. "/original.png"
assert(uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", fixture))
local serial = 0
local function buffer(ft)
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, root .. "/note-" .. serial .. ".txt")
  vim.bo[buf].filetype = ft or "markdown"
  return buf
end
local function run(paths, opts)
  local done, outputs, failure
  I.files(paths, opts, function(err, result)
    done, outputs, failure = true, result, err
  end)
  assert(vim.wait(5000, function()
    return done
  end, 1))
  return outputs, failure
end
local function identify(path)
  return vim.system({ "magick", "identify", "-format", "%m %wx%h", path }, { text = true }):wait().stdout
end
buffer()
local naming_context
local paths, err = run({ fixture }, {
  process = { format = "jpg", resize = "40x40>", quality = 80 },
  file_name = function(ctx)
    naming_context = ctx
    return "renamed"
  end,
})
assert(paths, err)
assert(vim.fs.basename(paths[1]) == "renamed.jpg" and identify(paths[1]) == "JPEG 40x25")
assert(
  naming_context.source == fixture
    and naming_context.source_name == "original.png"
    and naming_context.extension == "jpg"
)
assert(identify(fixture) == "PNG 160x100", "Processing preserves original files")
-- Cross-format input becomes a compiler-supported output before validation.
local webp = root .. "/download.webp"
assert(vim.system({ "magick", fixture, webp }):wait().code == 0)
buffer("tex")
paths, err = run({ webp, fixture }, { process = { format = "png", resize = "80x80>" } })
assert(paths and #paths == 2, err)
assert(vim.fs.basename(paths[1]) == "download.png" and vim.fs.basename(paths[2]) == "original.png")
assert(identify(paths[1]) == "PNG 80x50")
-- Existing asset directories and reference mode preserve bytes and skip menus.
local existing = paths[1]
local select, choose, choices = vim.ui.select
vim.ui.select = function(items, _, callback)
  choices, choose = items, callback
end
buffer()
local reused = assert(run({ existing }, { process = "select" }))
assert(reused[1] == existing and not choose)
local referenced = assert(run({ fixture }, { process = "select", mode = "reference" }))
assert(referenced[1] == fixture and not choose)
-- Capture the source document across menu interaction and focus changes.
local origin = buffer("tex")
local done, outputs, failure
I.files({ webp }, { process = "select", filename = "menu" }, function(e, p)
  done, failure, outputs = true, e, p
end)
assert(#choices == 2 and choices[1].format == "png" and choices[2].format == "jpg")
vim.api.nvim_buf_set_lines(origin, 0, 0, false, { "edited while choosing" })
local other = buffer()
choose(choices[1])
assert(vim.wait(5000, function()
  return done
end, 1))
assert(outputs, failure)
assert(vim.api.nvim_get_current_buf() == other)
assert(table.concat(vim.api.nvim_buf_get_lines(origin, 0, -1, false), "\n"):find("menu.png", 1, true))
buffer()
done = false
local cancel = I.files({ fixture }, { process = "select" }, function(e)
  done, failure = true, e
end)
cancel()
choose(choices[1])
vim.wait(20)
assert(done and failure == "Cancelled" and vim.api.nvim_buf_line_count(0) == 1)
vim.ui.select = select
-- A bad later source cannot leave a partial import or text edit.
vim.fn.writefile({ "not an image" }, root .. "/bad.png")
local failed_buf = buffer()
paths, err = run({ fixture, root .. "/bad.png" }, { directory = "failed", process = { format = "png" } })
assert(not paths and err and vim.api.nvim_buf_line_count(failed_buf) == 1)
assert(#vim.fn.glob(root .. "/failed/*", false, true) == 0)
buffer()
paths, err = run({ fixture }, { process = { format = "jpg", command = { "cp", "$INPUT", "$OUTPUT" } } })
assert(not paths and err:find("invalid encoding"), tostring(err))
buffer()
paths, err = run({ fixture }, { max_dimension = 10, process = { format = "png" } })
assert(not paths and err:find("dimension limits"), tostring(err))
-- A running converter is cancellable and late output cannot insert text.
local slow = root .. "/slow"
vim.fn.writefile({ "#!/bin/sh", "sleep 0.2", 'cp "$1" "$2"' }, slow)
assert(uv.fs_chmod(slow, 493))
buffer()
done = false
cancel = I.files({ fixture }, { process = { format = "png", command = { slow, "$INPUT", "$OUTPUT" } } }, function(e)
  done, failure = true, e
end)
vim.wait(20)
cancel()
assert(done and failure == "Cancelled")
vim.wait(300)
assert(vim.api.nvim_buf_line_count(0) == 1)
buffer()
paths, err = run(
  { fixture },
  { convert_timeout = 10, process = { format = "png", command = { slow, "$INPUT", "$OUTPUT" } } }
)
assert(not paths and err:find("processing failed"), tostring(err))
print(
  "file processing: real conversion, compiler formats, naming, reuse, menus, batch failure, encoding/dimension limits, cancellation and timeout passed"
)
