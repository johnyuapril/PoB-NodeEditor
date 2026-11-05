-- pob_calc driver: runs Path of Building (PoE2) headless and answers one JSON request.
-- Usage (cwd must be <PathOfBuilding-PoE2>/src):
--   luajit <this>/driver.lua <request.json> <response.json>
-- See README.md next to this file for the request format.

local reqPath, outPath = arg[1], arg[2]
local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here .. "/shim/?.lua;../runtime/lua/?.lua;../runtime/lua/?/init.lua;" .. package.path

local realPrint = print
local logLines = {}
local quiet = os.getenv("POB_CALC_VERBOSE") == nil

-- Boot PoB (HeadlessWrapper defines SimpleGraphic stubs, loads Launch.lua, inits Main)
if quiet then print = function(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring(select(i, ...)) end logLines[#logLines+1] = table.concat(t, "\t") end end
dofile("HeadlessWrapper.lua")
ConPrintf = function(fmt, ...) local ok, s = pcall(string.format, fmt, ...) logLines[#logLines+1] = ok and s or fmt end

-- Real zlib through FFI, so build codes and compressed data work headless
do
	local ok, ffi = pcall(require, "ffi")
	local zok, z = false, nil
	if ok then
		ffi.cdef[[
		typedef struct z_stream_s {
			const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
			unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
			const char *msg; void *state; void *zalloc; void *zfree; void *opaque;
			int data_type; unsigned long adler; unsigned long reserved;
		} z_stream;
		int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
		int inflate(z_stream *strm, int flush);
		int inflateEnd(z_stream *strm);
		int deflateInit2_(z_stream *strm, int level, int method, int windowBits, int memLevel, int strategy, const char *version, int stream_size);
		int deflate(z_stream *strm, int flush);
		int deflateEnd(z_stream *strm);
		const char *zlibVersion(void);
		]]
		zok, z = pcall(ffi.load, "z")
		if not zok then zok, z = pcall(ffi.load, "libz.so.1") end
	end
	if zok then
		local function run(data, init, step, finish)
			local strm = ffi.new("z_stream[1]")
			if init(strm) ~= 0 then return nil, "zlib init failed" end
			local inbuf = ffi.new("unsigned char[?]", #data + 1)
			ffi.copy(inbuf, data, #data)
			strm[0].next_in = inbuf
			strm[0].avail_in = #data
			local chunk = 65536
			local out = ffi.new("unsigned char[?]", chunk)
			local parts = {}
			while true do
				strm[0].next_out = out
				strm[0].avail_out = chunk
				local ret = step(strm)
				parts[#parts+1] = ffi.string(out, chunk - strm[0].avail_out)
				if ret == 1 then break end -- Z_STREAM_END
				if ret ~= 0 and ret ~= -5 then finish(strm) return nil, "zlib error " .. ret end
				if ret == -5 and strm[0].avail_in == 0 and strm[0].avail_out ~= 0 then break end
			end
			finish(strm)
			return table.concat(parts)
		end
		function Inflate(data)
			return run(data,
				function(s) return z.inflateInit2_(s, 15 + 32, z.zlibVersion(), ffi.sizeof("z_stream")) end,
				function(s) return z.inflate(s, 0) end,
				function(s) z.inflateEnd(s) end)
		end
		function Deflate(data, isGzip)
			return run(data,
				function(s) return z.deflateInit2_(s, 9, 8, isGzip and 31 or 15, 8, 0, z.zlibVersion(), ffi.sizeof("z_stream")) end,
				function(s) return z.deflate(s, 4) end, -- Z_FINISH
				function(s) z.deflateEnd(s) end)
		end
	end
end

local dkjson = require("dkjson")

local function readFile(p) local f = assert(io.open(p, "rb")) local s = f:read("*a") f:close() return s end
local function writeFile(p, s) local f = assert(io.open(p, "wb")) f:write(s) f:close() end

local req = {}
local warnings = {}
local function warn(msg) warnings[#warnings+1] = msg end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function recalc()
	build.buildFlag = true
	build.modFlag = true
	runCallback("OnFrame")
	build.calcsTab:BuildOutput()
	runCallback("OnFrame")
end

local function lc(s) return tostring(s):lower() end

local function findNode(ref)
	local spec = build.spec
	if type(ref) == "number" or (type(ref) == "string" and ref:match("^%d+$")) then
		return spec.nodes[tonumber(ref)]
	end
	local want = lc(ref)
	local best
	for _, node in pairs(spec.nodes) do
		if node.dn and lc(node.dn) == want then
			-- prefer nodes reachable from the current tree, then the closest one
			local score = (node.path and #node.path or 1e6)
			if node.ascendancyName and spec.curAscendClass and node.ascendancyName ~= spec.curAscendClass.name then score = score + 1e7 end
			if not best or score < best.score then best = { node = node, score = score } end
		end
	end
	return best and best.node
end

local function allocNodes(list, force)
	local spec = build.spec
	local pending = {}
	for _, ref in ipairs(list or {}) do
		local node = findNode(ref)
		if not node then warn("node not found: " .. tostring(ref)) else pending[#pending+1] = node end
	end
	-- allocate in passes so nodes that only become reachable after others still get pathed
	for _ = 1, 4 do
		local left = {}
		for _, node in ipairs(pending) do
			if not node.alloc then
				if force then
					node.alloc = true
					spec.allocNodes[node.id] = node
				elseif node.path then
					spec:AllocNode(node)
				end
				if not node.alloc then left[#left+1] = node end
			end
		end
		pending = left
		if #pending == 0 then break end
	end
	if force then spec:BuildAllDependsAndPaths() end
	for _, node in ipairs(pending) do warn("node could not be connected: " .. tostring(node.dn) .. " (" .. node.id .. ")") end
	build.buildFlag = true
end

local function deallocNodes(list)
	for _, ref in ipairs(list or {}) do
		local node = findNode(ref)
		if node and node.alloc then build.spec:DeallocNode(node) else warn("node not allocated: " .. tostring(ref)) end
	end
end

local function setClass(className, ascName)
	local spec = build.spec
	if className then
		local id = spec.tree.classNameMap[className]
		if not id then
			for name, cid in pairs(spec.tree.classNameMap) do if lc(name) == lc(className) then id = cid end end
		end
		if id then spec:SelectClass(id) else warn("unknown class: " .. className) end
	end
	if ascName then
		local found
		for ascId, asc in pairs(spec.curClass.classes) do
			if lc(asc.name) == lc(ascName) then spec:SelectAscendClass(ascId) found = true break end
		end
		if not found then
			-- ascendancy given without class: search every class
			local entry = spec.tree.ascendNameMap[ascName]
			if entry then spec:SelectClass(entry.classId) spec:SelectAscendClass(entry.ascendClassId) found = true end
		end
		if not found then warn("unknown ascendancy: " .. ascName) end
	end
end

local function setLevel(level)
	build.characterLevel = level
	build.characterLevelAutoMode = false
	if build.controls.characterLevel then build.controls.characterLevel:SetText(tostring(level)) end
end

local function addSkills(skills)
	for _, s in ipairs(skills or {}) do
		local text = type(s) == "table" and s.text or s
		if type(s) == "table" and s.label then text = "Label: " .. s.label .. "\n" .. text end
		local before = #build.skillsTab.socketGroupList
		build.skillsTab:PasteSocketGroup(text)
		if #build.skillsTab.socketGroupList == before then warn("skill group not parsed: " .. text) end
	end
	build.buildFlag = true
end

local function addItems(items)
	for _, raw in ipairs(items or {}) do
		local ok, err = pcall(function()
			build.itemsTab:CreateDisplayItemFromRaw(raw)
			if not build.itemsTab.displayItem then error("item not parsed") end
			build.itemsTab:AddDisplayItem()
		end)
		if not ok then warn("item failed: " .. tostring(err) .. " :: " .. raw:sub(1, 60)) end
	end
	build.buildFlag = true
end

local function applyConfig(config, customMods)
	local tab = build.configTab
	for k, v in pairs(config or {}) do tab.input[k] = v end
	if customMods then
		local cur = tab.input.customMods or ""
		tab.input.customMods = (cur ~= "" and (cur .. "\n") or "") .. customMods
	end
	tab:BuildModList()
	build.buildFlag = true
end

local function selectMainSkill(sel)
	if sel == nil then return end
	local activeName
	if type(sel) == "table" then activeName = sel.skill sel = sel.group or sel.skill end
	local list = build.skillsTab.socketGroupList
	local idx
	if type(sel) == "number" then idx = sel
	else
		for i, g in ipairs(list) do
			local names = { g.label or "", g.displayLabel or "" }
			for _, gem in ipairs(g.gemList or {}) do names[#names+1] = gem.nameSpec or "" end
			for _, n in ipairs(names) do if lc(n) == lc(sel) then idx = i break end end
			if idx then break end
		end
		if not idx then
			for i, g in ipairs(list) do if g.displayLabel and lc(g.displayLabel):find(lc(sel), 1, true) then idx = i break end end
		end
	end
	if not idx or not list[idx] then warn("main skill not found: " .. tostring(sel)) return end
	build.mainSocketGroup = idx
	build.calcsTab.input.skill_number = idx
	local anyFull = false
	for _, g in ipairs(list) do if g.includeInFullDPS then anyFull = true end end
	if not anyFull then list[idx].includeInFullDPS = true end
	list[idx].mainActiveSkill = list[idx].mainActiveSkill or 1
	list[idx].mainActiveSkillCalcs = list[idx].mainActiveSkillCalcs or 1
	build.buildFlag = true
	-- a group can hold several active skills (meta gems + socketed skills); pick the named one
	local want = activeName or (type(sel) == "string" and sel)
	if want then
		recalc()
		for i, sk in ipairs(list[idx].displaySkillList or {}) do
			local ge = sk.activeEffect and sk.activeEffect.grantedEffect
			if ge and lc(ge.name) == lc(want) then
				list[idx].mainActiveSkill = i
				list[idx].mainActiveSkillCalcs = i
				break
			end
		end
	end
end

-- Stats the AI usually cares about. Missing keys are simply left out.
local SUMMARY = {
	"FullDPS", "CombinedDPS", "TotalDPS", "TotalDot", "TotalDotDPS", "WithDotDPS",
	"AverageHit", "AverageDamage", "Speed", "HitSpeed", "HitChance", "CritChance", "CritMultiplier",
	"IgniteDPS", "BleedDPS", "PoisonDPS", "TotalPoisonDPS", "ImpaleDPS", "BurningGroundDPS", "CausticGroundDPS", "CullingDPS", "MirageDPS",
	"ManaCost", "ManaPerSecondCost", "LifeCost", "ManaUnreserved", "SpiritUnreserved",
	"Life", "LifeUnreserved", "LifeRegenRecovery", "Mana", "ManaRegenRecovery", "EnergyShield", "EnergyShieldRegenRecovery", "Spirit",
	"Armour", "Evasion", "EvadeChance", "BlockChance", "SpellBlockChance", "PhysicalDamageReduction",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist", "FireResistOverCap", "ColdResistOverCap", "LightningResistOverCap",
	"TotalEHP", "PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken", "ChaosMaximumHitTaken",
	"EffectiveMovementSpeedMod", "Str", "Dex", "Int", "ReqStr", "ReqDex", "ReqInt",
}

local function scalarDump(t, depth)
	local o = {}
	for k, v in pairs(t) do
		local tv = type(v)
		if tv == "number" then
			if v == v and v ~= math.huge and v ~= -math.huge then o[k] = v end
		elseif tv == "boolean" or tv == "string" then o[k] = v
		elseif tv == "table" and depth > 0 and (k == "MainHand" or k == "OffHand" or k == "Minion") then
			o[k] = scalarDump(v, depth - 1)
		end
	end
	return o
end

local function snapshot(full)
	local out = build.calcsTab.mainOutput or {}
	local s = {}
	for _, k in ipairs(SUMMARY) do
		local v = out[k]
		if type(v) == "number" and v == v and v ~= math.huge then s[k] = v end
	end
	if out.Minion then
		s.Minion = {}
		for _, k in ipairs({ "TotalDPS", "CombinedDPS", "FullDPS", "AverageHit", "Speed", "Life", "EnergyShield" }) do
			if type(out.Minion[k]) == "number" then s.Minion[k] = out.Minion[k] end
		end
	end
	if out.SkillDPS then
		s.SkillDPS = {}
		for _, sk in ipairs(out.SkillDPS) do s.SkillDPS[#s.SkillDPS+1] = { name = sk.name, dps = sk.dps, count = sk.count, trigger = sk.trigger, skillPart = sk.skillPart } end
	end
	-- main skill info
	local grp = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if grp then s.mainSkill = { group = build.mainSocketGroup, label = grp.displayLabel } end
	local env = build.calcsTab.mainEnv
	if env and env.player and env.player.mainSkill then
		local ms = env.player.mainSkill
		s.mainSkill = s.mainSkill or {}
		s.mainSkill.name = ms.activeEffect and ms.activeEffect.grantedEffect and ms.activeEffect.grantedEffect.name
		local types = {}
		local seen = {}
		local sc = ms.activeEffect and ms.activeEffect.statSetCalcs
		for _, src in ipairs({ ms.skillFlags or {}, sc and sc.skillFlags or {} }) do
			for flag, on in pairs(src) do if on and not seen[flag] then seen[flag] = true types[#types+1] = tostring(flag) end end
		end
		table.sort(types)
		s.mainSkill.flags = types
	end
	if full then s.full = scalarDump(out, 1) end
	return s
end

local function listSkills()
	local res = {}
	for i, g in ipairs(build.skillsTab.socketGroupList) do
		local gems = {}
		for _, gem in ipairs(g.gemList or {}) do
			gems[#gems+1] = { name = gem.nameSpec, level = gem.level, quality = gem.quality, enabled = gem.enabled, valid = gem.gemData ~= nil }
		end
		res[#res+1] = { index = i, label = g.displayLabel, enabled = g.enabled, slot = g.slot, gems = gems }
	end
	return res
end

local function delta(base, cur)
	local d = {}
	for k, v in pairs(cur) do
		if type(v) == "number" and type(base[k]) == "number" and v ~= base[k] then
			d[k] = { from = base[k], to = v, pct = base[k] ~= 0 and ((v - base[k]) / math.abs(base[k]) * 100) or nil }
		end
	end
	return d
end

local function exportCode()
	local xml = build:SaveDB("code")
	local code
	local deflated = Deflate(xml)
	if deflated and #deflated > 0 then
		code = common.base64.encode(deflated):gsub("+", "-"):gsub("/", "_")
	end
	return xml, code
end

local function loadBase(r)
	if r.xml then
		loadBuildFromXML(r.xml, r.name or "pob_calc")
	else
		newBuild()
	end
	local s = r.spec or {}
	if s.class or s.ascendancy then setClass(s.class, s.ascendancy) end
	if s.level then setLevel(s.level) end
	if s.nodes then allocNodes(s.nodes, false) end
	if s.forceNodes then allocNodes(s.forceNodes, true) end
	if s.items then addItems(s.items) end
	if s.skills then addSkills(s.skills) end
	runCallback("OnFrame")
	applyConfig(r.config, r.customMods)
	selectMainSkill(r.mainSkill or s.mainSkill)
	recalc()
end

local function applyVariant(v)
	if v.class or v.ascendancy then setClass(v.class, v.ascendancy) end
	if v.level then setLevel(v.level) end
	if v.removeNodes then deallocNodes(v.removeNodes) end
	if v.addNodes then allocNodes(v.addNodes, false) end
	if v.forceNodes then allocNodes(v.forceNodes, true) end
	if v.items then addItems(v.items) end
	if v.skills then addSkills(v.skills) end
	if v.replaceSkills then
		wipeTable(build.skillsTab.socketGroupList)
		addSkills(v.replaceSkills)
	end
	runCallback("OnFrame")
	applyConfig(v.config, v.customMods)
	selectMainSkill(v.mainSkill)
	recalc()
end

-- Rank candidate passive nodes by how much they change one stat, using PoB's fast calculator
local function nodePower(opts)
	local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
	local stat = opts.stat or "FullDPS"
	local baseVal = baseOut[stat] or 0
	local res = {}
	local cands = {}
	if opts.nodes then
		for _, ref in ipairs(opts.nodes) do local n = findNode(ref) if n then cands[#cands+1] = n else warn("node not found: " .. tostring(ref)) end end
	else
		local maxDist = opts.maxDistance or 6
		for _, n in pairs(build.spec.nodes) do
			if not n.alloc and n.path and #n.path <= maxDist and (n.type == "Notable" or n.type == "Keystone" or (opts.includeSmall and n.type == "Normal"))
				and (not n.ascendancyName or (build.spec.curAscendClass and n.ascendancyName == build.spec.curAscendClass.name)) then
				cands[#cands+1] = n
			end
		end
	end
	for _, n in ipairs(cands) do
		local add = {}
		for _, p in ipairs(n.path or { n }) do add[p] = true end
		local ok, out = pcall(calcFunc, { addNodes = add }, stat == "FullDPS")
		if ok and out then
			local v = out[stat] or 0
			local cost = n.path and #n.path or 1
			res[#res+1] = { id = n.id, name = n.dn, type = n.type, points = cost, value = v, gain = v - baseVal,
				gainPct = baseVal ~= 0 and (v - baseVal) / baseVal * 100 or nil, gainPerPoint = (v - baseVal) / cost,
				life = out.Life, es = out.EnergyShield, ehp = out.TotalEHP, stats = n.sd }
		end
	end
	table.sort(res, function(a, b) return a.gainPerPoint > b.gainPerPoint end)
	local top = opts.top or 25
	local cut = {}
	for i = 1, math.min(top, #res) do cut[i] = res[i] end
	return { stat = stat, base = baseVal, candidates = #cands, results = cut }
end

-- Value of equipping each named unique in its own slot (rings -> Ring 1, jewels -> first allocated socket)
local function uniquePower(opts)
	local stat = opts.stat or "FullDPS"
	local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
	local baseVal, baseEHP = baseOut[stat] or 0, baseOut.TotalEHP or 0
	local want = {}
	for _, n in ipairs(opts.names or {}) do want[n] = true end
	local jewelSlot
	for _, slot in ipairs(build.itemsTab.orderedSlots) do
		if slot.nodeId and build.spec.allocNodes[slot.nodeId] then jewelSlot = slot.slotName break end
	end
	local res = {}
	for _, item in pairs(main.uniqueDB.list) do
		if want[item.name] then
			want[item.name] = nil
			local slotName = item:GetPrimarySlot()
			if item.type == "Jewel" then slotName = jewelSlot end
			if slotName and build.itemsTab.slots[slotName] then
				local ok, out = pcall(calcFunc, { repSlotName = slotName, repItem = item }, stat == "FullDPS")
				if ok and out then
					local v = out[stat] or 0
					res[#res+1] = { name = item.name, slot = slotName, value = v, gain = v - baseVal,
						gainPct = baseVal ~= 0 and (v - baseVal) / baseVal * 100 or nil, ehp = out.TotalEHP,
						ehpPct = baseEHP ~= 0 and ((out.TotalEHP or 0) - baseEHP) / baseEHP * 100 or nil }
				else
					res[#res+1] = { name = item.name, slot = slotName, error = tostring(out) }
				end
			else
				res[#res+1] = { name = item.name, error = "no slot " .. tostring(slotName) }
			end
		end
	end
	for n in pairs(want) do res[#res+1] = { name = n, error = "not in uniqueDB" } end
	return { stat = stat, base = baseVal, ehp = baseEHP, results = res }
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local function handle(r)
req = r
for k in pairs(warnings) do warnings[k] = nil end
local response = {}
local ok, err = xpcall(function()
	loadBase(req)
	if req.optimize then
		local O = dofile(here .. "/optimizer.lua")
		local okO, resO = xpcall(function() return O.run({ recalc = recalc, warn = warn }, req.optimize) end, debug.traceback)
		response.optimize = okO and resO or { error = tostring(resO) }
	end
	local base = snapshot(req.full)
	response.base = base
	response.skills = listSkills()
	response.build = {
		class = build.spec.curClassName, ascendancy = build.spec.curAscendClassName,
		level = build.characterLevel, points = select(1, build.spec:CountAllocNodes()),
		treeVersion = build.spec.treeVersion, targetVersion = build.targetVersion,
	}
	local baseXml, code = exportCode()
	if req.export ~= false then response.code = code end
	if req.exportXml then response.xml = baseXml end
	if req.listGems then
		local rev = {}
		for k, v in pairs(SkillType) do rev[v] = k end
		local gems = {}
		for id, gd in pairs(build.data.gems) do
			local ge = gd.grantedEffect
			if ge and not ge.legacy then
				local types = {}
				for t, on in pairs(ge.skillTypes or {}) do if on then types[#types+1] = rev[t] or tostring(t) end end
				table.sort(types)
				local wt = {}
				for w in pairs(ge.weaponTypes or {}) do wt[#wt+1] = w end
				table.sort(wt)
				local tags = {}
				for t, on in pairs(gd.tags or {}) do if on then tags[#tags+1] = t end end
				table.sort(tags)
				gems[#gems+1] = { id = id, name = gd.name, support = ge.support or false, lineage = ge.isLineage or false,
					fromItem = ge.fromItem or false, fromTree = ge.fromTree or false, skillTypes = types, weaponTypes = wt, tags = tags,
					reqStr = gd.reqStr, reqDex = gd.reqDex, reqInt = gd.reqInt, maxLevel = gd.naturalMaxLevel, minion = ge.minionList and true or false,
					tier = gd.Tier, description = ge.description }
				if type(req.listGems) == "table" and req.listGems.text then
					local lines, statIds = {}, {}
					for _, statSet in ipairs(ge.statSets or {}) do
						local ok, err = pcall(function()
							local inst = { level = math.min(gd.naturalMaxLevel or 20, 20), quality = 0 }
							local stats = calcLib.buildSkillInstanceStats(inst, ge, statSet)
							for sid in pairs(stats) do statIds[#statIds+1] = sid end
							local desc = build.data.describeStats(stats, statSet.statDescriptionScope)
							for _, l in ipairs(desc) do lines[#lines+1] = l end
						end)
						if not ok then lines[#lines+1] = "ERR " .. tostring(err) end
					end
					table.sort(statIds)
					gems[#gems].text = lines
					gems[#gems].statIds = statIds
				end
			end
		end
		response.gems = gems
	end
	if req.listClasses then
		local cl = {}
		for name, id in pairs(build.spec.tree.classNameMap) do
			local asc = {}
			for _, a in pairs(build.spec.tree.classes[id].classes) do asc[#asc+1] = a.name end
			cl[name] = asc
		end
		response.classes = cl
	end
	if req.nodePower then response.nodePower = nodePower(req.nodePower) end
	if req.uniquePower then response.uniquePower = uniquePower(req.uniquePower) end
	-- Try every enabled skill as the main skill and report its DPS (finds the real damage skill of imported builds)
	if req.scanSkills then
		local scan = {}
		local list = build.skillsTab.socketGroupList
		local savedGroup = build.mainSocketGroup
		for gi, g in ipairs(list) do
			if g.enabled ~= false then
				local n = math.min(#(g.displaySkillList or {}), 4)
				for si = 1, n do
					local sk = g.displaySkillList[si]
					local ge = sk and sk.activeEffect and sk.activeEffect.grantedEffect
					build.mainSocketGroup = gi
					build.calcsTab.input.skill_number = gi
					g.mainActiveSkill = si
					g.mainActiveSkillCalcs = si
					local okc = pcall(recalc)
					local o = build.calcsTab.mainOutput or {}
					local function num(v) return (type(v) == "number" and v == v and v ~= math.huge) and v or 0 end
					local m = o.Minion or {}
					local row = { group = gi, index = si, label = g.displayLabel, skill = ge and ge.name, ok = okc,
						CombinedDPS = num(o.CombinedDPS), TotalDPS = num(o.TotalDPS), TotalDotDPS = num(o.TotalDotDPS),
						MinionDPS = num(m.CombinedDPS) > 0 and num(m.CombinedDPS) or num(m.TotalDPS) }
					row.best = math.max(row.CombinedDPS, row.MinionDPS)
					if row.best > 0 then scan[#scan+1] = row end
				end
			end
		end
		table.sort(scan, function(a, b) return a.best > b.best end)
		response.skillScan = scan
		build.mainSocketGroup = savedGroup
	end
	-- Ablation: remove each build component (items, jewels, supports, buff groups, keystones/notables) one at a time
	-- and in pairs, to measure what carries the build and which pieces multiply each other (synergy).
	if req.ablate then
		local opt = req.ablate
		local function num(v) return (type(v) == "number" and v == v and v ~= math.huge) and v or 0 end
		local mainName, mainGroup, mainIndex, mainRef
		local function fixMain()
			if not mainName then return false end
			local changed = false
			for gi, gg in ipairs(build.skillsTab.socketGroupList) do
				if gg == mainRef and gi ~= mainGroup then mainGroup = gi changed = true end
			end
			local g = build.skillsTab.socketGroupList[mainGroup]
			if not g then return false end
			if changed or build.mainSocketGroup ~= mainGroup then
				build.mainSocketGroup = mainGroup
				build.calcsTab.input.skill_number = mainGroup
				changed = true
			end
			build.mainSocketGroup = mainGroup
			build.calcsTab.input.skill_number = mainGroup
			local list = g.displaySkillList or {}
			local want = mainIndex
			if not (list[want] and list[want].activeEffect.grantedEffect.name == mainName) then
				want = nil
				for i, sk in ipairs(list) do
					if sk.activeEffect.grantedEffect.name == mainName then want = i break end
				end
			end
			if want and (g.mainActiveSkill ~= want or g.mainActiveSkillCalcs ~= want) then
				g.mainActiveSkill = want g.mainActiveSkillCalcs = want return true
			end
			return changed
		end
		local function measure()
			recalc()
			if fixMain() then recalc() end
			local o = build.calcsTab.mainOutput or {}
			local m = o.Minion or {}
			local dps = math.max(num(o.CombinedDPS), num(m.CombinedDPS), num(m.TotalDPS))
			return dps, num(o.TotalEHP)
		end
		-- main skill = strongest skill (from scan if available)
		if response.skillScan and response.skillScan[1] then
			local b = response.skillScan[1]
			mainName, mainGroup, mainIndex = b.skill, b.group, b.index
			mainRef = build.skillsTab.socketGroupList[b.group]
			local g = build.skillsTab.socketGroupList[b.group]
			build.mainSocketGroup = b.group
			build.calcsTab.input.skill_number = b.group
			g.mainActiveSkill = b.index g.mainActiveSkillCalcs = b.index
		end
		local D0, E0 = measure()
		local D1 = measure()
		local env0 = build.calcsTab.mainEnv
		response.ablateDebug = { D0 = D0, D1 = D1, skill = env0 and env0.player.mainSkill and env0.player.mainSkill.activeEffect.grantedEffect.name }
		local comps = {}
		-- items & jewels
		for _, slot in ipairs(build.itemsTab.orderedSlots) do
			local it = build.itemsTab.items[slot.selItemId]
			if it and slot.selItemId ~= 0 and not slot.slotName:find("Swap") then
				local id = slot.selItemId
				comps[#comps+1] = { kind = it.rarity == "UNIQUE" and "unique" or (slot.nodeId and "jewel" or "rare"), name = (it.title or it.name or "?") .. " [" .. slot.slotName .. "]",
					off = function() slot.selItemId = 0 end, on = function() slot.selItemId = id end }
			end
		end
		-- individual explicit mod lines on rare items (and corrupted/desecrated rares)
		if opt.rareMods then
			for _, slot in ipairs(build.itemsTab.orderedSlots) do
				local it = build.itemsTab.items[slot.selItemId]
				if it and slot.selItemId ~= 0 and not slot.slotName:find("Swap") and it.rarity ~= "UNIQUE" then
					local id = slot.selItemId
					local raw = it:BuildRaw()
					for _, ml in ipairs(it.explicitModLines or {}) do
						local text = ml.line
						if text and text ~= "" then
							local variant
							comps[#comps+1] = { kind = "rare_mod", name = text .. " [" .. slot.slotName .. "]", item = (it.title or it.name),
								off = function()
									if not variant then
										local lines, removed = {}, false
										for l in (raw .. "\n"):gmatch("(.-)\n") do
											local plain = l:gsub("{[^}]*}", "")
											if not removed and plain == text then removed = true else lines[#lines+1] = l end
										end
										variant = new("Item"):Item(table.concat(lines, "\n"))
										variant:NormaliseQuality()
										build.itemsTab:AddItem(variant, true)
									end
									slot.selItemId = variant.id
								end,
								on = function() slot.selItemId = id end }
						end
					end
				end
			end
		end
		-- gems: supports in the main group, and whole other enabled groups (auras, buffs, triggers)
		local mainIdx = build.mainSocketGroup
		for gi, g in ipairs(build.skillsTab.socketGroupList) do
			if g.enabled ~= false then
				if gi == mainIdx then
					for _, gem in ipairs(g.gemList or {}) do
						local gd = gem.gemData
						if gem.enabled and gd and gd.grantedEffect and gd.grantedEffect.support then
							comps[#comps+1] = { kind = gd.grantedEffect.isLineage and "lineage_support" or "support", name = gem.nameSpec,
								off = function() gem.enabled = false build.skillsTab:ProcessSocketGroup(g) end,
								on = function() gem.enabled = true build.skillsTab:ProcessSocketGroup(g) end }
						end
					end
				elseif not g.source then
					comps[#comps+1] = { kind = "group", name = g.displayLabel or ("group " .. gi),
						off = function() g.enabled = false end, on = function() g.enabled = true end }
				end
			end
		end
		-- passive nodes
		for id, node in pairs(build.spec.allocNodes) do
			if node.type == "Keystone" or node.type == "Notable" or (node.ascendancyName and node.type ~= "AscendClassStart" and not node.isAscendancyStart) then
				comps[#comps+1] = { kind = node.ascendancyName and "ascendancy" or lc(node.type), name = node.dn, id = id,
					off = function() node.alloc = false build.spec.allocNodes[id] = nil end,
					on = function() node.alloc = true build.spec.allocNodes[id] = node end }
			end
		end
		if opt.only then
			local keep = {}
			for _, c in ipairs(comps) do if opt.only[c.kind] then keep[#keep+1] = c end end
			comps = keep
		end
		local singles = {}
		for _, c in ipairs(comps) do
			c.off()
			local ok, d, e = pcall(measure)
			c.on()
			if opt.debug then
				local rd = measure()
				local g = build.skillsTab.socketGroupList[build.mainSocketGroup]
				local names = {}
				for i, sk in ipairs(g and g.displaySkillList or {}) do names[#names+1] = sk.activeEffect.grantedEffect.name end
				local ms = build.calcsTab.mainEnv.player.mainSkill
				response.ablateDebug[#response.ablateDebug+1] = { c.name, d, rd, build.mainSocketGroup, g and g.mainActiveSkill, table.concat(names, ","), ms and ms.activeEffect.grantedEffect.name, g and g.enabled }
			end
			if ok then
				c.dps, c.ehp = d, e
				c.dpsLoss = D0 > 0 and (1 - d / D0) or 0
				c.ehpLoss = E0 > 0 and (1 - e / E0) or 0
				singles[#singles+1] = c
			end
		end
		measure()
		table.sort(singles, function(a, b) return (a.dpsLoss + a.ehpLoss) > (b.dpsLoss + b.ehpLoss) end)
		local out = { baseDPS = D0, baseEHP = E0, components = {}, pairs = {} }
		for _, c in ipairs(singles) do
			out.components[#out.components+1] = { kind = c.kind, name = c.name, item = c.item, dpsLoss = c.dpsLoss, ehpLoss = c.ehpLoss }
		end
		-- pairwise synergy among the most important pieces
		local K = opt.pairs or 8
		local topc = {}
		for i = 1, math.min(K, #singles) do if (singles[i].dpsLoss + singles[i].ehpLoss) > 0.02 then topc[#topc+1] = singles[i] end end
		for i = 1, #topc do
			for j = i + 1, #topc do
				local a, b = topc[i], topc[j]
				a.off() b.off()
				local ok, d, e = pcall(measure)
				b.on() a.on()
				if ok then
					-- independent (multiplicative) expectation vs actual: >1 means the pair is worth more together
					local expD = D0 > 0 and (a.dps * b.dps / D0) or 0
					local expE = E0 > 0 and (a.ehp * b.ehp / E0) or 0
					out.pairs[#out.pairs+1] = { a = a.name, b = b.name, akind = a.kind, bkind = b.kind,
						dpsBoth = D0 > 0 and (1 - d / D0) or 0, ehpBoth = E0 > 0 and (1 - e / E0) or 0,
						dpsSynergy = (d > 0 and expD > 0) and (expD / d) or nil, ehpSynergy = (e > 0 and expE > 0) and (expE / e) or nil }
				end
			end
		end
		measure()
		response.ablation = out
	end
	if req.variants then
		response.variants = {}
		for i, v in ipairs(req.variants) do
			local before = #warnings
			loadBuildFromXML(baseXml, "variant")
			applyConfig(nil, nil)
			local vok, verr = pcall(applyVariant, v)
			local snap = vok and snapshot(v.full) or nil
			local entry = { name = v.name or ("variant " .. i), ok = vok, error = (not vok) and tostring(verr) or nil, stats = snap, delta = snap and delta(base, snap) or nil }
			if v.export then entry.code = select(2, exportCode()) end
			entry.warnings = {}
			for w = before + 1, #warnings do entry.warnings[#entry.warnings+1] = warnings[w] end
			response.variants[i] = entry
		end
	end
end, debug.traceback)
response.ok = ok
if not ok then response.error = tostring(err) end
response.warnings = { unpack(warnings) }
if not quiet then response.log = logLines end
return response
end

if reqPath ~= "--serve" and reqPath ~= "--http" then
	local response = handle(dkjson.decode(readFile(reqPath)))
	writeFile(outPath, dkjson.encode(response, { indent = true }))
	print = realPrint
	return
end

local H = {
	handle = handle, dkjson = dkjson, recalc = recalc, warn = warn, warnings = warnings,
	loadBase = loadBase, applyVariant = applyVariant, allocNodes = allocNodes, deallocNodes = deallocNodes, findNode = findNode,
	addItems = addItems, addSkills = addSkills, applyConfig = applyConfig, selectMainSkill = selectMainSkill,
	snapshot = snapshot, listSkills = listSkills, delta = delta, exportCode = exportCode, logLines = logLines,
}
if reqPath == "--http" then
	H.mode = "lib"
	local process = dofile(here .. "/serve.lua")(H)
	dofile(here .. "/http.lua")(process, { port = tonumber(arg[2]) or 8765, webroot = arg[3] or (here .. "/web"), dkjson = dkjson, realPrint = realPrint })
else
	dofile(here .. "/serve.lua")(H)
end
