-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  protocol = "image_tools.terminal.protocol",
}

local M = {}
M.__index = M

function M.new(opts, dependencies)
  local self = setmetatable({ opts = opts, dependencies = dependencies or {}, generation = 0 }, M)
  self.transfer = require("image_tools.terminal.transfer").new(opts, self.dependencies)
  return self
end

function M:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

-- Retain the existing helper while all renderers depend on geometry directly.
M.fit = require("image_tools.render.geometry").fit

function M:close()
  self.generation = self.generation + 1
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
  require("image_tools.render.placeholder").clear(state)
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
end

function M:destroy()
  self:close()
  self.transfer:clear()
end

local function on_reference_row(state)
  local row = vim.api.nvim_win_get_cursor(state.owner_win)[1]
  local range = state.reference_range
  return range and row >= range.start_row and row <= range.end_row or not range and row == state.cursor[1]
end

function M:open(path, options)
  options = options or {}
  self:close()
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local supported, reason = terminal.supports(self.opts)
  if not supported then
    if not options.silent then
      vim.notify(reason, vim.log.levels.WARN, { title = "image-tools" })
    end
    return false, reason
  end
  local generation = self.generation
  local state = {
    owner_buf = vim.api.nvim_get_current_buf(),
    owner_win = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
    path = path,
    automatic = options.silent or false,
    reference = options.reference or false,
    reference_range = options.reference_range,
  }
  state.changedtick = vim.api.nvim_buf_get_changedtick(state.owner_buf)
  self.state = state
  state.render = require("image_tools.render.session").new(self:dependency("image"), self.transfer)
  state.render:start(path, self.opts, {
    current = function()
      return self.generation == generation
        and self.state == state
        and vim.api.nvim_win_is_valid(state.owner_win)
        and vim.api.nvim_buf_is_valid(state.owner_buf)
        and vim.api.nvim_get_current_win() == state.owner_win
        and vim.api.nvim_get_current_buf() == state.owner_buf
        and vim.api.nvim_buf_get_changedtick(state.owner_buf) == state.changedtick
        and on_reference_row(state)
        and (not state.reference or vim.api.nvim_win_get_cursor(state.owner_win)[2] == state.cursor[2])
    end,
    stale = function()
      if self.state == state then
        self:close()
      end
    end,
    error = function(err)
      self:close()
      if not options.silent then
        vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
      end
    end,
    size = function(image)
      return require("image_tools.render.geometry").fit(
        image,
        terminal.cell_size(self.opts.cell_size),
        math.max(1, math.min(self.opts.max_width, protocol.max_cells, vim.o.columns - 4)),
        math.max(1, math.min(self.opts.max_height, protocol.max_cells, vim.o.lines - vim.o.cmdheight - 4))
      )
    end,
    draw = function(entry, width, height)
      state.cursor = vim.api.nvim_win_get_cursor(state.owner_win)
      state.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[state.buf].buftype = "nofile"
      vim.bo[state.buf].bufhidden = "wipe"
      vim.bo[state.buf].swapfile = false
      vim.bo[state.buf].filetype = "image_tools_preview"
      local window = {
        relative = "editor",
        width = width,
        height = height,
        style = "minimal",
        border = self.opts.border,
        focusable = false,
        zindex = 50,
        title = " " .. vim.fs.basename(path) .. " ",
        title_pos = "center",
      }
      if self.opts.position == "bottom_right" then
        local statusline = vim.o.laststatus == 2
          or vim.o.laststatus == 3
          or (vim.o.laststatus == 1 and vim.fn.winnr("$") > 1)
        window.anchor = "SE"
        window.row = math.max(0, vim.o.lines - vim.o.cmdheight - (statusline and 1 or 0))
        window.col = vim.o.columns
      else
        local position = vim.fn.screenpos(state.owner_win, state.cursor[1], state.cursor[2] + 1)
        window.row = math.max(0, math.min(position.row, vim.o.lines - vim.o.cmdheight - height - 2))
        window.col = math.max(0, math.min(position.col, vim.o.columns - width - 2))
      end
      state.win = vim.api.nvim_open_win(state.buf, false, window)
      vim.wo[state.win].wrap = false
      vim.wo[state.win].winblend = 0
      vim.wo[state.win].conceallevel = 0
      vim.wo[state.win].list = false
      vim.wo[state.win].spell = false
      require("image_tools.render.placeholder").draw(
        state,
        vim.api.nvim_create_namespace("image_tools.preview"),
        "ImageTools_",
        entry,
        width,
        height,
        protocol
      )
      vim.bo[state.buf].modifiable = false
      vim.bo[state.buf].modified = false
    end,
  })
  return true
end

return M
