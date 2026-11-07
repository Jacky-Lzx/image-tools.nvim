-- Activate automatic previews without initializing image-tools for plain text.
-- These are conservative hints, not reference parsers: image-tools still owns
-- syntax exclusions, multiline references, path validation and rendering.
local M = {}
local api = vim.api
local automatic, markdown_math, activate, group
local options = {}
local generation, proxy_commands = 0, {}
local watched = {}
local pending = {}
local hints = {
  markdown = function(line)
    return line:find("![", 1, true)
      or markdown_math
        and (line:find("$", 1, true) or line:find("\\(", 1, true) or line:find("\\[", 1, true) or line:find(
          "\\begin",
          1,
          true
        ))
  end,
  tex = function(line)
    return line:find("\\includegraphics", 1, true)
  end,
  typst = function(line)
    return line:find("%f[%w_]image%s*%(") or line:find("%f[%w_]image%s*$")
  end,
  html = function(line)
    return line:lower():find("<img%f[^%w_]")
  end,
}
hints.plaintex, hints.latex = hints.tex, hints.tex

local function loaded()
  local image = package.loaded.image_tools
  return image and image.status().configured and image or nil
end

local function candidate(buf, first, last)
  if
    not automatic
    or loaded()
    or not api.nvim_buf_is_valid(buf)
    or vim.bo[buf].buftype ~= ""
    or vim.b[buf].image_tools_preview_owner
    or #vim.fn.win_findbuf(buf) == 0
  then
    return false
  end
  local hint = hints[vim.bo[buf].filetype]
  if not hint and options.path_preview ~= false then
    hint = require("image_tools.document.generic").hint
    if not first then
      local win = vim.fn.win_findbuf(buf)[1]
      first = api.nvim_win_get_cursor(win)[1] - 1
      last = first + 1
    end
  end
  if not hint then
    return false
  end
  last = last or api.nvim_buf_line_count(buf)
  -- Bound each allocation, including for a newly opened large document.
  for row = first or 0, last - 1, 256 do
    for _, line in ipairs(api.nvim_buf_get_lines(buf, row, math.min(row + 256, last), false)) do
      if hint(line) then
        return true
      end
    end
  end
  return false
end

local function request(buf)
  if pending[buf] then
    return
  end
  pending[buf] = true
  local version = generation
  -- Buffer callbacks run under textlock. Recheck after scheduling so a deleted
  -- candidate, closed buffer or disabled automatic preview cannot activate us.
  vim.schedule(function()
    if version ~= generation then
      return
    end
    pending[buf] = nil
    if candidate(buf) then
      activate()
    end
  end)
end

local function watch(buf)
  if not automatic or loaded() or not api.nvim_buf_is_loaded(buf) then
    return
  end
  if not watched[buf] then
    local version = generation
    watched[buf] = api.nvim_buf_attach(buf, false, {
      on_lines = function(_, changed, _, first, _, last)
        if version ~= generation then
          return true
        end
        if loaded() then
          watched[changed] = nil
          return true
        end
        -- Scan changed lines only; ordinary typing never rescans the document.
        if candidate(changed, first, last) then
          request(changed)
        end
      end,
      on_reload = function(_, changed)
        if version ~= generation then
          return true
        end
        if loaded() then
          watched[changed] = nil
          return true
        end
        if candidate(changed) then
          request(changed)
        end
      end,
      on_detach = function(_, changed)
        if version == generation then
          watched[changed] = nil
        end
      end,
    })
  end
  if candidate(buf) then
    request(buf)
  end
end

-- Return a private option copy for the public facade's first service request.
function M.options()
  local result = vim.deepcopy(options)
  if automatic ~= nil then
    result.auto_preview = automatic
  end
  return result
end
function M.enabled()
  local image = loaded()
  if image then
    return image.status().auto_preview
  end
  return automatic
end
function M.set_auto_preview(enabled)
  assert(type(enabled) == "boolean", "image-tools: automatic preview state must be boolean")
  local image = loaded()
  automatic = image and image.set_auto_preview(enabled) or enabled
  if automatic and not image then
    for _, buf in ipairs(api.nvim_list_bufs()) do
      watch(buf)
    end
  end
  return automatic
end
function M.toggle()
  return M.set_auto_preview(not M.enabled())
end
function M.configured()
  generation = generation + 1
  watched, pending, proxy_commands = {}, {}, {}
  if group then
    api.nvim_del_augroup_by_id(group)
    group = nil
  end
end
function M.ensure()
  local image = require("image_tools")
  if not image.status().configured then
    image.setup(M.options())
  end
  return image
end
function M.dispose()
  local commands = proxy_commands
  M.configured()
  for _, cleanup in ipairs(commands) do
    cleanup()
  end
  proxy_commands = {}
  options = {}
  automatic, markdown_math, activate = nil, nil, nil
end

function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "image-tools: setup expects a table")
  require("image_tools.config").resolve(opts)
  M.dispose()
  options = vim.deepcopy(opts or {})
  automatic, activate = options.auto_preview ~= false, M.ensure
  if loaded() then
    require("image_tools").setup(M.options())
    return
  end
  markdown_math = not (type(options.math) == "table" and options.math.enabled == false)
  group = api.nvim_create_augroup("ImageToolsBootstrap", { clear = true })
  api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
    group = group,
    callback = function(event)
      watch(event.buf)
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(event)
      if not hints[vim.bo[event.buf].filetype] and candidate(event.buf) then
        request(event.buf)
      end
    end,
  })
  -- Install native command definitions against a resolver. Registration itself
  -- does not create a Runtime, decode images, or allocate terminal resources.
  local proxy = {
    bind = function(_, callback)
      return function(...)
        M.ensure()
        return callback(...)
      end
    end,
  }
  setmetatable(proxy, {
    __index = function(_, key)
      local runtime = require("image_tools")._runtime()
      local value = runtime[key]
      if type(value) == "function" then
        return function(_, ...)
          return value(runtime, ...)
        end
      end
      return value
    end,
  })
  require("image_tools.commands").register(proxy)
  proxy_commands = proxy.commands
  local buffer = options.buffer or {}
  if buffer.enabled ~= false then
    local patterns = {}
    for _, extension in ipairs(buffer.formats or require("image_tools.defaults").buffer.formats) do
      patterns[#patterns + 1] = "*."
        .. extension:gsub("%a", function(c)
          return "[" .. c:lower() .. c:upper() .. "]"
        end)
    end
    if #patterns > 0 then
      api.nvim_create_autocmd("BufReadCmd", {
        group = group,
        pattern = patterns,
        callback = function(event)
          M.ensure()
          -- Replay only this plugin's new reader, before native binary reads.
          api.nvim_exec_autocmds("BufReadCmd", { group = "image_tools.buffers", buffer = event.buf, modeline = false })
        end,
      })
    end
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    watch(buf)
  end
end
return M
