local M = {}
M.__index = M
local ns = vim.api.nvim_create_namespace("image_tools.canvas")

function M.new(opts, dependencies)
  local self = setmetatable({ opts = opts, dependencies = dependencies or {} }, M)
  self.transfer = require("image_tools.transfer").new(opts, self.dependencies)
  return self
end
function M:dependency(name)
  return self.dependencies[name] or require("image_tools." .. name)
end
function M:close()
  local state = self.state
  self.state = nil
  if not state then
    return
  end
  if state.cancel then
    state.cancel()
  end
  if state.cancel_transfer then
    state.cancel_transfer()
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  if state.highlight then
    vim.api.nvim_set_hl(0, state.highlight, {})
  end
end

function M:destroy()
  self:close()
  self.transfer:clear()
end

function M.viewport(win)
  local info = vim.fn.getwininfo(win)[1] or {}
  -- API height includes winbar; relative="win" starts below it. getwininfo()
  -- reports text height, already excluding winbar, statusline and separators.
  local height = info.height or (vim.api.nvim_win_get_height(win) - (info.winbar or 0))
  local header = height > 1 and 1 or 0
  return math.max(1, vim.api.nvim_win_get_width(win) - (info.textoff or 0)),
    math.max(1, height - header),
    info.textoff or 0,
    header
end

function M:open(meta, owner_buf, owner_win, callback)
  self:close()
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local supported, reason = terminal.supports(self.opts)
  if not supported then
    callback(reason)
    return
  end
  local width, height, col, row = M.viewport(owner_win)
  local state = {
    owner_buf = owner_buf,
    owner_win = owner_win,
    path = meta.path,
    page = meta.page,
    generation = meta.generation,
    view_width = width,
    view_height = height,
    col = col,
    row = row,
  }
  self.state = state
  local function current()
    return self.state == state
      and meta.generation == state.generation
      and meta.page == state.page
      and vim.api.nvim_win_is_valid(owner_win)
      and vim.api.nvim_win_get_buf(owner_win) == owner_buf
      and vim.api.nvim_win_get_tabpage(owner_win) == vim.api.nvim_get_current_tabpage()
  end
  local function fail(err)
    self:close()
    callback(err)
  end
  state.cancel = self
    :dependency("image")
    .prepare(meta.path, vim.tbl_extend("force", self.opts, { page = meta.page }), function(err, image)
      if not current() then
        if self.state == state then
          self:close()
        end
        return
      end
      if err then
        fail(err)
        return
      end
      width, height, col, row = M.viewport(owner_win)
      state.view_width, state.view_height, state.col, state.row = width, height, col, row
      width, height = require("image_tools.preview").fit(
        image,
        terminal.cell_size(self.opts.cell_size),
        math.min(width, protocol.max_cells),
        math.min(height, protocol.max_cells),
        true
      )
      state.cancel_transfer = self.transfer:acquire(image, width, height, function(transfer_err, entry)
        if not current() then
          if entry and entry.cancel then
            entry.cancel()
          end
          if self.state == state then
            self:close()
          end
          return
        end
        if transfer_err then
          fail(transfer_err)
          return
        end
        state.id, state.width, state.height = entry.id, width, height
        state.highlight = "ImageToolsCanvas_" .. entry.id
        vim.api.nvim_set_hl(0, state.highlight, { fg = string.format("#%06x", entry.id) })
        state.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[state.buf].bufhidden, vim.bo[state.buf].filetype = "wipe", "image_tools_canvas"
        vim.bo[state.buf].swapfile = false
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, protocol.grid(width, height))
        for i = 0, height - 1 do
          vim.api.nvim_buf_set_extmark(
            state.buf,
            ns,
            i,
            0,
            { end_row = i + 1, end_col = 0, hl_group = state.highlight, priority = 1000 }
          )
        end
        vim.bo[state.buf].modifiable, vim.bo[state.buf].modified = false, false
        state.win = vim.api.nvim_open_win(state.buf, false, {
          relative = "win",
          win = owner_win,
          row = row,
          col = col,
          width = width,
          height = height,
          style = "minimal",
          border = "none",
          focusable = false,
          zindex = 30,
        })
        vim.wo[state.win].wrap, vim.wo[state.win].list, vim.wo[state.win].spell = false, false, false
        vim.wo[state.win].winblend, vim.wo[state.win].conceallevel = 0, 0
        callback(nil)
      end)
    end)
end
return M
