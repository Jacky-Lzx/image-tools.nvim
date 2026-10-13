local M = {}

function M.supports(opts)
  if #vim.api.nvim_list_uis() == 0 then
    return false, "Image preview requires an attached terminal UI"
  end
  if not vim.o.termguicolors then
    return false, "Image preview requires termguicolors"
  end
  if vim.env.TMUX or vim.env.ZELLIJ then
    return false, "Multiplexers are not supported in this first version"
  end
  if opts.force or vim.env.KITTY_WINDOW_ID or vim.env.TERM == "xterm-kitty" then
    return true
  end
  return false, "Image preview currently supports Kitty 0.28+; other terminals are not yet validated"
end

function M.write(data)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    io.stdout:write(data)
    io.stdout:flush()
  end
end

-- Use the terminal's real cell geometry; a configurable fallback is useful
-- when TIOCGWINSZ does not expose pixel dimensions.
function M.cell_size(fallback)
  local ok, result = pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, ...);")
    local size = ffi.new("unsigned short[4]")
    local system = vim.uv.os_uname().sysname
    local request = system == "Darwin" and 0x40087468 or (system == "Linux" and 0x5413 or nil)
    if not request then
      return
    end
    local fd = vim.uv.fs_open("/dev/tty", "r", 0)
    if not fd then
      return
    end
    local status = ffi.C.ioctl(fd, request, size)
    vim.uv.fs_close(fd)
    if status == 0 and size[0] > 0 and size[1] > 0 and size[2] > 0 and size[3] > 0 then
      return { width = tonumber(size[2]) / tonumber(size[1]), height = tonumber(size[3]) / tonumber(size[0]) }
    end
  end)
  return ok and result or fallback
end

return M
