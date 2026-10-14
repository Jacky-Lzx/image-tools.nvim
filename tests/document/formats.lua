vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local D, I, Picker =
  require("image_tools.document"), require("image_tools.workflow.insert"), require("image_tools.workflow.picker")
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/format-policy"
vim.fn.mkdir(tmp .. "/chapter", "p")
local source = tmp .. "/image space.png"
assert(vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", source))
local count, config = 0, nil
local function check(value, message)
  count = count + 1
  assert(value, message)
end
-- Capture the optional picker adapter's configuration; insertion and decoding
-- still operate on actual Neovim buffers and copied assets below.
local previous_snacks, previous_module = _G.Snacks, package.loaded.snacks
local snacks = { picker = { util = {
  path = function(item)
    return item.path
  end,
} } }
snacks.picker.files = function(options)
  config = options
  return {
    close = function(self)
      options.on_close(self)
    end,
  }
end
_G.Snacks, package.loaded.snacks = snacks, snacks
for _, filetype in ipairs({ "markdown", "tex", "latex", "plaintex", "typst" }) do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/chapter/" .. filetype .. ".txt")
  vim.bo.filetype = filetype
  local cancelled
  local picker = Picker.pick({}, nil, function() end, function(err)
    cancelled = err
  end)
  check(picker ~= nil and vim.tbl_contains(config.ft, "png"), filetype .. ": picker exposes importable PNGs")
  if filetype == "markdown" then
    check(vim.tbl_contains(config.ft, "tiff"), "Markdown picker includes TIFF alongside its TIFF import support")
  else
    check(not vim.tbl_contains(config.ft, "avif"), filetype .. ": compiler-incompatible AVIFs stay out of picker")
  end
  picker:close()
  check(cancelled == "Cancelled", filetype .. ": picker cancellation releases the captured position")
  local done, failure, paths
  I.files({ source }, { root = tmp, reference_root = tmp, directory = "assets-" .. filetype }, function(err, outputs)
    done, failure, paths = true, err, outputs
  end)
  check(vim.wait(3000, function()
    return done
  end) and not failure, filetype .. ": actual import succeeds")
  check(
    D.at_line(buf, 2, { root = tmp, max_scan_lines = 100, treesitter = false }) == paths[1],
    filetype .. ": emitted reference resolves to the imported file from a nested document"
  )
  local exported = D.adapter(filetype).image_formats()
  exported[1] = "invalid"
  check(
    vim.tbl_contains(D.adapter(filetype).image_formats(), "png"),
    filetype .. ": picker format lists are independent"
  )
end
check(not I.supported("lua", source), "Unsupported document types do not inherit Markdown insertion capabilities")
vim.bo.filetype = "lua"
local failure
check(Picker.pick({}, nil, function() end, function(err)
  failure = err
end) == nil and failure ~= nil, "Unsupported picker document fails immediately")
local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("image_tools.insert"), 0, -1, {})
check(#marks == 0, "Rejected picker context leaves no captured insertion position")
_G.Snacks, package.loaded.snacks = previous_snacks, previous_module
print("document adapters: " .. count .. " assertions passed")
