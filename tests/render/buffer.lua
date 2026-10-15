vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
vim.o.termguicolors, vim.o.hidden = true, true
local tmp = vim.env.IMAGE_TOOLS_TEST_TMP .. "/buffer"
vim.fn.mkdir(tmp, "p")
tmp = assert(vim.uv.fs_realpath(tmp))
local png = tmp .. "/picture.PNG"
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", png)
local original_hash = vim.fn.sha256(table.concat(vim.fn.readfile(png, "b"), "\n"))
local writes, count = {}, 0
local function check(value, msg)
  count = count + 1
  assert(value, msg)
end
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(command)
    writes[#writes + 1] = command
  end,
  request = function(_, command, _, callback)
    writes[#writes + 1] = command
    local cancelled = false
    vim.schedule(function()
      if not cancelled then
        callback(nil)
      end
    end)
    return function()
      cancelled = true
    end
  end,
}
local image = require("image_tools")
image.setup({ auto_preview = false, cache = tmp .. "/cache" })
local function ready(win)
  local windows = type(win) == "table" and win or { win or vim.api.nvim_get_current_win() }
  return vim.wait(12000, function()
    local status = image.status().buffer
    if not status then
      return false
    end
    for _, owner in ipairs(windows) do
      local view = status.views[owner]
      if not view or not view.window or not vim.api.nvim_win_is_valid(view.window) or view.page ~= status.page then
        return false
      end
    end
    return true
  end)
end
vim.cmd.edit(png)
check(ready(), "Native :edit displays image")
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
check(
  vim.bo.buftype == "nofile" and vim.bo.readonly and not vim.bo.modifiable and not vim.bo.modified,
  "Read-only file buffer"
)
check(
  vim.bo.filetype == "image_tools" and vim.api.nvim_buf_get_name(buf) == png,
  "Filename retained with view filetype"
)
check(
  not vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("\137PNG", 1, true),
  "Binary bytes are never loaded into document text"
)
local frame = image.status().buffer.views[win].window
local cfg = vim.api.nvim_win_get_config(frame)
check(
  cfg.relative == "win" and cfg.win == win and cfg.row == 1 and cfg.col == 0,
  "Canvas belongs to file window beneath header, top-left"
)
check(
  vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(frame), 0, 1, false)[1]:find(vim.fn.nr2char(0x10EEEE), 1, true),
  "Placeholders in file window"
)
local marks = vim.api.nvim_buf_get_extmarks(
  vim.api.nvim_win_get_buf(frame),
  vim.api.nvim_create_namespace("image_tools.canvas"),
  0,
  -1,
  { details = true }
)
local highlight = marks[1][4].hl_group
local foreground = vim.api.nvim_get_hl(0, { name = highlight }).fg
vim.api.nvim_set_hl(0, highlight, {})
vim.api.nvim_exec_autocmds("ColorScheme", { group = "image_tools.buffers" })
check(vim.api.nvim_get_hl(0, { name = highlight }).fg == foreground, "Colorscheme reload restores the image id color")
check(not pcall(vim.cmd, "write!"), "Forced write cannot overwrite original")
check(vim.fn.sha256(table.concat(vim.fn.readfile(png, "b"), "\n")) == original_hash, "Source bytes preserved")
local before_winbar = image.status().buffer.views[win].cache.uploads
local prior_frame = image.status().buffer.views[win].window
vim.cmd("setlocal winbar=ImagePreviewTitle")
check(
  vim.wait(2000, function()
    local current = image.status().buffer.views[win]
    return current and current.window and current.window ~= prior_frame
  end),
  "Winbar change refits file canvas"
)
local bar_frame = image.status().buffer.views[win].window
check(
  vim.api.nvim_win_get_position(bar_frame)[1] + vim.api.nvim_win_get_height(bar_frame)
    <= vim.api.nvim_win_get_position(win)[1] + vim.api.nvim_win_get_height(win),
  "Canvas stops above statusline with winbar enabled"
)
check(image.status().buffer.views[win].cache.uploads == before_winbar, "Winbar refit reuses uploaded image")
vim.cmd("setlocal winbar=")
check(
  vim.wait(2000, function()
    local current = image.status().buffer.views[win]
    return current and current.window and current.window ~= bar_frame
  end),
  "Removing winbar restores available height"
)
vim.cmd.vsplit()
local second = vim.api.nvim_get_current_win()
-- Splitting also resizes the first window; both asynchronous refits must finish.
check(ready({ win, second }), "Same image can preview in both splits")
local status = image.status().buffer
check(status.views[win].window ~= status.views[second].window, "Each split has its own placement")
check(
  status.views[second].cache.uploads == 1 and status.views[second].cache.placements == 2,
  "Two actual Neovim split canvases share one terminal upload"
)
-- Zoom and pan belong to one window and reuse native PNG pixels.
local other_frame = status.views[win].window
check(image.zoom(2) and ready(second), "Zoom current split")
local zoomed = image.status().buffer.views[second]
check(
  zoomed.viewport.zoom == 2 and image.status().buffer.views[win].window == other_frame,
  "Zoom leaves the other split placement untouched"
)
check(
  zoomed.crop.width < zoomed.dimensions.width or zoomed.crop.height < zoomed.dimensions.height,
  "Zoom crops source pixels to the viewport"
)
check(image.pan(10000, 10000) and ready(second), "Pan clamps to the image edge")
local panned = image.status().buffer.views[second]
check(panned.crop.x > 0 or panned.crop.y > 0, "Panning changes the source rectangle")
check(
  panned.crop.x + panned.crop.width <= panned.dimensions.width
    and panned.crop.y + panned.crop.height <= panned.dimensions.height,
  "Crop remains inside source pixels"
)
local placement_command
for _, command in ipairs(writes) do
  if command:find("a=p", 1, true) then
    placement_command = command
  end
end
check(
  placement_command:find(",x=" .. panned.crop.x .. ",", 1, true)
    and placement_command:find(",w=" .. panned.crop.width .. ",", 1, true),
  "Placement protocol carries the selected pixel crop"
)
check(panned.cache.uploads == 1, "PNG zoom and pan reuse the uploaded pixels")
check(not image.zoom(0) and not image.zoom(0 / 0) and not image.pan(math.huge, 0), "Invalid view controls rejected")
check(image.zoom("native") and ready(second), "Native pixel scale")
check(image.zoom("fit") and ready(second), "Restore fit")
local function canvas_color(owner)
  local canvas = image.status().buffer.views[owner].window
  local buf = vim.api.nvim_win_get_buf(canvas)
  local mark = vim.api.nvim_buf_get_extmarks(
    buf,
    vim.api.nvim_create_namespace("image_tools.canvas"),
    0,
    -1,
    { details = true }
  )[1]
  return vim.api.nvim_get_hl(0, { name = mark[4].hl_group })
end
local color_a, color_b = canvas_color(win), canvas_color(second)
check(
  color_a.fg == color_b.fg and color_a.sp ~= color_b.sp,
  "Split highlight colors select independent virtual placements"
)
local before = status.views[second].cache.uploads
vim.api.nvim_win_set_width(second, 20)
vim.api.nvim_exec_autocmds("WinResized", { group = "image_tools.buffers" })
check(
  vim.wait(2000, function()
    local view = image.status().buffer.views[second]
    return view and view.window and vim.api.nvim_win_get_width(view.window) <= 20
  end),
  "Split resize refits the image"
)
check(image.status().buffer.views[second].cache.uploads == before, "Resize retains pixels")
local old_frame = image.status().buffer.views[second].window
vim.cmd.enew()
check(
  vim.wait(500, function()
    return not vim.api.nvim_win_is_valid(old_frame)
  end),
  "Leaving image removes only that split canvas"
)
vim.api.nvim_set_current_win(win)
check(ready(win), "Other split remains visible")
check(image.status().buffer.views[win].cache.placements == 1, "Closing split releases only its placement")
vim.api.nvim_set_current_win(second)
vim.cmd("buffer " .. buf)
check(ready(second), "Returning to hidden file restores preview")
image.setup({ auto_preview = false, cache = tmp .. "/cache" })
check(ready(second), "Repeated setup reconnects loaded image buffers")
check(vim.fn.sha256(table.concat(vim.fn.readfile(png, "b"), "\n")) == original_hash, "Setup does not alter source")
-- Real two-page PDF fixture with distinct colors; prove paging changes pixels.
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.pdf", tmp .. "/pages.pdf")
local pdf = tmp .. "/pages.pdf"
local pdf_hash = vim.fn.sha256(table.concat(vim.fn.readfile(pdf, "b"), "\n"))
check(image.open(pdf), "ImageOpen opens PDF")
check(ready(), "First PDF page rendered: " .. vim.inspect(image.status()))
local pdfbuf = vim.api.nvim_get_current_buf()
check(image.status().buffer.pages == 2 and image.status().buffer.page == 1, "Actual PDF metadata")
local first_path
for _, command in ipairs(writes) do
  local encoded = command:match("t=f;([^\27]+)")
  if encoded then
    first_path = vim.base64.decode(encoded)
  end
end
check(first_path ~= nil, "PDF converted to PNG for upload")
local first_color = vim.system({ "magick", first_path, "-format", "%[pixel:p{10,10}]", "info:" }):wait().stdout
check(first_color:match("255,0,0") or first_color:match("100%%,0%%,0%%"), "First PDF page is red: " .. first_color)
local initial_dimensions = image.status().buffer.views[second].dimensions
check(image.zoom(2) and ready(second), "PDF zoom re-renders")
local detailed = image.status().buffer.views[second].dimensions
check(
  detailed.width > initial_dimensions.width and detailed.height > initial_dimensions.height,
  "PDF zoom increases actual raster resolution"
)
check(image.zoom("fit") and ready(second), "PDF fit restored")
check(image.page(2), "Go to specified page")
check(ready(), "Second PDF page rendered")
local second_path
for _, command in ipairs(writes) do
  local encoded = command:match("t=f;([^\27]+)")
  if encoded then
    second_path = vim.base64.decode(encoded)
  end
end
check(first_path ~= second_path, "Page-specific conversion cache")
local second_color = vim.system({ "magick", second_path, "-format", "%[pixel:p{10,10}]", "info:" }):wait().stdout
check(second_color:match("0,0,255") or second_color:match("0%%,0%%,100%%"), "Second PDF page is blue: " .. second_color)
check(not image.page(3) and not image.page(0), "Page bounds")
local uploads = image.status().buffer.views[second].cache.uploads
check(image.page(1) and ready(), "Back to first page")
check(image.status().buffer.views[second].cache.uploads == uploads, "Previous PDF page reused without upload")
check(vim.api.nvim_buf_get_lines(pdfbuf, 0, 1, false)[1]:find("1 / 2", 1, true), "Visible PDF page indicator")
check(vim.fn.maparg("]p", "n", false, true).buffer == 1, "PDF-local page mapping")
check(
  not pcall(vim.cmd, "write!") and vim.fn.sha256(table.concat(vim.fn.readfile(pdf, "b"), "\n")) == pdf_hash,
  "PDF stays unchanged"
)
-- Pending conversion cannot reappear after switching its source window.
local real_image = require("image_tools.media")
local pending
package.loaded["image_tools.media"] = vim.tbl_extend("force", real_image, {
  prepare = function(_, _, cb)
    pending = cb
    return function() end
  end,
})
image.reload()
check(
  vim.wait(2000, function()
    return pending ~= nil
  end),
  "Pending conversion started"
)
vim.cmd.enew()
vim.wait(50)
local old = #writes
pending(nil, { path = png, width = 160, height = 100, key = "stale" })
check(#writes == old, "Late conversion cannot restore a closed view")
package.loaded["image_tools.media"] = real_image
image.clear_cache()
vim.api.nvim_buf_delete(buf, { force = true })
vim.api.nvim_buf_delete(pdfbuf, { force = true })
-- Automatic mode is optional, and source edits are never discarded by setup/open.
image.setup({ auto_preview = false, buffer = { enabled = false }, cache = tmp .. "/cache" })
local raw = tmp .. "/raw.png"
vim.uv.fs_copyfile(png, raw)
vim.cmd.edit(raw)
check(vim.bo.buftype == "" and not image.status().buffer, "Disabled automatic interception retains native file editing")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved source edits" })
image.setup({ auto_preview = false, cache = tmp .. "/cache" })
check(
  vim.bo.modified and vim.api.nvim_get_current_line() == "unsaved source edits",
  "Setup skips modified source buffers"
)
check(not image.open(raw), "Explicit opening refuses to replace modified source text")
vim.bo.modified = false
vim.cmd.enew()
local terminal = require("image_tools.terminal")
terminal.supports = function()
  return false, "Unsupported test terminal"
end
image.open(png)
check(
  vim.wait(500, function()
    return image.status().buffer and image.status().buffer.error ~= nil
  end),
  "Unsupported terminal produces readable buffer error"
)
check(
  vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == "Unsupported test terminal",
  "Error message appears in source buffer"
)
check(
  not next(image.status().buffer.views) or not image.status().buffer.views[vim.api.nvim_get_current_win()].window,
  "Unsupported terminal has no canvas"
)
print(
  "buffer: " .. count .. " assertions passed, including real PDF metadata, page pixels, splits and source preservation"
)
