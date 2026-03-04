-- lib/ui.lua — ANSI colour helpers and common UI primitives
local M = {}

local ESC = string.char(27)
local function a(code) return ESC.."["..code.."m" end

M.RST  = a("0");  M.BOL = a("1")
M.RED  = a("31"); M.GRN = a("32"); M.YEL = a("33")
M.BLU  = a("34"); M.MAG = a("35"); M.CYN = a("36"); M.WHT = a("37")
M.BRED = M.BOL..M.RED;  M.BGRN = M.BOL..M.GRN
M.BYEL = M.BOL..M.YEL;  M.BCYN = M.BOL..M.CYN
M.BMAG = M.BOL..M.MAG;  M.BWHT = M.BOL..M.WHT

function M.W(s)   door.write(s)         end
function M.WL(s)  door.writeln(s or "") end
function M.CLS()  door.clear()          end
function M.KEY()  return door.read_key() end
function M.INPUT(prompt)
    M.W(prompt)
    return door.read_line()
end

function M.pause()
    M.WL(M.CYN.."\r\n  [ press any key ]"..M.RST)
    M.KEY()
end

function M.divider()
    M.WL(M.CYN..string.rep("-", 60)..M.RST)
end

function M.header(title)
    M.WL("")
    M.WL(M.BCYN..string.rep("=", 60)..M.RST)
    M.WL(M.BCYN.."  "..title..M.RST)
    M.WL(M.BCYN..string.rep("=", 60)..M.RST)
    M.WL("")
end

-- Simple bar graph: val/max, width w, colours based on fill ratio
function M.bar(val, max, w)
    w = w or 20
    local fill = math.max(0, math.floor(val / math.max(1, max) * w))
    local col = fill > w * 0.5 and M.GRN
             or fill > w * 0.25 and M.YEL
             or M.BRED
    return "["..col..string.rep("#", fill)..M.RST..string.rep(".", w - fill).."]"
end

-- Comma-format large numbers
function M.commas(n)
    local s = tostring(math.floor(n))
    return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

-- Centred text in a field of width w
function M.centre(s, w)
    local pad = math.max(0, w - #s)
    return string.rep(" ", math.floor(pad/2))..s..string.rep(" ", math.ceil(pad/2))
end

-- Pager: show long text one screen at a time
function M.pager(text)
    local lines = {}
    for ln in (text.."\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, ln)
    end
    local rows = 22
    local i = 1
    while i <= #lines do
        for j = i, math.min(i + rows - 1, #lines) do
            M.WL(lines[j])
        end
        i = i + rows
        if i <= #lines then
            M.W(M.CYN.."-- more -- (any key) --"..M.RST)
            M.KEY()
            M.WL("")
        end
    end
end

return M
