local M = {}
local Renderer = {}
Renderer.__index = Renderer
local serial = 0
local live = setmetatable({}, { __mode = "k" })
local ns = vim.api.nvim_create_namespace("image_tools.picker")

function Renderer:close()
  local state = self.state
  self.state = nil
  if not state then
    return
  end
  if state.render then
    state.render:close()
  end
  require("image_tools.placeholder").clear(state)
  if vim.api.nvim_buf_is_valid(state.buf) then
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, ns, 0, -1, { limit = 1 })
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
    if state.id and #marks > 0 then
      local modifiable = vim.bo[state.buf].modifiable
      vim.bo[state.buf].modifiable = true
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
      vim.bo[state.buf].modifiable = modifiable
    end
  end
end

function Renderer:destroy()
  self:close()
  self.transfer:clear()
  if self.picker.opts.on_close == self.on_close then
    self.picker.opts.on_close = self.previous_close
  end
  if self.picker.opts.on_change == self.on_change then
    self.picker.opts.on_change = self.previous_change
  end
  live[self] = nil
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
  if self.picker._image_tools_preview == self then
    self.picker._image_tools_preview = nil
  end
end

function M.clear_all()
  local all = {}
  for renderer in pairs(live) do
    all[#all + 1] = renderer
  end
  for _, renderer in ipairs(all) do
    renderer:destroy()
  end
end

function M.new(picker, opts, dependencies)
  serial = serial + 1
  local self = setmetatable({ picker = picker, opts = opts, dependencies = dependencies or {} }, Renderer)
  self.transfer = require("image_tools.transfer").new(opts, self.dependencies)
  live[self] = true
  self.group = vim.api.nvim_create_augroup("image_tools.picker." .. serial, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    callback = function(event)
      if self.state and self.state.win == tonumber(event.match) then
        self:close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = self.group,
    callback = function()
      local state = self.state
      if not state or self.resize_pending then
        return
      end
      self.resize_pending = true
      vim.schedule(function()
        self.resize_pending = false
        if
          not self.group
          or self.state ~= state
          or self.picker.closed
          or not vim.api.nvim_win_is_valid(state.win)
          or not vim.api.nvim_buf_is_valid(state.buf)
          or vim.api.nvim_win_get_buf(state.win) ~= state.buf
          or self.picker.preview.item ~= state.item
        then
          return
        end
        local width, height = self:viewport(state.win)
        if width ~= state.view_width or height ~= state.view_height then
          self.picker.preview:show(self.picker, { force = true })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.group,
    callback = function(event)
      if self.state and self.state.buf == event.buf then
        self:close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimLeavePre", "VimSuspend" }, {
    group = self.group,
    callback = function()
      self:destroy()
    end,
  })
  local on_close, on_change = picker.opts.on_close, picker.opts.on_change
  self.previous_close, self.previous_change = on_close, on_change
  self.on_close = function(...)
    self:destroy()
    if on_close then
      on_close(...)
    end
  end
  self.on_change = function(p, item)
    if self.state and self.state.item ~= item then
      self:close()
    end
    if on_change then
      on_change(p, item)
    end
  end
  picker.opts.on_close, picker.opts.on_change = self.on_close, self.on_change
  return self
end

function Renderer:dependency(name)
  return self.dependencies[name] or require("image_tools." .. name)
end

function Renderer:viewport(win)
  local info = vim.fn.getwininfo(win)[1] or {}
  return math.max(1, vim.api.nvim_win_get_width(win) - (info.textoff or 0)), vim.api.nvim_win_get_height(win)
end

function Renderer:show(ctx, path)
  self:close()
  ctx.preview:reset()
  ctx.preview:minimal()
  ctx.preview:set_title(vim.fs.basename(path))
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local supported, reason = terminal.supports(self.opts)
  if not supported then
    ctx.preview:notify(reason, "warn", { item = false })
    return
  end
  local view_width, view_height = self:viewport(ctx.win)
  local state = { buf = ctx.buf, win = ctx.win, item = ctx.item, view_width = view_width, view_height = view_height }
  self.state = state
  local function current()
    return self.state == state
      and not ctx.picker.closed
      and ctx.preview.item == state.item
      and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_buf_is_valid(state.buf)
      and vim.api.nvim_win_get_buf(state.win) == state.buf
  end
  local function fail(err)
    self:close()
    ctx.preview:notify(err, "error", { item = false })
  end
  state.render = require("image_tools.render_session").new(self:dependency("image"), self.transfer)
  state.render:start(path, self.opts, {
    current = current,
    stale = function()
      if self.state == state then
        self:close()
      end
    end,
    error = fail,
    size = function(image)
      state.view_width, state.view_height = self:viewport(state.win)
      return require("image_tools.geometry").fit(
        image,
        terminal.cell_size(self.opts.cell_size),
        math.min(state.view_width, protocol.max_cells),
        math.min(state.view_height, protocol.max_cells),
        true
      )
    end,
    draw = function(entry, width, height)
      ctx.preview:wo({ wrap = false, conceallevel = 0, list = false, spell = false, winblend = 0 })
      state.top, state.left = 0, 0
      require("image_tools.placeholder").draw(
        state,
        ns,
        "ImageToolsPicker_",
        entry,
        width,
        height,
        protocol,
        function(lines)
          ctx.preview:set_lines(lines)
        end,
        state.view_height
      )
    end,
  })
end

-- Public custom previewer: uses picker lifecycle, not cursor-line ownership.
function M.preview(ctx, opts, dependencies)
  local path = Snacks.picker.util.path(ctx.item)
  if path and require("image_tools.image").supported(path) then
    local renderer = ctx.picker._image_tools_preview
    if not renderer then
      renderer = M.new(ctx.picker, opts, dependencies)
      ctx.picker._image_tools_preview = renderer
    end
    renderer:show(ctx, path)
  else
    if ctx.picker._image_tools_preview then
      ctx.picker._image_tools_preview:close()
    end
    Snacks.picker.preview.file(ctx)
  end
end

function M.pick(insertion, opts, previewer, callback)
  local I = require("image_tools.insert")
  local context = insertion.context or I.capture(insertion)
  insertion = vim.tbl_extend("force", insertion, { context = context })
  local format = require("image_tools.document").adapter(context.filetype)
  if not format then
    I.release(context)
    local err = "Unsupported image insertion filetype"
    if callback then
      callback(err)
    else
      vim.notify(err, vim.log.levels.ERROR, { title = "image-tools" })
    end
    return nil
  end
  local formats = format.image_formats()
  local confirmed = false
  local config = vim.tbl_deep_extend("force", {
    ft = formats,
    preview = previewer,
  }, opts or {})
  local on_close = config.on_close
  config.on_close = function(picker)
    if not confirmed then
      I.release(context)
      if callback then
        callback("Cancelled")
      end
    end
    if on_close then
      on_close(picker)
    end
  end
  config.actions = config.actions or {}
  config.actions.confirm = function(picker)
    local paths = {}
    for _, item in ipairs(picker:selected({ fallback = true })) do
      local path = Snacks.picker.util.path(item)
      if path then
        paths[#paths + 1] = path
      end
    end
    if #paths == 0 then
      return
    end
    confirmed = true
    picker:close()
    vim.schedule(function()
      I.files(paths, insertion, callback)
    end)
  end
  local success, picker = pcall(function()
    return require("snacks").picker.files(config)
  end)
  if not success then
    I.release(context)
    if callback then
      callback(tostring(picker))
    else
      vim.notify(tostring(picker), vim.log.levels.ERROR, { title = "image-tools" })
    end
    return nil
  end
  return picker
end

return M
