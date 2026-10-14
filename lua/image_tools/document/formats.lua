local M = {}
local aliases = { markdown = "markdown", tex = "tex", latex = "tex", plaintex = "tex", typst = "typst" }

function M.kind(filetype)
  return aliases[filetype]
end
function M.get(filetype)
  local kind = M.kind(filetype)
  return kind and require("image_tools.document." .. kind) or nil
end
function M.supported(filetype)
  return M.kind(filetype) ~= nil
end

return M
