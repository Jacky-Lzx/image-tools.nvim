-- Module: image_tools.terminal
--
-- Purpose:
--   Detect terminal support, measure cell geometry and exchange Kitty
--   acknowledgements.
--
-- Architecture:
--   Provide terminal I/O primitives to upload and placement services. Write
--   through Neovim UI transport and match TermResponse replies by
--   image/placement id with bounded timers.
--
-- Ownership:
--   Each request owns its handler/timer and cancellation cleanup. Pixel caches
--   and placement ownership live in upload/pixel_pool; cell geometry falls back
--   when ioctl data is unavailable.

local M = {}

function M.supports(opts)
  if vim.fn.has("nvim-0.12") ~= 1 then
    return false, "Image preview requires Neovim 0.12+ for Kitty APC acknowledgement events"
  end
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

-- Match replies to a specific image id. Install the handler before sending,
-- and always remove both handler and timer on completion or cancellation.
function M.request(id, command, timeout, callback, placement)
  local finished, autocmd = false, nil
  local timer = vim.uv.new_timer()

  local function cleanup()
    finished = true
    if autocmd then
      pcall(vim.api.nvim_del_autocmd, autocmd)
      autocmd = nil
    end
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end

  local function done(err)
    if finished then
      return
    end
    cleanup()
    callback(err)
  end

  autocmd = vim.api.nvim_create_autocmd("TermResponse", {
    callback = function(event)
      local sequence = event.data and event.data.sequence or vim.v.termresponse
      if type(sequence) ~= "string" then
        return
      end
      -- Neovim's TUI strips the APC terminator from TermResponse sequences;
      -- accept both that form and complete sequences from an attached UI.
      sequence = sequence:gsub("\27\\$", "")
      local fields, message = sequence:match("^\27_G([^;]+);([^\27]+)$")
      local response_id = fields and fields:match("i=(%d+)")
      local response_placement = fields and fields:match("p=(%d+)")
      if tonumber(response_id) == id and tonumber(response_placement) == placement then
        if message == "OK" then
          done(nil)
        else
          done(message)
        end
      end
    end,
  })

  timer:start(
    timeout,
    0,
    vim.schedule_wrap(function()
      done("ETIMEDOUT: no Kitty graphics response")
    end)
  )

  local ok, err = pcall(M.write, command)
  if not ok then
    done(tostring(err))
  end

  return function()
    if not finished then
      cleanup()
    end
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
