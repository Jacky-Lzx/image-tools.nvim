-- Download the selected HTTPS reference, publish original bytes transactionally,
-- and replace only its destination. No new image markup is inserted.
local M = {}

function M.run(opts, callback)
  local I = require("image_tools.workflow.insert")
  local context = I.capture(opts)
  local buf = context.buf
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local done, cancel_fetch, cancel_import = false, nil, nil
  local function finish(err, outputs)
    if done then
      return
    end
    done = true
    if cancel_fetch then
      cancel_fetch()
    end
    I.release(context)
    if callback then
      callback(err, outputs)
    elseif err ~= "Cancelled" then
      vim.notify(
        err or ("Localized image: " .. outputs[1]),
        err and vim.log.levels.ERROR or vim.log.levels.INFO,
        { title = "image-tools" }
      )
    end
  end
  local function cancel()
    if done then
      return
    end
    if cancel_import then
      cancel_import()
    end
    finish("Cancelled")
  end
  local options = vim.tbl_deep_extend("force", opts, { treesitter = false, remote = { enabled = true } })
  local cursor = opts.cursor or vim.api.nvim_win_get_cursor(0)
  local document = require("image_tools.document")
  local url, err, status, ref = document.at_cursor(buf, cursor[1], cursor[2], options)
  if not url and status == "miss" then
    url, err, status, ref = document.at_line(buf, cursor[1], options)
  end
  if not url or not url:match("^https://") then
    finish(err or "Select an HTTPS image reference to localize")
    return cancel
  end
  cancel_fetch = require("image_tools.media.remote").fetch(url, options, function(download_err, path)
    if done then
      return
    end
    if download_err then
      finish(download_err)
      return
    end
    if not vim.api.nvim_buf_is_loaded(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
      finish("Document changed during image download; retry localization")
      return
    end
    local extension = require("image_tools.media.formats").extension(path)
    local name = vim.fs.basename(url:match("^[^?#]+")):gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
    name = name:gsub("[/\\%c]", "_")
    name = vim.fn.fnamemodify(name, ":r")
    if name == "" or name == "." or name == ".." then
      name = "image"
    end
    local insertion = vim.tbl_extend("force", opts.insert or {}, {
      context = context,
      mode = "copy",
      process = false,
      filename = name .. "." .. extension,
      max_bytes = opts.max_bytes,
      reference_root = opts.root,
      _commit = function(_, outputs)
        assert(vim.api.nvim_buf_get_changedtick(buf) == tick, "Document changed during localization")
        local edit =
          require("image_tools.document.edit").path(buf, context.filetype, ref, outputs[1], context.document, options)
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("let &g:undolevels = &g:undolevels")
        end)
        vim.api.nvim_buf_set_text(buf, edit.row - 1, edit.first, edit.row - 1, edit.last, { edit.text })
      end,
    }, opts.filename and { filename = opts.filename } or {})
    cancel_import = I.files({ path }, insertion, finish)
  end)
  return cancel
end

return M
