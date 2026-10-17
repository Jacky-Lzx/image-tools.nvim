-- Clipboard processing presets use argv, so filenames never become shell code.
local M = {}
local formats = { png = true, jpg = true, webp = true, avif = true }
local presets = {
  { name = "Original PNG", format = "png" },
  { name = "AVIF", format = "avif", quality = 75 },
  { name = "JPEG", format = "jpg", quality = 85 },
  { name = "WebP up to 1600px", format = "webp", quality = 75, resize = "1600x1600>" },
}

local function validate_preset(preset)
  assert(type(preset) == "table" and not vim.islist(preset), "process preset must be a named option table")
  assert(preset.name == nil or type(preset.name) == "string", "process name must be a string")
  assert(preset.format == nil or formats[preset.format], "process format must be png, jpg, webp or avif")
  assert(
    preset.quality == nil or type(preset.quality) == "number" and preset.quality >= 1 and preset.quality <= 100,
    "process quality must be between 1 and 100"
  )
  assert(
    preset.resize == nil or type(preset.resize) == "string" and preset.resize ~= "",
    "resize must be a geometry string"
  )
  if preset.command then
    assert(
      type(preset.command) == "table" and vim.islist(preset.command) and #preset.command > 0,
      "command must be argv"
    )
    local input, output = false, false
    for _, arg in ipairs(preset.command) do
      assert(type(arg) == "string" and not arg:find("%z"), "command arguments must be strings without NUL")
      input = input or arg:find("$INPUT", 1, true) ~= nil
      output = output or arg:find("$OUTPUT", 1, true) ~= nil
    end
    assert(preset.command[1] ~= "" and input and output, "command needs an executable, $INPUT and $OUTPUT")
  end
  for key in pairs(preset) do
    assert(
      vim.tbl_contains({ "name", "format", "quality", "resize", "command" }, key),
      "Unknown process option: " .. key
    )
  end
end

function M.validate(process)
  if process == nil or process == false or process == "select" then
    return
  end
  assert(type(process) == "table", "process must be a preset, list, select or false")
  if vim.islist(process) then
    assert(#process > 0, "process list must not be empty")
    for _, preset in ipairs(process) do
      validate_preset(preset)
    end
  else
    validate_preset(process)
  end
end

function M.select(process, filetype, default_format, callback, prompt)
  M.validate(process)
  local choices = process == "select" and vim.deepcopy(presets) or vim.deepcopy(process)
  local list = vim.islist(choices) and choices or { choices }
  local supported = require("image_tools.workflow.insert").supported
  list = vim.tbl_filter(function(preset)
    return supported(filetype, "clipboard." .. (preset.format or default_format))
  end, list)
  assert(#list > 0, "No clipboard processing presets support " .. filetype)
  if #list == 1 then
    callback(list[1])
  else
    vim.ui.select(list, {
      prompt = prompt or "Clipboard image processing:",
      format_item = function(preset)
        return preset.name or ((preset.format or default_format) .. (preset.resize and " " .. preset.resize or ""))
      end,
    }, callback)
  end
end

function M.command(opts, input, output)
  if opts.command then
    validate_preset({ command = opts.command })
    return vim.tbl_map(function(arg)
      return (
        arg:gsub("%$([A-Z]+)", function(key)
          return ({ INPUT = input, OUTPUT = output })[key] or "$" .. key
        end)
      )
    end, opts.command)
  end
  local limits = require("image_tools.media.conversion_limits")
  local command = {
    opts.magick or "magick",
    "-limit",
    "memory",
    limits.MAGICK_MEMORY,
    "-limit",
    "map",
    limits.MAGICK_MAP,
    "-limit",
    "disk",
    limits.MAGICK_DISK,
    input,
    "-auto-orient",
  }
  if opts.resize then
    vim.list_extend(command, { "-resize", opts.resize })
  end
  vim.list_extend(command, { "-quality", tostring(opts.quality or 75), output })
  return command
end

return M
