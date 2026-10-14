-- Module: image_tools.render.buffer
--
-- Purpose:
--   Provide read-only named image/PDF buffers and their per-window viewers.
--
-- Architecture:
--   Install file interception, manage PDF metadata via media/pdf and delegate
--   drawing to render/canvas. Synchronize visible regular windows, source
--   revisions, page changes and viewer errors.
--
-- Ownership:
--   Own buffer metadata, window views, saved options and handlers. PDF page
--   state is shared per buffer; canvases have independent placements and are
--   cleaned up on hide, teardown or suspension.

-- Logical dependency keys remain stable across module directory changes.
local dependency_modules = {
  pdf = "image_tools.media.pdf",
}

local M = {}
M.__index = M
local window_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  wrap = false,
  list = false,
  spell = false,
  conceallevel = 0,
  cursorline = false,
}

function M.new(opts, dependencies)
  return setmetatable({ opts = opts, dependencies = dependencies or {}, buffers = {}, views = {} }, M)
end

function M:dependency(name)
  return self.dependencies[name] or require(dependency_modules[name] or ("image_tools." .. name))
end

function M:header(buf)
  local meta = self.buffers[buf]
  if not meta or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local line = vim.fs.basename(meta.path):gsub("[\r\n]", " ")
  if meta.pdf then
    line = line .. "  " .. meta.page .. " / " .. (meta.pages or "?") .. "   [p previous  ]p next"
  end
  line = line .. "   r reload"
  local lines = { line }
  if meta.error then
    vim.list_extend(lines, vim.split(meta.error, "\n", { plain = true }))
  end
  vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].modified, vim.bo[buf].readonly = false, false, true
end

function M:drop_view(win)
  local view = self.views[win]
  if not view then
    return
  end
  self.views[win] = nil
  view.canvas:destroy()
  if vim.api.nvim_win_is_valid(win) then
    for name, value in pairs(view.saved) do
      -- Preserve options already changed by the new buffer's filetype hooks.
      if vim.wo[win][name] == window_options[name] then
        vim.wo[win][name] = value
      end
    end
  end
end

function M:release(buf)
  local meta = self.buffers[buf]
  self.buffers[buf] = nil
  if meta and meta.cancel_info then
    meta.cancel_info()
  end
  for win, view in pairs(vim.tbl_extend("force", {}, self.views)) do
    if view.buf == buf then
      self:drop_view(win)
    end
  end
end

function M:clear_cache()
  self.paused = true
  for _, view in pairs(self.views) do
    view.canvas:destroy()
    view.failed = nil
  end
end

function M:destroy()
  if self.group then
    vim.api.nvim_del_augroup_by_id(self.group)
    self.group = nil
  end
  for win in pairs(vim.tbl_extend("force", {}, self.views)) do
    self:drop_view(win)
  end
  for buf in pairs(vim.tbl_extend("force", {}, self.buffers)) do
    self:release(buf)
  end
end

function M:schedule()
  if self.pending or not self.group then
    return
  end
  self.pending = true
  vim.schedule(function()
    self.pending = false
    if self.group then
      self:sync()
    end
  end)
end

function M:reload(buf)
  self.paused = false
  local meta = self.buffers[buf]
  if not meta then
    return false, "Current buffer is not an image/PDF preview"
  end

  if meta.cancel_info then
    meta.cancel_info()
    meta.cancel_info = nil
  end

  meta.generation, meta.error = meta.generation + 1, nil

  local stat = vim.uv.fs_stat(meta.path)
  if not stat or stat.type ~= "file" then
    meta.error = "File is missing or not a regular file"
  elseif stat.size > self.opts.max_bytes then
    meta.error = "File exceeds max_bytes"
  else
    meta.key = require("image_tools.image").key(meta.path, stat)
  end

  if meta.pdf and not meta.error then
    meta.pages = nil
    local generation = meta.generation
    meta.cancel_info = self:dependency("pdf").info(meta.path, self.opts, function(err, info)
      if self.buffers[buf] ~= meta or meta.generation ~= generation then
        return
      end
      meta.cancel_info = nil
      if err then
        meta.error = err
      else
        meta.pages, meta.key = info.pages, info.key
        meta.page = math.min(meta.page, meta.pages)
      end

      self:header(buf)
      self:schedule()
    end)
  end

  self:header(buf)
  self:schedule()
  return true
end

function M:page(page, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local meta = self.buffers[buf]

  if not meta or not meta.pdf then
    return false, "Current buffer is not a PDF preview"
  end

  if not meta.pages then
    return false, meta.error or "PDF metadata is still loading"
  end

  if type(page) ~= "number" or page % 1 ~= 0 or page < 1 or page > meta.pages then
    return false, "PDF page must be between 1 and " .. meta.pages
  end

  if page ~= meta.page then
    meta.page, meta.error, meta.generation = page, nil, meta.generation + 1
    self:header(buf)
    self:schedule()
  end

  return true
end

function M:step(delta, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local meta = self.buffers[buf]
  if not meta or not meta.pages then
    return false, "PDF metadata is unavailable"
  end
  return self:page(math.max(1, math.min(meta.pages, meta.page + delta)), buf)
end

function M:attach(buf, path)
  if self.buffers[buf] then
    self:release(buf)
  end

  local meta = { path = path, pdf = path:lower():sub(-4) == ".pdf", page = 1, generation = 0 }
  self.buffers[buf] = meta
  vim.b[buf].image_tools_view = true
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "hide"
  vim.bo[buf].swapfile, vim.bo[buf].modeline, vim.bo[buf].buflisted = false, false, true
  vim.bo[buf].undolevels, vim.bo[buf].readonly = -1, true
  self:header(buf)
  vim.bo[buf].filetype = "image_tools"

  local function mapping(key, callback, desc)
    vim.keymap.set("n", key, callback, { buffer = buf, silent = true, desc = desc })
  end

  mapping("r", function()
    self:reload(buf)
  end, "Reload image/PDF preview")
  if meta.pdf then
    mapping("]p", function()
      self:step(vim.v.count1, buf)
    end, "Next PDF page")
    mapping("[p", function()
      self:step(-vim.v.count1, buf)
    end, "Previous PDF page")
  end
  self:reload(buf)
end

function M:sync()
  if self.paused then
    return
  end

  local visible, visible_buffers = {}, {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local meta = self.buffers[buf]

      if meta and vim.api.nvim_win_get_config(win).relative == "" then
        visible[win], visible_buffers[buf] = true, true
        if vim.api.nvim_buf_get_name(buf) ~= meta.path then
          meta.error = "Preview buffer was renamed; reopen the image/PDF"
          self:header(buf)
        end

        local stat = vim.uv.fs_stat(meta.path)
        if
          stat and (not meta.key or require("image_tools.image").key(meta.path, stat) ~= meta.key)
          or not stat and not meta.error
        then
          self:reload(buf)
        end
        if meta.pdf and not meta.pages and not meta.cancel_info and not meta.error then
          self:reload(buf)
        end

        local view = self.views[win]
        if view and view.buf ~= buf then
          self:drop_view(win)
          view = nil
        end
        if not view then
          local saved = {}
          for name, value in pairs(window_options) do
            saved[name], vim.wo[win][name] = vim.wo[win][name], value
          end
          view = {
            buf = buf,
            saved = saved,
            canvas = require("image_tools.render.canvas").new(self.opts, self.dependencies),
          }
          self.views[win] = view
        end

        if meta.error or (meta.pdf and not meta.pages) then
          view.canvas:close()
        else
          local width, height, col, row = require("image_tools.render.canvas").viewport(win)
          local state = view.canvas.state

          if
            view.failed ~= meta.generation
            and (
              not state
              or state.generation ~= meta.generation
              or state.page ~= meta.page
              or state.view_width ~= width
              or state.view_height ~= height
              or state.col ~= col
              or state.row ~= row
              or state.win and not vim.api.nvim_win_is_valid(state.win)
            )
          then
            view.canvas:open(meta, buf, win, function(err)
              if self.views[win] ~= view or self.buffers[buf] ~= meta then
                return
              end
              if err then
                view.failed = meta.generation
                meta.error = err
                self:header(buf)
                self:schedule()
              end
            end)
          end
        end
      end
    end
  end

  for win in pairs(vim.tbl_extend("force", {}, self.views)) do
    if not visible[win] then
      self:drop_view(win)
    end
  end

  for buf, meta in pairs(self.buffers) do
    if not visible_buffers[buf] and meta.cancel_info then
      meta.cancel_info()
      meta.cancel_info = nil
    end
  end
end

function M:open(path)
  self.paused = false
  if type(path) ~= "string" or path == "" or not require("image_tools.image").supported(path) then
    return false, "Choose a supported image or PDF file"
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local buf = vim.fn.bufadd(path)
  if vim.api.nvim_buf_is_loaded(buf) then
    if vim.bo[buf].modified and not self.buffers[buf] then
      return false, "Save the source buffer before opening its preview"
    end
    if not self.buffers[buf] then
      self:attach(buf, path)
    end
  else
    vim.api.nvim_create_autocmd("BufReadCmd", {
      group = self.group,
      buffer = buf,
      once = true,
      callback = function()
        self:attach(buf, path)
      end,
    })
  end
  local ok, err = pcall(vim.api.nvim_cmd, { cmd = "edit", args = { path } }, {})
  if not ok then
    return false, tostring(err)
  end
  self:schedule()
  return true
end

function M:status(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local meta = self.buffers[buf]
  if not meta then
    return nil
  end
  local views = {}
  for win, view in pairs(self.views) do
    if view.buf == buf then
      views[win] = {
        window = view.canvas.state and view.canvas.state.win,
        page = view.canvas.state and view.canvas.state.page,
        cache = view.canvas.transfer:status(),
      }
    end
  end
  return { path = meta.path, page = meta.page, pages = meta.pages, error = meta.error, views = views }
end

function M:setup()
  self.group = vim.api.nvim_create_augroup("image_tools.buffers", { clear = true })
  if self.opts.buffer.enabled then
    local patterns = {}
    for _, extension in ipairs(self.opts.buffer.formats) do
      patterns[#patterns + 1] = "*."
        .. extension:gsub("%a", function(c)
          return "[" .. c:lower() .. c:upper() .. "]"
        end)
    end
    if #patterns > 0 then
      vim.api.nvim_create_autocmd("BufReadCmd", {
        group = self.group,
        pattern = patterns,
        callback = function(event)
          self:attach(event.buf, vim.api.nvim_buf_get_name(event.buf))
        end,
      })
    end
  end
  vim.api.nvim_create_autocmd({
    "BufWinEnter",
    "WinEnter",
    "TabEnter",
    "TabLeave",
    "WinClosed",
    "VimResized",
    "WinResized",
    "FocusGained",
    "BufFilePost",
  }, {
    group = self.group,
    callback = function()
      self:schedule()
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = self.group,
    pattern = "winbar",
    callback = function()
      self:schedule()
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.group,
    callback = function()
      for _, view in pairs(self.views) do
        local state = view.canvas.state
        if state and state.id then
          vim.api.nvim_set_hl(
            0,
            state.highlight,
            require("image_tools.terminal.protocol").highlight(state.id, state.placement_id)
          )
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = self.group,
    callback = function(event)
      self:release(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = self.group,
    callback = function()
      self:destroy()
    end,
  })
  vim.api.nvim_create_autocmd("VimSuspend", {
    group = self.group,
    callback = function()
      self:clear_cache()
      for _, meta in pairs(self.buffers) do
        if meta.cancel_info then
          meta.cancel_info()
          meta.cancel_info = nil
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResume", "BufEnter", "TabEnter" }, {
    group = self.group,
    callback = function()
      self.paused = false
      self:schedule()
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      local extension = path:match("%.([^./]+)$")
      if
        vim.b[buf].image_tools_view
        or self.opts.buffer.enabled
          and extension
          and vim.tbl_contains(self.opts.buffer.formats, extension:lower())
          and not vim.bo[buf].modified
          and vim.bo[buf].buftype == ""
      then
        self:attach(buf, path)
      end
    end
  end
  self:schedule()
end

return M
