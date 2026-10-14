-- Module: image_tools.terminal.protocol
--
-- Purpose:
--   Encode Kitty graphics commands, Unicode placeholder coordinates and
--   highlights.
--
-- Architecture:
--   Build file/direct uploads, virtual placements, hide/delete commands and
--   placeholder grids for terminal services and renderers. Foreground selects
--   the image id; underline color selects placement.
--
-- Ownership:
--   Keep static coordinate data only. Perform no terminal writes and allocate
--   no image/placement ids; callers own transmission and resource lifecycle.

local M = {}
local esc = "\27"

-- Row/column values from the Kitty graphics protocol specification:
-- https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders
-- Explicit row AND column diacritics keep clipping/overlapping windows correct.
local values =
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244"
local diacritics = {}
for value in values:gmatch("[^,]+") do
  diacritics[#diacritics + 1] = vim.fn.nr2char(tonumber(value, 16))
end
M.max_cells = #diacritics

-- Serialize deterministically ordered fields into one Kitty APC graphics command.
---@param fields table<string, string|number|nil> Protocol fields.
---@param payload? string Already encoded payload, if needed.
---@return string command
function M.command(fields, payload)
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. tostring(fields[key])
  end
  return esc .. "_G" .. table.concat(parts, ",") .. (payload and ";" .. payload or "") .. esc .. "\\"
end

-- Encode PNG bytes into direct-transmission chunks with an id only on the first chunk.
---@param id integer Allocated image id.
---@param png string Complete PNG bytes.
---@param quiet? integer Kitty q policy; defaults to 2.
---@return string commands Concatenated APC upload chunks.
function M.upload(id, png, quiet)
  local data = vim.base64.encode(png)
  local commands = {}
  for offset = 1, #data, 4096 do
    local fields = { m = offset + 4096 > #data and 0 or 1, q = quiet == nil and 2 or quiet }
    if offset == 1 then
      fields.a, fields.f, fields.t, fields.i = "t", 100, "d", id
    end
    commands[#commands + 1] = M.command(fields, data:sub(offset, offset + 4095))
  end
  return table.concat(commands)
end

-- Encode only an absolute PNG filename and request its upload acknowledgement.
---@param id integer Allocated image id.
---@param path string Absolute filename readable by the terminal.
---@return string command
function M.upload_file(id, path)
  return M.command({ a = "t", f = 100, t = "f", i = id, q = 0 }, vim.base64.encode(path))
end

-- Create a virtual Unicode-placeholder placement without transmitting pixels again.
---@param id integer Uploaded image id.
---@param width integer Terminal columns.
---@param height integer Terminal rows.
---@param quiet? integer q policy; defaults to 2.
---@param placement? integer Independent placement id.
---@return string command
function M.place(id, width, height, quiet, placement)
  return M.command({ a = "p", U = 1, i = id, p = placement, c = width, r = height, q = quiet == nil and 2 or quiet })
end

-- Hide one placement (or placements for an image) while retaining uploaded pixels.
---@param id integer Uploaded image id.
---@param placement? integer Optional placement selector.
---@return string command
function M.hide(id, placement)
  return M.command({ a = "d", d = "i", i = id, p = placement, q = 2 })
end

-- Free one plugin-owned image and all of its terminal placements.
---@param id integer Image to release.
---@return string command
function M.delete(id)
  return M.command({ a = "d", d = "I", i = id, q = 2 })
end

-- Kitty selects a virtual placement from the underline color (Neovim sp).
-- Neovim's TUI emits sp only with an underline attribute enabled:
-- https://github.com/neovim/neovim/blob/v0.12.6/src/nvim/tui/tui.c
-- Encode the image id as foreground RGB and placement id as underline RGB with underline enabled.
---@param id integer Nonzero 24-bit image id.
---@param placement? integer Optional nonzero 24-bit placement id.
---@return table highlight Neovim highlight attributes.
function M.highlight(id, placement)
  return {
    fg = string.format("#%06x", id),
    sp = placement and string.format("#%06x", placement) or nil,
    nocombine = true,
    underline = placement ~= nil,
  }
end

-- Build placeholder rows with explicit row/column diacritics for correct clipping.
---@param width integer Positive columns within max_cells.
---@param height integer Positive rows within max_cells.
---@return string[] lines
function M.grid(width, height)
  assert(width >= 1 and width <= M.max_cells and height >= 1 and height <= M.max_cells)
  local lines, placeholder = {}, vim.fn.nr2char(0x10EEEE)
  for row = 1, height do
    local cells = {}
    for col = 1, width do
      cells[col] = placeholder .. diacritics[row] .. diacritics[col]
    end
    lines[row] = table.concat(cells)
  end
  return lines
end

return M
