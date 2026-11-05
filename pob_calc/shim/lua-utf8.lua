-- Minimal pure-Lua stand-in for the luautf8 C module, enough for headless PoB.
-- PoB only uses find/gsub/match/next/reverse/sub, mostly on ASCII text.
local M = {}
M.find, M.gsub, M.match, M.gmatch, M.byte = string.find, string.gsub, string.match, string.gmatch, string.byte
M.charpattern = "[%z\1-\127\194-\244][\128-\191]*"
local function chars(s)
	local t = {}
	for c in s:gmatch(M.charpattern) do t[#t+1] = c end
	return t
end
function M.len(s) return #chars(s) end
function M.reverse(s)
	local t = chars(s)
	local o = {}
	for i = #t, 1, -1 do o[#o+1] = t[i] end
	return table.concat(o)
end
function M.sub(s, i, j)
	local t = chars(s)
	local n = #t
	i = i or 1; j = j or -1
	if i < 0 then i = n + i + 1 end
	if j < 0 then j = n + j + 1 end
	if i < 1 then i = 1 end
	if j > n then j = n end
	if i > j then return "" end
	return table.concat(t, "", i, j)
end
-- next(s, bytePos, step): byte offset of the next/previous character start
function M.next(s, pos, step)
	step = step or 1
	pos = pos or 0
	local n = #s
	local p = pos
	repeat
		p = p + (step >= 0 and 1 or -1)
		if p < 1 or p > n then return nil end
		local b = s:byte(p)
	until b < 0x80 or b >= 0xC0
	return p
end
function M.char(...)
	local o = {}
	for _, cp in ipairs({...}) do
		if cp < 0x80 then o[#o+1] = string.char(cp)
		elseif cp < 0x800 then o[#o+1] = string.char(0xC0 + math.floor(cp/0x40), 0x80 + cp%0x40)
		elseif cp < 0x10000 then o[#o+1] = string.char(0xE0 + math.floor(cp/0x1000), 0x80 + math.floor(cp/0x40)%0x40, 0x80 + cp%0x40)
		else o[#o+1] = string.char(0xF0 + math.floor(cp/0x40000), 0x80 + math.floor(cp/0x1000)%0x40, 0x80 + math.floor(cp/0x40)%0x40, 0x80 + cp%0x40) end
	end
	return table.concat(o)
end
return M
