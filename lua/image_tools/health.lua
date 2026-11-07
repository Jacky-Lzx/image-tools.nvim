local M = {}

function M.check()
  vim.health.start("image-tools.nvim")
  if vim.fn.has("nvim-0.12") == 0 then
    vim.health.error("Neovim 0.12+ is required", { "Upgrade Neovim" })
    return
  end
  local issues = {}
  local function problem(level, message, advice)
    issues[#issues + 1] = { level = level, message = message, advice = advice }
  end
  local plugin = package.loaded.image_tools
  local state = plugin and plugin.status()
  if not state or not state.configured then
    vim.health.info("Not configured; image feature checks skipped.")
    return
  end
  local opts = plugin.configuration()
  local supported, reason = require("image_tools.terminal").supports(opts)
  if #vim.api.nvim_list_uis() > 0 and not supported then
    problem(
      "warn",
      tostring(reason) .. "; terminal image display is unavailable.",
      { "Use a Kitty graphics compatible terminal" }
    )
  end
  local tools = state.tools
  if vim.fn.executable(tools.magick) == 0 then
    problem(
      "warn",
      tools.magick .. ": unavailable; non-PNG conversion is limited.",
      { "Install ImageMagick or configure magick" }
    )
  end
  if opts.buffer.enabled and vim.tbl_contains(opts.buffer.formats, "pdf") then
    local missing = {}
    for _, cmd in ipairs({ tools.pdfinfo, "gs" }) do
      if vim.fn.executable(cmd) == 0 then
        missing[#missing + 1] = cmd
      end
    end
    if #missing > 0 then
      problem(
        "warn",
        "PDF tools unavailable: " .. table.concat(missing, ", ") .. "; PDF previews are limited.",
        { "Install Poppler and Ghostscript or disable PDF buffer previews" }
      )
    end
  end
  if opts.math.enabled then
    local missing = {}
    for _, cmd in ipairs({ tools.math_latex, tools.math_dvipng }) do
      if vim.fn.executable(cmd) == 0 then
        missing[#missing + 1] = cmd
      end
    end
    if #missing > 0 then
      problem(
        "warn",
        "Formula tools unavailable: " .. table.concat(missing, ", ") .. "; formula rendering is disabled.",
        { "Install the configured TeX tools or set math.enabled = false" }
      )
    end
  end
  if state.remote.enabled and vim.fn.executable(state.remote.curl) == 0 then
    problem(
      "warn",
      state.remote.curl .. ": unavailable; enabled remote image loading cannot run.",
      { "Install/configure curl or disable remote.enabled" }
    )
  end
  local cache = state.disk_cache
  local stat = cache and vim.uv.fs_stat(cache.path)
  if stat and stat.type ~= "directory" then
    problem("error", "Cache path is not a directory: " .. cache.path, { "Configure cache to use a directory" })
  end

  if #issues == 0 and #vim.api.nvim_list_uis() == 0 then
    vim.health.info("Conversion requirements are available; terminal checks need an attached UI. Details: :ImageInfo")
    return
  end
  table.sort(issues, function(a, b)
    if a.level ~= b.level then
      return a.level == "error"
    end
    return a.message < b.message
  end)
  for _, issue in ipairs(issues) do
    vim.health[issue.level](issue.message, issue.advice)
  end
  if #issues == 0 then
    vim.health.ok("Configured image rendering requirements are available.")
  end
  vim.health.info("Details: :ImageInfo")
end

return M
