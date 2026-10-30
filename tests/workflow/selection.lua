vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local selection = vim.env.IMAGE_TOOLS_SELECTION_ROOT
if not selection or not vim.uv.fs_stat(selection .. "/lua/selection_tools/init.lua") then
  print("selection picker: skipped (set IMAGE_TOOLS_SELECTION_ROOT)")
  return
end
vim.opt.rtp:prepend(selection)
vim.o.columns, vim.o.lines = 180, 80
local requests, pending = {}, {}
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(command)
    requests[#requests + 1] = command
  end,
  request = function(_, command, _, callback)
    requests[#requests + 1] = command
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
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local tmp = vim.env.IMAGE_TOOLS_TEST_TMP .. "/selection"
vim.fn.mkdir(tmp .. "/images", "p")
local source = vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png"
local function copy(to)
  vim.fn.writefile(vim.fn.readfile(source, "b"), to, "b")
end
copy(tmp .. "/images/a | %.PnG")
copy(tmp .. "/images/b.png")
vim.fn.writefile({ "not an image" }, tmp .. "/images/ignore.txt")
local origin = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, tmp .. "/note.md")
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "source" })
local image = require("image_tools")
image.setup({ auto_preview = false })
local function ready(p)
  check(
    vim.wait(5000, function()
      return not p.loading and p.preview.provider and p.preview.provider.id
    end, 2),
    "Picker loads real selection-tools files and acknowledged image preview"
  )
end
local done, err, paths, calls = false, nil, nil, 0
local function result(e, p)
  calls = calls + 1
  done, err, paths = true, e, p
end
local picker = image.pick({ insert = { mode = "reference" }, picker = { cwd = tmp .. "/images" } }, result)
check(
  picker and picker.opts.source == "files" and not picker.opts.resume,
  "Selection files picker with single-use context"
)
ready(picker)
check(#picker.matches == 2, "Formats exclude text and preserve mixed-case image extensions")
local view = picker.preview.provider
check(view.buf == picker.preview_buf and view.win == picker.preview_win, "Public render API borrows the selection pane")
check(
  vim.api.nvim_buf_get_lines(view.buf, 0, 1, false)[1]:find(vim.fn.nr2char(0x10EEEE), 1, true) == 1,
  "Top-left image grid"
)
local id = view.id
picker:expand_preview()
check(
  vim.wait(1000, function()
    return view.session and view.session.stage == "ready"
  end, 2),
  "Preview expands"
)
check(view.id == id and view.transfer:status().uploads == 1, "Resize reuses shared pixels")
picker:toggle()
picker:move(1)
ready(picker)
picker:toggle()
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "before source" })
picker:confirm()
check(
  vim.wait(3000, function()
    return done
  end, 2),
  "Multi-confirm completes insertion"
)
check(not err and #paths == 2 and calls == 1, tostring(err))
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check(
  lines[3]:find("PnG", 1, true) and lines[4]:find("b.png", 1, true),
  "References follow source extmark and selection order"
)
check(view.closed and image.status().terminal_cache.placements == 0, "Confirm releases only chooser placements")
check(
  vim.api.nvim_get_current_win() == origin and vim.api.nvim_get_current_buf() == buf,
  "Insertion returns to source document"
)
-- Copy an external file, then select the resulting asset without making duplicates.
done, err, paths = false, nil, nil
picker = image.pick({ picker = { cwd = tmp .. "/images", ft = "png" } }, result)
ready(picker)
picker:confirm()
check(vim.wait(3000, function()
  return done
end, 2) and not err, "Copy import completes")
local imported = paths[1]
done, err, paths = false, nil, nil
picker = image.pick({ picker = { cwd = tmp .. "/Figures", ft = { "png" } } }, result)
ready(picker)
picker:confirm()
check(
  vim.wait(3000, function()
    return done
  end, 2),
  "Existing asset import completes"
)
check(not err and vim.uv.fs_realpath(paths[1]) == vim.uv.fs_realpath(imported), "Already imported asset reused")
check(#vim.fn.readdir(tmp .. "/Figures") == 1, "No duplicate asset created")
-- Processing offers convertible input even for a restrictive LaTeX adapter.
vim.fn.mkdir(tmp .. "/downloads", "p")
check(vim.system({ "magick", source, tmp .. "/downloads/input.webp" }):wait().code == 0, "Prepare WebP")
local tex = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(tex)
vim.api.nvim_buf_set_name(tex, tmp .. "/paper.tex")
vim.bo[tex].filetype = "tex"
done, err, paths = false, nil, nil
picker = image.pick(
  { insert = { process = { format = "png", resize = "40x40>" } }, picker = { cwd = tmp .. "/downloads" } },
  result
)
ready(picker)
check(picker:current().file:match("%.webp$"), "Processing widens source format filter")
picker.opts.actions.confirm(picker)
check(vim.wait(5000, function()
  return done
end, 2) and not err, tostring(err))
check(vim.fs.basename(paths[1]) == "input.png", "Processed output retains document-compatible format")
check(
  vim.system({ "magick", "identify", "-format", "%m %wx%h", paths[1] }):wait().stdout == "PNG 40x25",
  "Real conversion preserves pipeline"
)
vim.api.nvim_set_current_buf(buf)
-- A filtered-out pending image cannot upload late; cancellation releases the mark once.
local media = package.loaded["image_tools.media"]
package.loaded["image_tools.media"] = {
  prepare = function(_, _, callback)
    pending[#pending + 1] = callback
    return function() end
  end,
}
local insertion = require("image_tools.workflow.insert")
local context = insertion.capture()
local cancelled, cancel_calls = nil, 0
picker = image.pick({ insert = { context = context }, picker = { cwd = tmp .. "/images", ft = { "png" } } }, function(e)
  cancelled = e
  cancel_calls = cancel_calls + 1
end)
check(
  vim.wait(1000, function()
    return #pending > 0
  end, 2),
  "Slow preparation starts"
)
view = picker.preview.provider
picker:set_query("no matching image")
local before = #requests
pending[#pending](nil, { path = source, width = 160, height = 100, key = "late", size = 100 })
check(view.closed and #requests == before, "Stale image never uploads after filtering")
picker:close()
picker:close()
check(
  cancelled == "Cancelled" and cancel_calls == 1 and context.mark == nil,
  "Cancellation releases source context once"
)
package.loaded["image_tools.media"] = media
-- Failed construction/dependency lookup also releases insertion authority.
context = insertion.capture()
local old, preload = package.loaded.selection_tools, package.preload.selection_tools
package.loaded.selection_tools = nil
package.preload.selection_tools = function()
  error("missing picker")
end
local fail_error
local failed = image.pick({ insert = { context = context } }, function(e)
  fail_error = e
end)
package.loaded.selection_tools, package.preload.selection_tools = old, preload
check(
  failed == nil and context.mark == nil and fail_error:find("selection-tools", 1, true),
  "Missing dependency does not leak the capture"
)
check(not package.loaded.snacks and not package.loaded["snacks.image"], "Image chooser does not load Snacks")
print(("selection picker: %d assertions with real selection-tools windows passed"):format(count))
