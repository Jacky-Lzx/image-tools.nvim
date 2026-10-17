-- Select standalone Markdown images and display math. Parsing/context remains
-- owned by the existing adapters; this module decides eligibility and visibility.
local M = {}

function M.eligible(buf, ref)
  if vim.bo[buf].filetype ~= "markdown" or not ref then
    return false
  end
  if ref.kind == "math" then
    local formula = ref.formula
    local environment = formula:match("^\\begin%s*{([%a*]+)}")
    if
      not (
        formula:sub(1, 2) == "$$"
        or formula:sub(1, 2) == "\\["
        or environment and environment ~= "math" and environment ~= "math*"
      )
    then
      return false
    end
  end
  local lines = vim.api.nvim_buf_get_lines(buf, ref.start_row - 1, ref.end_row, false)
  return #lines > 0
    and lines[1]:sub(1, ref.start_col):match("^%s*$") ~= nil
    and lines[#lines]:sub(ref.end_col + 1):match("^%s*$") ~= nil
end

-- Called inside the target window. Skip closed folds as ranges, including their
-- headers. Multiline formulas may start above the viewport but must end in it.
function M.collect(buf, win, opts, anchors)
  local info = vim.fn.getwininfo(win)[1]
  if not info or vim.bo[buf].filetype ~= "markdown" then
    return {}
  end
  local first, last = math.max(1, info.topline - 1), math.min(info.botline, opts.max_scan_lines)
  local topfill = vim.fn.winsaveview().topfill
  local result, seen, row = {}, {}, first
  local markdown, formulas = require("image_tools.document.markdown"), require("image_tools.document.math")
  while row <= last and #result < opts.inline.max_images do
    local folded = vim.fn.foldclosed(row)
    if folded ~= -1 then
      row = vim.fn.foldclosedend(row) + 1
    else
      local selected
      for _, item in ipairs(markdown.references(buf, row, opts)) do
        if M.eligible(buf, item.reference) then
          selected = item
          break
        end
      end
      if not selected then
        local ref = formulas.find(buf, row, nil, opts)
        if ref and ref.end_row <= last and M.eligible(buf, ref) then
          selected = { path = ref.path, reference = ref }
        end
      end
      if selected then
        local ref, visible = selected.reference, true
        for covered = ref.start_row, ref.end_row do
          if vim.fn.foldclosed(covered) ~= -1 then
            visible = false
            break
          end
        end
        -- A previous anchor can still own partially scrolled virtual lines.
        if ref.end_row < info.topline then
          visible = anchors and anchors[ref.end_row] and topfill > 0 or false
        end
        local id = table.concat(
          { ref.start_row, ref.start_col, ref.end_row, ref.end_col, selected.path or selected.error or "" },
          ":"
        )
        if visible and not seen[id] then
          selected.key = id
          result[#result + 1], seen[id] = selected, true
        end
        row = math.max(row + 1, ref.end_row + 1)
      else
        row = row + 1
      end
    end
  end
  return result
end

return M
