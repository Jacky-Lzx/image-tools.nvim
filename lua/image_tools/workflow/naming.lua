-- Naming is separate from publication: the import transaction still owns
-- extension preservation, filename sanitizing, collisions and content reuse.
local M = {}

function M.validate(value)
  assert(
    value == nil or type(value) == "function" or type(value) == "string" and value ~= "",
    "file_name must be a nonempty os.date format or function"
  )
end

function M.resolve(opts, context)
  M.validate(opts.file_name)
  context = vim.tbl_extend("force", context, {
    document_name = vim.fn.fnamemodify(context.document, ":t:r"),
    timestamp = context.timestamp or os.time(),
  })
  local name = opts.filename
  if name == nil then
    if type(opts.file_name) == "function" then
      name = opts.file_name(vim.deepcopy(context))
    elseif opts.file_name or context.kind == "clipboard" then
      name = os.date(opts.file_name or "%Y-%m-%d_%H-%M-%S", context.timestamp)
    else
      name = context.source_name
    end
  end
  assert(
    type(name) == "string" and name ~= "" and name ~= "." and name ~= ".." and not name:find("[/\\%z\r\n]"),
    "Image name must be a single nonempty filename"
  )
  return name
end

return M
