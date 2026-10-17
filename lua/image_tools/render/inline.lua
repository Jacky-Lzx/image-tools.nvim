-- Window-scoped virtual-line rendering for visible Markdown images/block math.
-- Redraw callbacks only schedule reconciliation; parsing, conversions and editor
-- mutations run outside redraw. Each placement owns a normal render session.
local M = {}
M.__index = M
local provider = vim.api.nvim_create_namespace("image_tools.inline.redraw")
local namespaces, serial, provider_owner = {}, 0, nil
local modules =
  { image = "image_tools.media", protocol = "image_tools.terminal.protocol", terminal = "image_tools.terminal" }

function M:dependency(name)
  return self.dependencies[name] or require(modules[name])
end

function M.new(opts, dependencies)
  local self = setmetatable({ opts = opts, dependencies = dependencies or {}, views = {}, syncs = 0 }, M)
  provider_owner = self
  vim.api.nvim_set_decoration_provider(provider, {
    on_win = function(_, _, buf)
      if not self.destroyed and not self.paused and self.opts.inline.enabled and vim.bo[buf].filetype == "markdown" then
        self:schedule()
      end
      return false
    end,
  })
  return self
end

function M:close_entry(view, entry)
  view.entries[entry.key] = nil
  if entry.mark and vim.api.nvim_buf_is_valid(view.buf) then
    pcall(vim.api.nvim_buf_del_extmark, view.buf, view.ns, entry.mark)
  end
  if entry.render then
    entry.render:close()
  end
  require("image_tools.render.placeholder").clear(entry)
end

function M:drop(win)
  local view = self.views[win]
  if not view then
    return
  end
  self.views[win] = nil
  for _, entry in pairs(vim.tbl_extend("force", {}, view.entries)) do
    self:close_entry(view, entry)
  end
  if vim.api.nvim_buf_is_valid(view.buf) then
    vim.api.nvim_buf_clear_namespace(view.buf, view.ns, 0, -1)
  end
  view.transfer:clear()
  namespaces[#namespaces + 1] = view.ns
end

function M:clear()
  for win in pairs(vim.tbl_extend("force", {}, self.views)) do
    self:drop(win)
  end
end

function M:stop_timer()
  if self.timer then
    if not self.timer:is_closing() then
      self.timer:stop()
      self.timer:close()
    end
    self.timer = nil
  end
end

function M:pause()
  self.paused = true
  self:stop_timer()
  self:clear()
end

function M:resume()
  self.paused = false
  self:schedule()
end

function M:destroy()
  self.destroyed = true
  self:pause()
  if provider_owner == self then
    provider_owner = nil
    vim.api.nvim_set_decoration_provider(provider, {})
  end
end

-- Snapshot checks are cheap, and run again at preparation/placement completion.
-- topfill identifies virtual rows belonging to the line above the viewport.
function M:current(view, entry)
  if
    self.destroyed
    or self.paused
    or not self.opts.inline.enabled
    or self.views[view.win] ~= view
    or view.entries[entry.key] ~= entry
    or not vim.api.nvim_win_is_valid(view.win)
    or vim.api.nvim_win_get_buf(view.win) ~= view.buf
    or not vim.api.nvim_buf_is_loaded(view.buf)
    or vim.api.nvim_win_get_tabpage(view.win) ~= vim.api.nvim_get_current_tabpage()
    or vim.api.nvim_buf_get_changedtick(view.buf) ~= view.tick
    or vim.api.nvim_buf_get_name(view.buf) ~= view.name
    or vim.bo[view.buf].filetype ~= "markdown"
  then
    return false
  end
  return vim.api.nvim_win_call(view.win, function()
    local info = vim.fn.getwininfo(view.win)[1]
    local ref = entry.reference
    if ref.end_row > info.botline or ref.end_row < info.topline - 1 then
      return false
    end
    if ref.end_row < info.topline and (not entry.mark or vim.fn.winsaveview().topfill == 0) then
      return false
    end
    for row = ref.start_row, ref.end_row do
      if vim.fn.foldclosed(row) ~= -1 then
        return false
      end
    end
    return true
  end)
end

function M:start_entry(view, candidate, force)
  local ref = candidate.reference
  local entry = { key = candidate.key, path = candidate.path, reference = ref, version = candidate.version }
  view.entries[entry.key] = entry
  if not entry.path then
    entry.error = candidate.error or "Unresolved image reference"
    self.last_error = entry.error
    return
  end
  local options = vim.tbl_extend("force", self.opts, { _formula = ref.formula, _remote_refresh = force or nil })
  local terminal, protocol = self:dependency("terminal"), self:dependency("protocol")
  local function stale()
    if view.entries[entry.key] == entry then
      self:close_entry(view, entry)
      self:schedule()
    end
  end
  entry.render = require("image_tools.render.session").new(self:dependency("image"), view.transfer)
  entry.render:start(entry.path, options, {
    current = function()
      return self:current(view, entry)
    end,
    stale = stale,
    error = function(err)
      entry.error, self.last_error = tostring(err), tostring(err)
      if entry.mark and vim.api.nvim_buf_is_valid(view.buf) then
        pcall(vim.api.nvim_buf_del_extmark, view.buf, view.ns, entry.mark)
        entry.mark = nil
      end
      require("image_tools.render.placeholder").clear(entry)
    end,
    size = function(image)
      entry.image =
        { width = image.width, height = image.height, format = image.source_format, bytes = image.source_bytes }
      return require("image_tools.render.geometry").fit(
        image.display_size or image,
        terminal.cell_size(self.opts.cell_size),
        math.min(view.width, self.opts.inline.max_width, protocol.max_cells),
        math.min(math.max(1, view.height - 1), self.opts.inline.max_height, protocol.max_cells)
      )
    end,
    draw = function(placement, width, height)
      local lines = require("image_tools.render.placeholder").virtual(
        entry,
        "ImageToolsInline_",
        placement,
        width,
        height,
        protocol
      )
      entry.mark = vim.api.nvim_buf_set_extmark(view.buf, view.ns, ref.end_row - 1, 0, {
        virt_lines = lines,
        virt_lines_overflow = "scroll",
        right_gravity = false,
        undo_restore = false,
        invalidate = true,
      })
      self:schedule()
    end,
  })
end

function M:sync()
  if self.destroyed or self.paused then
    return
  end
  self.syncs = self.syncs + 1
  if not self.opts.inline.enabled then
    self:clear()
    return
  end
  local supported, reason = self:dependency("terminal").supports(self.opts)
  if not supported or not vim.api.nvim__ns_set then
    self.last_error = reason or "Inline rendering requires window-scoped namespace support"
    self:clear()
    return
  end
  local visible = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if
      vim.api.nvim_win_get_config(win).relative == ""
      and vim.bo[buf].filetype == "markdown"
      and vim.bo[buf].buftype == ""
    then
      visible[win] = true
      local info = vim.fn.getwininfo(win)[1]
      local width, height = math.max(1, info.width - info.textoff), math.max(1, info.height)
      local tick, name = vim.api.nvim_buf_get_changedtick(buf), vim.api.nvim_buf_get_name(buf)
      local view = self.views[win]
      if
        view
        and (view.buf ~= buf or view.tick ~= tick or view.name ~= name or view.width ~= width or view.height ~= height)
      then
        self:drop(win)
        view = nil
      end
      local anchors = {}
      for _, entry in pairs(view and view.entries or {}) do
        if entry.mark then
          anchors[entry.reference.end_row] = true
        end
      end
      local ok, candidates = pcall(vim.api.nvim_win_call, win, function()
        return require("image_tools.document.inline").collect(buf, win, self.opts, anchors)
      end)
      if not ok then
        self.last_error = tostring(candidates)
        candidates = {}
      end
      if #candidates > 0 and not view then
        local ns = table.remove(namespaces)
        if not ns then
          serial = serial + 1
          ns = vim.api.nvim_create_namespace("image_tools.inline.window." .. serial)
        end
        vim.api.nvim__ns_set(ns, { wins = { win } })
        view = {
          win = win,
          buf = buf,
          tick = tick,
          name = name,
          width = width,
          height = height,
          ns = ns,
          entries = {},
          transfer = require("image_tools.terminal.transfer").new(self.opts, self.dependencies),
        }
        self.views[win] = view
      end
      if view then
        local wanted = {}
        for _, candidate in ipairs(candidates) do
          wanted[candidate.key] = candidate
          local stat = candidate.path and not candidate.reference.formula and vim.uv.fs_stat(candidate.path)
          candidate.version = stat and require("image_tools.media.file_version").key(candidate.path, stat) or nil
        end
        for key, entry in pairs(vim.tbl_extend("force", {}, view.entries)) do
          if not wanted[key] or wanted[key].version ~= entry.version then
            self:close_entry(view, entry)
          end
        end
        for _, candidate in ipairs(candidates) do
          if not view.entries[candidate.key] then
            self:start_entry(view, candidate, self.force and self.force[buf])
          end
        end
        if not next(view.entries) then
          self:drop(win)
        end
      end
    end
  end
  for win in pairs(vim.tbl_extend("force", {}, self.views)) do
    if not visible[win] then
      self:drop(win)
    end
  end
  self.force = nil
end

function M:schedule()
  if self.destroyed or self.paused or self.timer or not self.opts.inline.enabled then
    return
  end
  self.timer = vim.defer_fn(function()
    self.timer = nil
    self:sync()
  end, self.opts.inline.debounce)
end

function M:invalidate(buf, force)
  for win, view in pairs(vim.tbl_extend("force", {}, self.views)) do
    if not buf or view.buf == buf then
      self:drop(win)
    end
  end
  if force and buf then
    self.force = self.force or {}
    self.force[buf] = true
  end
  self:schedule()
end

function M:info(win, row)
  local view = self.views[win]
  if not view then
    return
  end
  for _, entry in pairs(view.entries) do
    if row >= entry.reference.start_row and row <= entry.reference.end_row then
      local stat = entry.path and vim.uv.fs_stat(entry.path)
      return {
        path = entry.path or entry.reference.src or "Unresolved image",
        format = entry.reference.formula and "math" or entry.image and entry.image.format or entry.path and require(
          "image_tools.media.formats"
        ).extension(entry.path),
        width = entry.image and entry.image.width,
        height = entry.image and entry.image.height,
        bytes = entry.image and entry.image.bytes or stat and stat.size,
        error = entry.error,
        stage = entry.error and "failed" or entry.render and entry.render.stage or "preparing",
        ready = entry.mark ~= nil,
        timings = entry.render and entry.render:timings(),
        disk_cache = self.opts.cache,
        inline = true,
      }
    end
  end
end

function M:status()
  local result = {
    enabled = self.opts.inline.enabled,
    paused = not not self.paused,
    windows = vim.tbl_count(self.views),
    images = 0,
    ready = 0,
    pending = 0,
    failed = 0,
    syncs = self.syncs,
    last_error = self.last_error,
  }
  for _, view in pairs(self.views) do
    for _, entry in pairs(view.entries) do
      result.images = result.images + 1
      local field = entry.error and "failed" or entry.mark and "ready" or "pending"
      result[field] = result[field] + 1
    end
  end
  return result
end

return M
