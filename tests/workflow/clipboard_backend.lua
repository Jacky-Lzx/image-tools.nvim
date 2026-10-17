vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local B, C = require("image_tools.workflow.clipboard_backend"), require("image_tools.workflow.clipboard")
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/backends"
vim.fn.mkdir(tmp, "p")
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ actual = a, expected = b }))
end
local function detect(platform, available, env, opts)
  return B.detect(opts or {}, {
    platform = platform,
    env = env or {},
    executable = function(tool)
      return available[tool] and 1 or 0
    end,
  })
end
eq(detect("macos", { pbctl = true }).name, "pbctl")
eq(detect("macos", { pbctl = true, pngpaste = true }).name, "pngpaste")
eq(detect("macos", { pbctl = true }, {}, { pngpaste = "missing" }), nil)
eq(
  detect("linux", { ["wl-paste"] = true, xclip = true }, { WAYLAND_DISPLAY = "wayland", DISPLAY = ":0" }).name,
  "wl-paste"
)
eq(detect("linux", { xclip = true }, { WAYLAND_DISPLAY = "wayland", DISPLAY = ":0" }).name, "xclip")
eq(detect("linux", { xclip = true }), nil)
eq(detect("wsl", { ["powershell.exe"] = true }).name, "powershell")
eq(detect("windows", { ["powershell.exe"] = true }).name, "powershell")
local argv, streamed = B.command({ name = "powershell", executable = "powershell.exe" }, "not embedded ' 中文.png")
eq(streamed, true)
eq(argv[5], "-STA")
assert(argv[7]:find("OpenStandardOutput", 1, true) and not argv[7]:find("not embedded", 1, true))
local direct, stdout = tmp .. "/direct reader", tmp .. "/stdout reader"
vim.fn.writefile({ "#!/bin/sh", 'cp "$IMAGE_TOOLS_ROOT/tests/fixtures/fixture.png" "$1"' }, direct)
vim.fn.writefile({ "#!/bin/sh", 'cat "$IMAGE_TOOLS_ROOT/tests/fixtures/fixture.png"' }, stdout)
assert(vim.uv.fs_chmod(direct, 493))
assert(vim.uv.fs_chmod(stdout, 493))
local pbctl = tmp .. "/pbctl reader"
vim.fn.writefile({
  "#!/bin/sh",
  '[ "$1" = paste ] && [ "$2" = --type ] && [ "$3" = image/png ] && [ "$4" = --output ] || exit 2',
  'cp "$IMAGE_TOOLS_ROOT/tests/fixtures/fixture.png" "$5"',
}, pbctl)
assert(vim.uv.fs_chmod(pbctl, 493))
local serial = 0
local function buffer()
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/note-" .. serial .. ".md")
  vim.bo.filetype = "markdown"
  return buf
end
local function paste(backend, tool, extra)
  local done, failure, paths
  C.paste(
    vim.tbl_extend("force", {
      clipboard_backend = backend,
      clipboard_tools = { [backend] = tool },
      format = "png",
    }, extra or {}),
    function(err, outputs)
      failure, paths, done = err, outputs, true
    end
  )
  assert(vim.wait(3000, function()
    return done
  end))
  return failure, paths
end
for _, backend in ipairs({ "pngpaste", "pbctl", "wl-paste", "xclip", "powershell" }) do
  local buf = buffer()
  local err, paths = paste(backend, backend == "pngpaste" and direct or backend == "pbctl" and pbctl or stdout)
  assert(not err, err)
  eq(vim.fn.readblob(paths[1]), vim.fn.readblob(fixture))
  eq(require("image_tools.document").at_line(buf, 2, { max_scan_lines = 100 }), paths[1])
end
buffer()
local err = paste("wl-paste", stdout, { max_bytes = 8 })
assert(err and err:find("max_bytes", 1, true))
eq(vim.api.nvim_buf_line_count(0), 1)
local bad = tmp .. "/bad reader"
vim.fn.writefile({ "#!/bin/sh", "echo not-an-image" }, bad)
assert(vim.uv.fs_chmod(bad, 493))
buffer()
err = paste("xclip", bad)
assert(err)
eq(vim.api.nvim_buf_line_count(0), 1)
local slow = tmp .. "/slow reader"
vim.fn.writefile({ "#!/bin/sh", "exec sleep 5" }, slow)
assert(vim.uv.fs_chmod(slow, 493))
buffer()
err = paste("powershell", slow, { clipboard_timeout = 20 })
assert(err)
eq(vim.api.nvim_buf_line_count(0), 1)
-- Cancelled readers cannot write to a closed descriptor or complete late.
local system, settings, complete, killed = vim.system, nil, nil, false
vim.system = function(_, options, callback)
  settings, complete = options, callback
  return {
    kill = function()
      killed = true
    end,
  }
end
local received = false
local cancel = B.read({ name = "xclip", executable = stdout }, tmp .. "/cancel.png", {}, function()
  received = true
end)
cancel()
settings.stdout(nil, "late data")
complete({ code = 0 })
vim.wait(10)
eq({ received, killed }, { false, true })
vim.system = system
-- Force short writes to exercise the streamed writer's offset accounting.
local write = vim.uv.fs_write
vim.uv.fs_write = function(fd, data, offset)
  return write(fd, data:sub(1, 7), offset)
end
local done, failure
B.read({ name = "xclip", executable = stdout }, tmp .. "/short.png", {}, function(e)
  failure, done = e, true
end)
assert(vim.wait(3000, function()
  return done
end))
vim.uv.fs_write = write
assert(not failure, failure)
eq(vim.fn.readblob(tmp .. "/short.png"), vim.fn.readblob(fixture))
print(
  "clipboard backends: detection, all reader protocols, binary/short writes, limits, timeouts and cancellation passed"
)
