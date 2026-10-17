-- Run through Neovim's main event loop (-c luafile, not -l), so startinsert
-- actually takes effect and queued typing exercises the insertion position.
vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local I = require("image_tools.workflow.insert")
require("image_tools").register_adapter("org", {
  image_formats = { "png", "jpg" },
  markup = "[[file:$FILE_PATH]]$CURSOR",
})
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/insert-mode"
vim.fn.mkdir(tmp, "p")
local fixture = tmp .. "/fixture.png"
assert(vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", fixture))
local pngpaste = tmp .. "/pngpaste"
vim.fn.writefile({ "#!/bin/sh", 'cp "$IMAGE_TOOLS_ROOT/tests/fixtures/fixture.png" "$1"' }, pngpaste)
assert(vim.uv.fs_chmod(pngpaste, 493))

local cases = {}
for _, strategy in ipairs({ "insert_before", "insert_after", "insert_line_before", "insert_line_after" }) do
  cases[#cases + 1] = { strategy = strategy }
end
cases[#cases + 1] = { alt = "原有]描述", start_insert = true }
cases[#cases + 1] = { paste = true }
cases[#cases + 1] = { template = "Image: $FILE_PATH\nCaption: $CURSOR\nEnd" }
for _, filetype in ipairs({ "tex", "latex", "plaintex", "typst", "html", "org" }) do
  for _, strategy in ipairs({ "insert_before", "insert_after", "insert_line_before", "insert_line_after" }) do
    cases[#cases + 1] = { filetype = filetype, strategy = strategy }
  end
  cases[#cases + 1] = { filetype = filetype, paste = true }
end
cases[#cases + 1] = { switch_window = true }
cases[#cases + 1] = { fail = true }

local index, assertions = 0, 0
local function check(value, message)
  assertions = assertions + 1
  assert(value, "case " .. index .. ": " .. message)
end
local function guarded(fn)
  return function(...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then
      io.stderr:write(err .. "\n")
      vim.cmd("cquit 1")
    end
  end
end

local next_case
next_case = guarded(function()
  index = index + 1
  local case = cases[index]
  if not case then
    print("insert mode: " .. assertions .. " assertions passed")
    vim.cmd("qa!")
    return
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/note-" .. index .. ".txt")
  local ft = case.filetype or "markdown"
  vim.bo.filetype = ft
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "你尾" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local strategy = case.strategy or "insert_line_after"
  local opts = { mode = "reference", insert_strategy = strategy, alt = case.alt, template = case.template }
  local extension = (ft == "markdown" or ft == "html") and "avif" or "png"
  local paste_path = "paste-" .. index .. "/image." .. extension
  local snippet = I.markup(case.paste and paste_path or I.relative(fixture, tmp), case.alt, ft)
  local row = strategy == "insert_line_after" and 2 or 1
  local prefix = strategy == "insert_after" and "你" or ""
  local col = #prefix + (ft == "markdown" and 2 or #snippet)
  local tex = ft == "tex" or ft == "latex" or ft == "plaintex"
  if tex then
    row, col = row + 3, #"  \\caption{"
  end
  if ft == "html" then
    col = #prefix + #assert(snippet:match('^(.-alt=")'))
  end
  if case.template then
    row, col = row + 1, #"Caption: "
  end
  local other_win
  local function execute()
    local callback = guarded(function(err)
      if case.fail or case.switch_window then
        check((err ~= nil) == (case.fail == true), "expected completion result")
        check(vim.api.nvim_get_mode().mode == "n", "completion preserves Normal mode")
        check(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 0 }), "completion preserves cursor")
        if other_win then
          check(vim.api.nvim_get_current_win() == other_win, "completion preserves window focus")
          vim.api.nvim_win_close(other_win, true)
        end
        vim.defer_fn(next_case, 10)
        return
      end
      check(not err, err or "import succeeds")
      -- startinsert takes effect after the completion callback returns.
      vim.defer_fn(
        guarded(function()
          check(vim.api.nvim_get_mode().mode == "i", "completion enters Insert mode")
          check(
            vim.deep_equal(vim.api.nvim_win_get_cursor(0), { row, col }),
            "editing byte position: "
              .. vim.inspect({ actual = vim.api.nvim_win_get_cursor(0), expected = { row, col } })
          )
          local before = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
          if tex then
            check(before == "  \\caption{}", "LaTeX editing target is the empty caption")
          end
          vim.api.nvim_input("here")
          vim.defer_fn(
            guarded(function()
              local after = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
              check(after == before:sub(1, col) .. "here" .. before:sub(col + 1), "typing edits the intended field")
              vim.cmd("stopinsert")
              vim.defer_fn(next_case, 10)
            end),
            10
          )
        end),
        10
      )
    end)
    if case.paste then
      opts.pngpaste, opts.filename, opts.directory = pngpaste, "image." .. extension, "paste-" .. index
      require("image_tools.workflow.clipboard").paste(opts, callback, { macos = true })
    else
      I.files({ case.fail and tmp .. "/missing.png" or fixture }, opts, callback)
    end
    if case.switch_window then
      -- Even another window on the same buffer must keep its own cursor/mode.
      vim.cmd("split")
      other_win = vim.api.nvim_get_current_win()
    end
  end
  if case.start_insert then
    vim.cmd("startinsert")
    vim.defer_fn(guarded(execute), 10)
  else
    execute()
  end
end)
vim.defer_fn(function()
  io.stderr:write("insert mode: timed out\n")
  vim.cmd("cquit 1")
end, 10000)
vim.schedule(next_case)
