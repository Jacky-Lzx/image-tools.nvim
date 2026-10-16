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

---@class ImageToolsCellSize
---@field width number Positive pixel width of one terminal cell.
---@field height number Positive pixel height of one terminal cell.
---@class ImageToolsTerminal
local M = {}
local kitty = require("image_tools.terminal.constants")
local TIOCGWINSZ = { Darwin = 0x40087468, Linux = 0x5413 }

-- Require a supported Neovim/UI/color environment and reject multiplexers before terminal-name
-- detection.
---@param opts table force bypasses name detection only.
---@return boolean supported
---@return string? reason
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

-- Send encoded bytes through Neovim UI transport, falling back to flushed stdout.
---@param data string Complete terminal control bytes.
---@return nil
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
-- Register a bounded id-specific acknowledgement wait before sending the command.
---@param id integer Kitty image id.
---@param command string Encoded graphics command.
---@param timeout integer Response timeout in milliseconds.
---@param callback fun(err: string?) Nil means OK; errors include write failures and timeouts.
---@param placement? integer Match placement responses by both ids; nil matches upload responses.
---@param deferred? boolean Streaming caller arms the response timeout after the final chunk.
---@return ImageToolsCancel cancel Removes the handler/timer without delivering a cancellation callback.
---@return fun() arm Start the timeout unless the request already completed/cancelled.
function M.request(id, command, timeout, callback, placement, deferred)
  local finished, autocmd = false, nil
  local timer = vim.uv.new_timer()

  -- Remove the acknowledgement handler and close its timer once before completion/cancellation.
  ---@return nil
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

  -- Complete a still-live request after cleaning its callback resources.
  ---@param err? string Terminal, timeout or write error.
  ---@return nil
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
      sequence = sequence:gsub(kitty.ESC .. "\\$", "")
      local fields, message = sequence:match("^" .. kitty.ESC .. "_G([^;]+);([^" .. kitty.ESC .. "]+)$")
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

  local function arm()
    if not finished then
      timer:start(
        timeout,
        0,
        vim.schedule_wrap(function()
          done("ETIMEDOUT: no Kitty graphics response")
        end)
      )
    end
  end
  if not deferred then
    arm()
  end

  local ok, err = pcall(M.write, command)
  if not ok then
    done(tostring(err))
  end

  return function()
    if not finished then
      cleanup()
    end
  end, arm
end

-- Use the terminal's real cell geometry; a configurable fallback is useful
-- when TIOCGWINSZ does not expose pixel dimensions.
-- Measure pixels per cell via the controlling terminal ioctl, or return the supplied fallback.
---@param fallback ImageToolsCellSize Geometry used when measurement is unavailable.
---@return ImageToolsCellSize cell
function M.cell_size(fallback)
  local ok, result = pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, ...);")

    -- Match the native winsize layout without numeric array-field offsets.
    local size = ffi.new("struct { unsigned short rows, cols, width, height; }[1]")
    local system = vim.uv.os_uname().sysname
    local request = TIOCGWINSZ[system]
    if not request then
      return
    end

    local fd = vim.uv.fs_open("/dev/tty", "r", 0)
    if not fd then
      return
    end

    local status = ffi.C.ioctl(fd, request, size)
    vim.uv.fs_close(fd)

    local geometry = size[0]
    if status == 0 and geometry.rows > 0 and geometry.cols > 0 and geometry.width > 0 and geometry.height > 0 then
      return {
        width = tonumber(geometry.width) / tonumber(geometry.cols),
        height = tonumber(geometry.height) / tonumber(geometry.rows),
      }
    end
  end)
  return ok and result or fallback
end

return M
