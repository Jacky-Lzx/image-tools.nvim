vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
local D, I = require("image_tools.document"), require("image_tools.workflow.insert")
local tmp = assert(vim.uv.fs_realpath(vim.env.IMAGE_TOOLS_TEST_TMP)) .. "/html"
vim.fn.mkdir(tmp, "p")
local source = tmp .. "/a & 图.png"
assert(vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixtures/fixture.png", source))
local serial = 0
local function buffer(lines)
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, tmp .. "/note-" .. serial .. ".html")
  vim.bo.filetype = "html"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ actual = a, expected = b }))
end
local markup, offset = I.markup("a & 图.png", 'A "quote" & <tag>', "html")
eq(markup, '<img src="a%20%26%20%E5%9B%BE.png" alt="A &quot;quote&quot; &amp; &lt;tag&gt;" />')
eq(markup:sub(offset + 1, offset + 1), "A")
local buf = buffer({ markup })
local opts = { max_scan_lines = 100 }
eq(D.at_line(buf, 1, opts), source)
eq(D.at_cursor(buf, 1, offset, opts), source)
local _, _, status = D.at_cursor(buf, 1, #markup, opts)
eq(status, "miss")
buf = buffer({ '<IMG title="a > b" src=second.png> <img src="a&#32;&amp;&#x20;图.png">' })
eq(D.at_line(buf, 1, opts), tmp .. "/second.png")
eq(D.at_cursor(buf, 1, 45, opts), source)
eq(#D.adapter("html").references(buf, 1, opts), 2)
buf = buffer({ "<!--", '<img src="a%20%26%20图.png">', "-->", '<img src="a%20%26%20图.png">' })
eq(D.at_line(buf, 2, opts), nil)
eq(D.at_line(buf, 4, opts), source)
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "" })
eq(D.at_line(buf, 2, opts), source)
for _, tag in ipairs({ "script", "style", "pre", "code" }) do
  buf = buffer({ "<" .. tag .. ">", '<img src="hidden.png">', "</" .. tag .. "><img src='second.png'>" })
  eq(D.at_line(buf, 2, opts), nil)
  eq(D.at_line(buf, 3, opts), tmp .. "/second.png")
end
for _, line in ipairs({
  '<img :src="value">',
  '<img src="{{value}}">',
  '<img srcset="a.png 1x">',
  '<image src="a.png">',
}) do
  buf = buffer({ line })
  eq(D.at_line(buf, 1, opts), nil)
end
buf = buffer({ '<img src="https://example.invalid/image.png">' })
local path, err = D.at_line(buf, 1, opts)
eq(path, nil)
assert(err:find("Remote", 1, true))
buf = buffer({ "before" })
local done, failure, outputs
I.files({ source }, { alt = "description" }, function(e, p)
  failure, outputs, done = e, p, true
end)
assert(vim.wait(2000, function()
  return done
end))
assert(not failure, failure)
eq(D.at_line(buf, 2, opts), outputs[1])
eq(I.supported("html", "a.pdf"), false)
print("HTML: escaped insertion, entities, byte ranges, exclusions, cache edits and import round trips passed")
