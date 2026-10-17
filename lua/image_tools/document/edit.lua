-- Produce destination-only edits for recognized literal references. Custom
-- adapters must explicitly supply path_edit; guessing can corrupt their syntax.
local M = {}

function M.path(buf, ft, ref, target, document, opts)
  local formats = require("image_tools.document.formats")
  local adapter = assert(formats.get(ft))
  assert(adapter.supports_image(target), "Unsupported destination image format for " .. ft)
  if adapter.validate_reference then
    adapter.validate_reference(target, document, opts, buf)
  end
  local base = adapter.insertion_base(document, opts, buf)
  local relative = require("image_tools.document.paths").relative(target, base)
  adapter.markup(relative) -- Apply the same path constraints as insertion.
  if adapter.path_edit then
    return adapter.path_edit(buf, ref, relative, opts)
  end
  local kind = formats.kind(ft)
  local line = vim.api.nvim_buf_get_lines(buf, ref.end_row - 1, ref.end_row, false)[1]
  if kind == "typst" then
    local first = assert(line:find('"', ref.start_col + 1, true))
    local _, last = require("image_tools.document.typst").quoted(line, first)
    return {
      row = ref.start_row,
      first = first,
      last = assert(last) - 1,
      text = relative:gsub("\\", "\\\\"):gsub('"', '\\"'),
    }
  end
  if kind == "tex" then
    -- The final argument is a same-line literal, optionally \detokenize{...}.
    -- Walk balanced braces backwards so options and surrounding commands survive.
    local depth, opening = 0, nil
    for i = ref.end_col, 1, -1 do
      local prefix = line:sub(1, i - 1):match("(\\*)$")
      if #prefix % 2 == 0 then
        local char = line:sub(i, i)
        if char == "}" then
          depth = depth + 1
        end
        if char == "{" then
          depth = depth - 1
          if depth == 0 then
            opening = i
            break
          end
        end
      end
    end
    assert(opening, "LaTeX image argument is no longer available")
    return { row = ref.end_row, first = opening, last = ref.end_col - 1, text = relative }
  end
  error("Destination rewriting is not implemented for " .. ft .. "; register path_edit")
end

return M
