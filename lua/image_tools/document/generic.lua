-- Purpose: Find literal local image paths on one line, independently of language syntax.
-- Architecture: Used only when no document adapter exists; never enumerate assets or fetch URLs.
-- Ownership: Keep no state. Return original byte ranges and recheck the filesystem on each lookup.
local M = {}
local formats = require("image_tools.media.formats")
local separators = "[%s%[%]{}()<>,;=\"'`]"

-- Cheap bootstrap hint; actual lookup also resolves the path and requires a regular file.
function M.hint(line)
  for extension in line:gmatch("%.([%a]+)") do
    if formats.supported("file." .. extension) then
      return true
    end
  end
  return false
end

function M.find(buf, row, col, opts)
  local length = vim.api.nvim_buf_get_offset(buf, row) - vim.api.nvim_buf_get_offset(buf, row - 1) - 1
  if length > 16 * 1024 then
    return nil, "Path preview line exceeds 16 KiB", "miss"
  end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local document = vim.api.nvim_buf_get_name(buf)
  local pos = 1
  while pos <= #line do
    local first, last, finish
    local char = line:sub(pos, pos)
    if char == '"' or char == "'" or char == "`" then
      finish = line:find(char, pos + 1, true)
      if finish then
        first, last = pos + 1, finish - 1
      end
    elseif not char:match(separators) then
      first = pos
      finish = line:find(separators, pos) or (#line + 1)
      last = finish - 1
      -- Sentence punctuation is not part of an unquoted filename.
      while last >= first and line:sub(last, last):match("[.!?:]") do
        last = last - 1
      end
      finish = finish - 1
    end
    if first then
      local source = line:sub(first, last)
      if formats.supported(source) and (col == nil or col >= first - 1 and col < last) then
        local literal = source
        if literal:sub(1, 2) == "~/" then
          literal = vim.uv.os_homedir() .. literal:sub(2)
        end
        local path = require("image_tools.document.paths").resolve(
          literal,
          document,
          vim.tbl_extend("force", opts, { literal = true, remote = { enabled = false } })
        )
        local stat = path and vim.uv.fs_stat(path)
        if stat and stat.type == "file" then
          return path,
            nil,
            nil,
            {
              src = source,
              start_row = row,
              end_row = row,
              start_col = first - 1,
              end_col = last,
            }
        end
      end
    end
    pos = (finish or pos) + 1
  end
  return nil, "No existing local image path on the current line", "miss"
end

return M
