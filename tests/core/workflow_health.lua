vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local reports = {}
for _, kind in ipairs({ "start", "ok", "warn", "info", "error" }) do
  vim.health[kind] = function(message)
    reports[#reports + 1] = { kind, message }
  end
end
require("image_tools.health").check()
assert(#reports == 2 and reports[2][1] == "info", "Unconfigured features are skipped without warnings")
assert(not package.loaded.image_tools and not package.loaded["image_tools.runtime"])
assert(not package.loaded.selection_tools and not package.loaded["git_tools.diff"])
print("Image health: unconfigured workflows do not load providers or warn")
