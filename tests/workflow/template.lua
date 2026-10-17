vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local I = require("image_tools.workflow.insert")
local config = require("image_tools.config")
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ actual = a, expected = b }))
end
local text, offset = I.markup("Figures/My Plot.PNG", "caption", "tex", {
  template = {
    tex = [[
    \begin{figure}[H]
      \includegraphics[width=0.5\linewidth]{$FILE_PATH}
      \caption{$ALT$CURSOR}
      \label{custom:$LABEL}
    \end{figure}
  ]],
  },
})
eq(
  text,
  table.concat({
    "\\begin{figure}[H]",
    [[  \includegraphics[width=0.5\linewidth]{Figures/My Plot.PNG}]],
    [[  \caption{caption}]],
    [[  \label{custom:my-plot}]],
    [[\end{figure}]],
  }, "\n")
)
eq(text:sub(offset + 1, offset + 1), "}")
eq(I.markup("a.png", nil, "latex", { template = { tex = "$FILE_NAME" } }), "a.png")
eq(I.markup("a.png", nil, "markdown", { template = { tex = "ignored" } }), I.markup("a.png", nil, "markdown"))
text, offset = I.markup("100% $CURSOR.png", "$ALT", "markdown", { template = "$FILE_NAME|$ALT|$CURSOR" })
eq(text, "100% $CURSOR.png|$ALT|")
eq(offset, #text)
text, offset = I.markup("a.png", nil, "markdown", {
  template = function(ctx)
    eq(ctx.file_name_no_ext, "a")
    return "before " .. ctx.cursor .. ctx.file_path
  end,
})
eq(text, "before a.png")
eq(offset, #"before ")
eq(pcall(I.markup, "a.png", nil, "markdown", { template = "$CURSOR $CURSOR" }), false)
eq(pcall(config.resolve, { insert = { template = { tex = 42 } } }), false)

-- A failed user renderer must roll back copied assets as well as text.
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/template"
vim.fn.mkdir(tmp, "p")
vim.api.nvim_buf_set_name(0, tmp .. "/note.md")
vim.bo.filetype = "markdown"
local done, failure
I.files({ vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png" }, {
  template = function(ctx)
    eq(ctx.document, tmp .. "/note.md")
    error("renderer failed")
  end,
}, function(err)
  failure, done = err, true
end)
assert(vim.wait(2000, function()
  return done
end))
assert(failure:find("renderer failed", 1, true))
eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "" })
eq(vim.fn.glob(tmp .. "/Figures/*", false, true), {})
print("templates: expansion, aliases, functions, cursor offsets and rollback passed")
