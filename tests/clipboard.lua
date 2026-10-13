vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local tmp = assert(vim.env.IMAGE_TOOLS_TEST_TMP) .. "/clipboard"
vim.fn.mkdir(tmp, "p")
local fixture = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png"
local script = tmp .. "/fake pngpaste"
vim.fn.writefile({ "#!/bin/sh", 'cp "$IMAGE_TOOLS_ROOT/tests/fixture.png" "$1"' }, script)
vim.uv.fs_chmod(script, 493)
local C = require("image_tools.clipboard")
local count = 0
local function check(value, msg)
  count = count + 1
  assert(value, msg)
end
local function buffer(name)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/" .. name .. ".md")
  vim.bo.filetype = "markdown"
  return buf
end
local function paste(opts)
  opts = vim.tbl_extend("force", { pngpaste = script }, opts or {})
  local done, err, paths
  C.paste(opts, function(e, p)
    done, err, paths = true, e, p
  end, { macos = true })
  assert(
    vim.wait(5000, function()
      return done
    end),
    "Paste timeout"
  )
  return err, paths
end
local buf = buffer("png")
local err, paths = paste({ filename = "clip with space.png" })
check(not err, err)
check(vim.fn.readblob(paths[1]) == vim.fn.readblob(fixture), "PNG bytes preserved")
check(
  require("image_tools.document").at_line(buf, 2, { max_scan_lines = 100 }) == paths[1],
  "Inserted clipboard link resolves"
)
buffer("jpg")
err, paths = paste({ format = "jpg" })
check(not err, err)
check(paths[1]:sub(-4) == ".jpg", "Converted extension")
local result = vim.system({ "magick", "identify", "-format", "%m", paths[1] }):wait()
check(result.code == 0 and result.stdout == "JPEG", "Real conversion encoding")
buffer("cancel")
local done, prompt
local original = vim.ui.input
vim.ui.input = function(_, cb)
  prompt = cb
end
local cancel = C.paste({ pngpaste = script, prompt_for_file_name = true, directory = "cancel" }, function(e)
  done, err = true, e
end, { macos = true })
assert(vim.wait(2000, function()
  return prompt ~= nil
end))
cancel()
prompt("late.png")
vim.wait(50)
check(done and err == "Cancelled", "Paste cancellation")
check(#vim.fn.glob(tmp .. "/cancel/*", false, true) == 0, "Cancelled paste produces no assets")
vim.ui.input = original
buffer("missing")
err = paste({ pngpaste = tmp .. "/absent" })
check(err and err:match("pngpaste is required"), "Missing executable actionable")
buffer("empty")
vim.fn.writefile({ "#!/bin/sh", "exit 1" }, script)
err = paste()
check(err and err:match("Cannot read"), "Empty clipboard fails")
check(#vim.api.nvim_buf_get_lines(0, 0, -1, false) == 1, "Failed paste inserts no text")
print("clipboard: " .. count .. " assertions passed")
