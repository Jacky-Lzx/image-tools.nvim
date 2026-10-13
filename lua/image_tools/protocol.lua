local M = {}
local esc = "\27"

-- First 64 row/column values from the Kitty graphics protocol specification:
-- https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders
-- Explicit row AND column diacritics keep clipping/overlapping windows correct.
local values =
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658"
local diacritics = {}
for value in values:gmatch("[^,]+") do
  diacritics[#diacritics + 1] = vim.fn.nr2char(tonumber(value, 16))
end
M.max_cells = #diacritics

function M.command(fields, payload)
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. tostring(fields[key])
  end
  return esc .. "_G" .. table.concat(parts, ",") .. (payload and ";" .. payload or "") .. esc .. "\\"
end

function M.upload(id, png)
  local data = vim.base64.encode(png)
  local commands = {}
  for offset = 1, #data, 4096 do
    local fields = { m = offset + 4096 > #data and 0 or 1, q = 2 }
    if offset == 1 then
      fields.a, fields.f, fields.t, fields.i = "t", 100, "d", id
    end
    commands[#commands + 1] = M.command(fields, data:sub(offset, offset + 4095))
  end
  return table.concat(commands)
end

function M.place(id, width, height)
  return M.command({ a = "p", U = 1, i = id, c = width, r = height, q = 2 })
end

function M.delete(id)
  return M.command({ a = "d", d = "I", i = id, q = 2 })
end

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
