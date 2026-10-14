vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_ROOT))
if vim.env.IMAGE_TOOLS_PARSER_ROOT then
  vim.opt.rtp:append(vim.env.IMAGE_TOOLS_PARSER_ROOT)
end
local D = require("image_tools.document")
local TS = require("image_tools.document.treesitter")
local C = require("image_tools.document.syntax_cache")
local tmp = assert(vim.uv.fs_realpath(assert(vim.env.IMAGE_TOOLS_TEST_TMP)))
local opts, checks = { max_scan_lines = 10000 }, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local serial = 0
local function buffer(ft, lines)
  serial = serial + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, tmp .. "/treesitter-" .. serial .. "." .. ft)
  vim.bo[buf].filetype = ft
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end
local function set(buf, lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", tmp .. "/a.png")
vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", tmp .. "/b.png")
local config = require("image_tools.config")
check(config.resolve({}).treesitter == true, "Tree-sitter defaults on")
check(config.resolve({ treesitter = false }).treesitter == false, "Lexer can be selected explicitly")
check(not pcall(config.resolve, { treesitter = "auto" }), "Invalid Tree-sitter option fails validation")

local get_parser, parse_query = vim.treesitter.get_parser, vim.treesitter.query.parse
local fixtures = { tex = [[\includegraphics{a.png}]], typst = [[#image("a.png")]] }
for _, failure in ipairs({ "missing", "nil", "parse", "query" }) do
  for ft, source in pairs(fixtures) do
    vim.treesitter.get_parser = function(...)
      if failure == "missing" then
        error("parser unavailable")
      elseif failure == "nil" then
        return nil
      elseif failure == "parse" then
        return {
          parse = function()
            error("parser failed")
          end,
        }
      end
      return get_parser(...)
    end
    vim.treesitter.query.parse = failure == "query" and function()
      error("incompatible grammar")
    end or parse_query
    check(D.at_line(buffer(ft, { source }), 1, opts) == tmp .. "/a.png", failure .. " falls back for " .. ft)
  end
end
vim.treesitter.get_parser, vim.treesitter.query.parse = get_parser, parse_query

local real = 0
for ft, lang in pairs({ tex = "latex", typst = "typst" }) do
  local available = pcall(vim.treesitter.language.add, lang)
  if available then
    real = real + 1
    local requests = 0
    vim.treesitter.get_parser = function(...)
      requests = requests + 1
      return get_parser(...)
    end
    local buf = buffer(ft, { fixtures[ft] })
    local syntax = TS.query(buf, 1, lang)
    check(syntax and syntax.candidates[1].src == "a.png", "Real " .. lang .. " backend is active")
    local query = C.query
    C.query = function()
      error("Available Tree-sitter must not use the fallback scanner")
    end
    check(D.at_line(buf, 1, opts) == tmp .. "/a.png", "Default route uses real " .. lang)
    check(D.at_cursor(buf, 1, 0, opts) == tmp .. "/a.png", "Cursor includes command/hash in " .. lang)
    check(not D.at_cursor(buf, 1, 500, opts), "Cursor outside reference in " .. lang)
    check(requests == 1, "Unchanged buffer reuses syntax index in " .. lang)
    set(buf, { ft == "tex" and [[\includegraphics{b.png}]] or [[#image("b.png")]] })
    check(D.at_line(buf, 1, opts) == tmp .. "/b.png", "Edit invalidates index in " .. lang)
    check(requests == 2, "Edit refreshes buffer parser in " .. lang)
    local negatives = ft == "tex"
        and {
          { [[% \includegraphics{a.png}]] },
          { [[\verb|\includegraphics{a.png}|]] },
          { [[\begin{verbatim}]], fixtures.tex, [[\end{verbatim}]] },
          { [[\begin{lstlisting}]], fixtures.tex, [[\end{lstlisting}]] },
          { [[\begin{minted}{tex}]], fixtures.tex, [[\end{minted}]] },
          { [[\begin{comment}]], fixtures.tex, [[\end{comment}]] },
          { [[\includegraphics{\macro.png}]] },
          { [[\includegraphics{a.png]] },
          { [[\\includegraphics{a.png}]] },
        }
      or {
        { [[// #image("a.png")]] },
        { [[/* outer /* nested */]], fixtures.typst, [[*/]] },
        { [[```typst]], fixtures.typst, [[```]] },
        { [[`#image("a.png")`]] },
        { [[#let s = "#image(\"a.png\")"]] },
        { [[text image("a.png")]] },
        { [[\#image("a.png")]] },
        { [[#image("a" + ".png")]] },
        { [[#image(path)]] },
        { [[#image("a.png"]] },
        { [[#image("a\q.png")]] },
      }
    for i, lines in ipairs(negatives) do
      set(buf, lines)
      check(not D.at_line(buf, #lines > 1 and 2 or 1, opts), "Authoritative negative " .. lang .. " " .. i)
    end
    if ft == "tex" then
      for _, command in ipairs({ [[\includegraphics*{a.png}]], [[\includegraphics{\detokenize{a.png}}]] }) do
        set(buf, { command })
        check(D.at_line(buf, 1, opts) == tmp .. "/a.png", "Literal compatibility: " .. command)
      end
      vim.fn.mkdir(tmp .. "/plots", "p")
      vim.uv.fs_copyfile(vim.env.IMAGE_TOOLS_ROOT .. "/tests/fixture.png", tmp .. "/plots/only.png")
      set(buf, { [[\graphicspath{{plots/}}]], [[\includegraphics{only}]] })
      check(D.at_line(buf, 2, opts) == tmp .. "/plots/only.png", "Tree-sitter graphicspath and extension lookup")
      set(buf, { [[\verb|\graphicspath{{plots/}}|]], [[\includegraphics{only}]] })
      check(not D.at_line(buf, 2, opts), "Verb graphicspath excluded")
      set(buf, { [[\begin{comment}]], [[\graphicspath{{plots/}}]], [[\end{comment}]], [[\includegraphics{only}]] })
      check(not D.at_line(buf, 4, opts), "Comment graphicspath excluded")
      for _, alias in ipairs({ "latex", "plaintex" }) do
        set(buf, { fixtures.tex })
        vim.bo[buf].filetype = alias
        check(D.at_line(buf, 1, opts) == tmp .. "/a.png", alias .. " uses latex parser")
      end
      vim.bo[buf].filetype = ft
    else
      set(buf, { [[#figure(]], [[image("a.png"),]], [[caption: [test])]] })
      check(D.at_line(buf, 2, opts) == tmp .. "/a.png", "Tree-sitter nested multiline figure")
      set(buf, { [[#image("/a.png")]] })
      check(
        D.at_line(buf, 1, { max_scan_lines = 100, root = tmp .. "/plots" }) == tmp .. "/plots/a.png",
        "Root is not cached"
      )
      check(
        D.at_line(buf, 1, { max_scan_lines = 100, root = tmp }) == tmp .. "/a.png",
        "Changing root is visible without a buffer edit"
      )
      set(buf, { [[#image("图\u{56fe}%20.png")]] })
      check(TS.query(buf, 1, lang).candidates[1].src == "图图%20.png", "Unicode escapes and literal percent")
    end
    set(buf, { fixtures[ft] .. " " .. (ft == "tex" and [[\includegraphics{b.png}]] or [[#image("b.png")]]) })
    check(D.at_line(buf, 1, opts) == tmp .. "/a.png", "Multiple references keep first image in " .. lang)
    check(D.at_cursor(buf, 1, #fixtures[ft] + 2, opts) == tmp .. "/b.png", "Cursor selects second image in " .. lang)
    vim.api.nvim_buf_delete(buf, { force = true })
    C.query = query
    vim.treesitter.get_parser = get_parser
    local unfinished = ft == "tex" and { [[\begin{minted}]], fixtures.tex } or { "```typst", fixtures.typst }
    check(not D.at_line(buffer(ft, unfinished), 2, opts), "Unreliable prefix falls back conservatively in " .. lang)
    local retry = buffer(ft, { fixtures[ft] })
    vim.treesitter.get_parser = function()
      return nil
    end
    check(D.at_line(retry, 1, opts) == tmp .. "/a.png", "Temporary parser absence: " .. lang)
    vim.treesitter.get_parser = get_parser
    check(TS.query(retry, 1, lang) ~= nil, "Parser availability is retried in " .. lang)
    vim.api.nvim_buf_delete(retry, { unload = true })
    vim.fn.bufload(retry)
    set(retry, { ft == "tex" and [[\includegraphics{b.png}]] or [[#image("b.png")]] })
    check(D.at_line(retry, 1, opts) == tmp .. "/b.png", "Unload/reload recreates Tree-sitter index in " .. lang)
    vim.api.nvim_buf_delete(retry, { force = true })
  else
    print("treesitter: real " .. lang .. " parser unavailable; install it or set IMAGE_TOOLS_PARSER_ROOT")
  end
end
-- Explicit disabling must not even attempt parser initialization.
vim.treesitter.get_parser = function()
  error("Tree-sitter is disabled")
end
for ft, source in pairs(fixtures) do
  check(
    D.at_line(buffer(ft, { source }), 1, { max_scan_lines = 100, treesitter = false }) == tmp .. "/a.png",
    "Explicit lexer: " .. ft
  )
end
vim.treesitter.get_parser = get_parser
print("treesitter: " .. checks .. " assertions passed; " .. real .. " real language parsers exercised")
