local M = {}
M.__index = M

function M.new(opts, dependencies)
  return setmetatable({ opts = opts, dependencies = dependencies or {}, generation = 0 }, M)
end

function M:dependency(name)
  return self.dependencies[name] or require("image_tools." .. name)
end

function M.fit(image, cell, max_width, max_height)
  local columns, rows = image.width / cell.width, image.height / cell.height
  local scale = math.min(1, max_width / columns, max_height / rows)
  return math.max(1, math.ceil(columns * scale)), math.max(1, math.ceil(rows * scale))
end

function M:close()
  self.generation = self.generation + 1
  local state = self.state
  self.state = nil
  if not state then
    return
  end
  if state.cancel then
    state.cancel()
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.id then
    self:dependency("terminal").write(self:dependency("protocol").delete(state.id))
    vim.api.nvim_set_hl(0, state.highlight, {})
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
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
  }
  state.changedtick = vim.api.nvim_buf_get_changedtick(state.owner_buf)
  self.state = state
  state.cancel = self:dependency("image").prepare(path, self.opts, function(err, image)
    if self.generation ~= generation or self.state ~= state then
      return
    end
    if
      not vim.api.nvim_win_is_valid(state.owner_win)
      or not vim.api.nvim_buf_is_valid(state.owner_buf)
      or vim.api.nvim_get_current_win() ~= state.owner_win
      or vim.api.nvim_get_current_buf() ~= state.owner_buf
      or vim.api.nvim_buf_get_changedtick(state.owner_buf) ~= state.changedtick
      or vim.api.nvim_win_get_cursor(state.owner_win)[1] ~= state.cursor[1]
    then
      self:close()
      return
    end
    if err then
      self:close()
      if not options.silent then
        vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
      end
      return
    end
    local width, height = M.fit(
      image,
      terminal.cell_size(self.opts.cell_size),
      math.max(1, math.min(self.opts.max_width, protocol.max_cells, vim.o.columns - 4)),
      math.max(1, math.min(self.opts.max_height, protocol.max_cells, vim.o.lines - vim.o.cmdheight - 4))
    )
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
    -- 24-bit true-color ids, with a per-process starting point. Only this
    -- plugin's ids are ever deleted; never issue a terminal-wide clear.
    self.next_id = ((self.next_id or (vim.uv.hrtime() % 0xEFFFFF)) % 0xEFFFFF) + 0x100000
    state.id = self.next_id
    state.highlight = "ImageTools_" .. state.id
    vim.api.nvim_set_hl(0, state.highlight, { fg = string.format("#%06x", state.id) })
    terminal.write(protocol.upload(state.id, image.data) .. protocol.place(state.id, width, height))
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, protocol.grid(width, height))
    local namespace = vim.api.nvim_create_namespace("image_tools.preview")
    for i = 0, height - 1 do
      vim.api.nvim_buf_set_extmark(state.buf, namespace, i, 0, {
        end_row = i + 1,
        end_col = 0,
        hl_group = state.highlight,
        priority = 1000,
      })
    end
    vim.bo[state.buf].modifiable = false
    vim.bo[state.buf].modified = false
  end)
  return true
end

return M
