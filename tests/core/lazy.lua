-- Run the README spec against an explicitly supplied, real lazy.nvim checkout.
local root = assert(vim.env.IMAGE_TOOLS_ROOT)
local temporary = assert(vim.env.IMAGE_TOOLS_TEST_TMP)
local lazy_root = assert(vim.env.IMAGE_TOOLS_LAZY_ROOT)
local scenario = vim.env.IMAGE_TOOLS_LAZY_SCENARIO
local script = root .. "/tests/core/lazy.lua"
if not scenario then
  for _, name in ipairs({ "dormant", "document", "command", "require", "image", "pdf", "startup-image", "startup-pdf" }) do
    local args = { vim.v.progpath, "--headless", "-i", "NONE" }
    if name:match("^startup") then
      local ext = name == "startup-image" and "png" or "pdf"
      local path = temporary .. "/startup-" .. ext .. "." .. ext:upper()
      vim.fn.writefile(vim.fn.readfile(root .. "/tests/fixtures/fixture." .. ext, "b"), path, "b")
      vim.list_extend(args, { "-u", script, path })
    else
      vim.list_extend(args, { "-u", "NONE", "--noplugin", "-l", script })
    end
    local result = vim
      .system(args, {
        text = true,
        env = {
          IMAGE_TOOLS_LAZY_SCENARIO = name,
          XDG_CACHE_HOME = temporary .. "/cache",
          XDG_STATE_HOME = temporary .. "/state",
          NVIM_LOG_FILE = temporary .. "/nvim.log",
        },
      })
      :wait(10000)
    assert(result.code == 0, name .. ": " .. (result.stderr or "") .. (result.stdout or ""))
    print("image-tools lazy.nvim: " .. name .. " passed")
  end
  return
end

local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
local spec = assert(loadstring(assert(readme:match("```lua\n(.-)\n```"))))()
spec.dir = root
vim.opt.rtp:prepend(lazy_root)
vim.o.loadplugins = true
require("lazy").setup({ spec }, {
  root = temporary .. "/lazy-" .. scenario,
  lockfile = temporary .. "/lazy-lock-" .. scenario .. ".json",
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  performance = { rtp = { reset = false } },
})
local function dormant()
  assert(not package.loaded.image_tools, "Plugin loaded before its trigger")
end
local function configured()
  assert(package.loaded.image_tools, "Trigger did not load the plugin")
  assert(require("image_tools").status().configured, "Trigger did not configure the plugin")
end
local function viewer()
  configured()
  assert(vim.b.image_tools_view, "Binary file was not intercepted")
  assert(vim.bo.buftype == "nofile", "Binary file was read into a normal buffer")
  assert(not package.loaded["image_tools.render.preview"], "File viewing loaded floating previews")
  -- Diagnostics also work before the first scheduled canvas/pixel allocation.
  vim.cmd("ImageInfo")
end
dormant()
if scenario:match("^startup") then
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      local ok, err = pcall(viewer)
      if not ok then
        io.stderr:write(tostring(err) .. "\n")
        vim.cmd("cquit 1")
      end
      vim.cmd("qa!")
    end,
  })
elseif scenario == "dormant" then
  vim.cmd("edit " .. vim.fn.fnameescape(temporary .. "/unrelated.lua"))
  vim.bo.filetype = "lua"
  vim.wait(20, function()
    return false
  end)
  dormant()
elseif scenario == "document" then
  vim.cmd("edit " .. vim.fn.fnameescape(temporary .. "/note.md"))
  vim.bo.filetype = "markdown"
  configured()
elseif scenario == "command" then
  vim.cmd("ImagePreviewClose")
  configured()
  assert(not package.loaded["image_tools.render.preview"], "Closing an unused preview loaded its controller")
elseif scenario == "require" then
  require("image_tools")
  configured()
else
  local ext = scenario == "image" and "png" or "pdf"
  local path = temporary .. "/lazy-fixture." .. ext:upper()
  vim.fn.writefile(vim.fn.readfile(root .. "/tests/fixtures/fixture." .. ext, "b"), path, "b")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  viewer()
end
