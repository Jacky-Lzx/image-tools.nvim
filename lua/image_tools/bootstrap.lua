-- Activate automatic previews without initializing image-tools for plain text.
-- These are conservative hints, not reference parsers: image-tools still owns
-- syntax exclusions, multiline references, path validation and rendering.
local M = {}
local api = vim.api
local automatic, markdown_math, activate, group
local options = {}
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
    or #vim.fn.win_findbuf(buf) == 0
  then
    return false
  end
  local hint = hints[vim.bo[buf].filetype]
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
  -- Buffer callbacks run under textlock. Recheck after scheduling so a deleted
  -- candidate, closed buffer or disabled automatic preview cannot activate us.
  vim.schedule(function()
    pending[buf] = nil
    if candidate(buf) then
      activate()
    end
  end)
end

local function watch(buf)
  if not automatic or loaded() or not api.nvim_buf_is_loaded(buf) or not hints[vim.bo[buf].filetype] then
    return
  end
  if not watched[buf] then
    watched[buf] = api.nvim_buf_attach(buf, false, {
      on_lines = function(_, changed, _, first, _, last)
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
        if loaded() then
          watched[changed] = nil
          return true
        end
        if candidate(changed) then
          request(changed)
        end
      end,
      on_detach = function(_, changed)
        watched[changed] = nil
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
function M.toggle()
  local image = loaded()
  automatic = image and image.toggle() or not automatic
  if automatic and not image then
    for _, buf in ipairs(api.nvim_list_bufs()) do
      watch(buf)
    end
  end
  return automatic
end
function M.configured()
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
function M.setup(opts)
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
