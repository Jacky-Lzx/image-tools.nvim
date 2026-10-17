-- Platform adapters only acquire PNG bytes. Validation, conversion, naming and
-- publication remain in the shared clipboard/import transaction.
local M = {}
local uv = vim.uv
local names = { "pngpaste", "pbctl", "wl-paste", "xclip", "powershell" }

function M.validate(opts)
  assert(
    opts.clipboard_backend == nil or opts.clipboard_backend == "auto" or vim.tbl_contains(names, opts.clipboard_backend),
    "Unknown clipboard_backend"
  )
  if opts.clipboard_tools then
    assert(type(opts.clipboard_tools) == "table", "clipboard_tools must be a table")
    for key, executable in pairs(opts.clipboard_tools) do
      assert(vim.tbl_contains(names, key), "Unknown clipboard tool: " .. tostring(key))
      assert(
        type(executable) == "string" and executable ~= "" and not executable:find("%z"),
        "Clipboard tools must be executable names or paths"
      )
    end
  end
end

function M.detect(opts, dependencies)
  opts, dependencies = opts or {}, dependencies or {}
  local ok, err = pcall(M.validate, opts)
  if not ok then
    return nil, tostring(err)
  end
  local platform = dependencies.platform
    or (dependencies.macos and "macos")
    or (vim.fn.has("win32") == 1 and "windows")
    or ((vim.env.WSL_DISTRO_NAME or vim.env.WSL_INTEROP) and "wsl")
    or (vim.fn.has("mac") == 1 and "macos")
    or "linux"
  local choices
  if opts.clipboard_backend and opts.clipboard_backend ~= "auto" then
    choices = { opts.clipboard_backend }
  elseif platform == "macos" then
    -- An explicit legacy executable override remains authoritative.
    choices = opts.pngpaste and { "pngpaste" } or { "pngpaste", "pbctl" }
  elseif platform == "windows" or platform == "wsl" then
    choices = { "powershell" }
  else
    local env = dependencies.env or vim.env
    choices = {}
    if env.WAYLAND_DISPLAY and env.WAYLAND_DISPLAY ~= "" then
      choices[#choices + 1] = "wl-paste"
    end
    if env.DISPLAY and env.DISPLAY ~= "" then
      choices[#choices + 1] = "xclip"
    end
  end
  local executable = dependencies.executable or vim.fn.executable
  for _, name in ipairs(choices) do
    local tool = opts.clipboard_tools and opts.clipboard_tools[name]
      or name == "pngpaste" and opts.pngpaste
      or name == "powershell" and "powershell.exe"
      or name
    if executable(tool) == 1 then
      return { name = name, executable = tool }
    end
  end
  if opts.pngpaste and platform == "macos" then
    return nil, "pngpaste is required for clipboard images (brew install pngpaste)"
  end
  return nil,
    "No image clipboard backend available; install pngpaste/pbctl (macOS), wl-paste/xclip (Linux session), or powershell.exe (Windows/WSL)"
end

function M.command(backend, output)
  local tool, name = backend.executable, backend.name
  if name == "pngpaste" then
    return { tool, output }, false
  elseif name == "pbctl" then
    return { tool, "paste", "--type", "image/png", "--output", output }, false
  elseif name == "wl-paste" then
    return { tool, "--no-newline", "--type", "image/png" }, true
  elseif name == "xclip" then
    return { tool, "-selection", "clipboard", "-target", "image/png", "-out" }, true
  end
  -- No user paths enter PowerShell source. Binary stdout also works through WSL
  -- without wslpath, shared temp directories or PowerShell's text encoding.
  local script = table.concat({
    "$ErrorActionPreference='Stop'",
    "Add-Type -AssemblyName System.Windows.Forms",
    "$image=[System.Windows.Forms.Clipboard]::GetImage()",
    "if ($null -eq $image) { throw 'Clipboard does not contain an image' }",
    "$stream=New-Object System.IO.MemoryStream",
    "try { $image.Save($stream,[System.Drawing.Imaging.ImageFormat]::Png); $bytes=$stream.ToArray(); $stdout=[Console]::OpenStandardOutput(); $stdout.Write($bytes,0,$bytes.Length); $stdout.Flush() } finally { $stream.Dispose(); $image.Dispose() }",
  }, "; ")
  return { tool, "-NoLogo", "-NoProfile", "-NonInteractive", "-STA", "-Command", script }, true
end

-- Bound streamed data before writing it. A cancelled reader closes its file and
-- suppresses late callbacks; the owning transaction removes the temp directory.
function M.read(backend, output, opts, callback)
  local command, streamed = M.command(backend, output)
  local active, bytes, fd, stream_error, job = true, 0
  local function close()
    if fd then
      uv.fs_close(fd)
      fd = nil
    end
  end
  local function complete(result)
    close()
    if not active then
      return
    end
    active = false
    callback(
      stream_error or (result.code ~= 0 and ("Cannot read a clipboard image: " .. vim.trim(result.stderr or "")) or nil)
    )
  end
  local settings = { timeout = opts.clipboard_timeout or 5000, stdout = false }
  if streamed then
    local err
    fd, err = uv.fs_open(output, "wx", 384)
    if not fd then
      complete({ code = 1, stderr = tostring(err) })
      return function() end
    end
    settings.stdout = function(err, data)
      if not active or stream_error then
        return
      end
      if err then
        stream_error = "Clipboard stream failed: " .. tostring(err)
      elseif data then
        if bytes + #data > (opts.max_bytes or require("image_tools.defaults").max_bytes) then
          stream_error = "Clipboard image exceeds max_bytes"
        else
          local offset = 0
          while offset < #data do
            local written, write_err = uv.fs_write(fd, data:sub(offset + 1), bytes + offset)
            if not written or written == 0 then
              stream_error = "Clipboard write failed: " .. tostring(write_err)
              break
            end
            offset = offset + written
          end
          bytes = bytes + offset
        end
      end
      if stream_error and job then
        job:kill(15)
      end
    end
  end
  local ok, result = pcall(vim.system, command, settings, vim.schedule_wrap(complete))
  if not ok then
    complete({ code = 1, stderr = tostring(result) })
  else
    job = result
    if stream_error and active then
      job:kill(15)
    end
  end
  return function()
    if active then
      active = false
      close()
      if job then
        job:kill(15)
      end
    end
  end
end

return M
