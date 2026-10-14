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

  if state.render then
    state.render:close()
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end

  require("image_tools.placeholder").clear(state)
end

function M:destroy()
  self:close()
  self.transfer:clear()
end

--- Return: width, height , column, row
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

  state.render = require("image_tools.render_session").new(self:dependency("image"), self.transfer)
  state.render:start(meta.path, vim.tbl_extend("force", self.opts, { page = meta.page }), {
    current = current,
    stale = function()
      if self.state == state then
        self:close()
      end
    end,
    error = fail,
    size = function(image)
      width, height, col, row = M.viewport(owner_win)
      state.view_width, state.view_height, state.col, state.row = width, height, col, row
      return require("image_tools.geometry").fit(
        image,
        terminal.cell_size(self.opts.cell_size),
        math.min(width, protocol.max_cells),
        math.min(height, protocol.max_cells),
        true
      )
    end,
    draw = function(entry, width, height)
      state.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[state.buf].bufhidden, vim.bo[state.buf].filetype = "wipe", "image_tools_canvas"
      vim.bo[state.buf].swapfile = false
      require("image_tools.placeholder").draw(state, ns, "ImageToolsCanvas_", entry, width, height, protocol)
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
    end,
  })
end

return M
