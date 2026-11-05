-- Serve mode: PoB stays loaded; one JSON request per stdin line, one JSON response per stdout line.
--   luajit driver.lua --serve
-- A line without "op" is a normal one-shot request (same format as driver.lua).
-- Ops keep the loaded build in memory, so edits recalc in well under a second:
--   {"op":"load","xml":...|"code":...,"mainSkill":...}
--   {"op":"state"}                                   allocated nodes, items, skill groups, config, stats
--   {"op":"apply","addNodes":[id],"removeNodes":[id],"equip":[{"slot":"Ring 1","unique":"Name"}|{"slot":..,"raw":".."}],
--          "unequip":["Helmet"],"setGroup":{"index":1,"text":"Gem 20/20\nSupport 1/0"},"addGroup":"text",
--          "toggleGem":{"group":1,"gem":2,"enabled":false},"config":{...},"mainSkill":...}
--   {"op":"preview","candidates":[{"addNodes":[id]}|{"removeNodes":[id]}|{"slot":..,"unique":..}]}   value without applying
--   {"op":"findNodes","text":"ignite","limit":40}     notables/keystones matching text, with path length
--   {"op":"uniques","slot":"Ring"}                    unique catalog
--   {"op":"export"}                                   PoB build code
return function(H)
	local dk = H.dkjson
	local KEYS = { "FullDPS", "CombinedDPS", "TotalEHP", "Life", "EnergyShield", "Mana", "Spirit", "SpiritUnreserved", "Armour", "Evasion",
		"FireResist", "ColdResist", "LightningResist", "ChaosResist", "CritChance", "Speed", "AverageHit", "PhysicalMaximumHitTaken" }

	local function stats(out)
		local s = {}
		for _, k in ipairs(KEYS) do local v = out[k] if type(v) == "number" and v == v and v ~= math.huge then s[k] = v end end
		if out.Minion and type(out.Minion.CombinedDPS) == "number" then s.MinionDPS = out.Minion.CombinedDPS end
		return s
	end
	local function cur() return stats(build.calcsTab.mainOutput or {}) end

	local function nodeInfo(n)
		return { id = n.id, name = n.dn, type = n.type, asc = n.ascendancyName, stats = n.sd, points = n.path and #n.path or nil, alloc = n.alloc or false,
			x = n.x, y = n.y }
	end

	local function itemInfo(slotName, it)
		local lines = {}
		for _, list in ipairs({ it.implicitModLines or {}, it.explicitModLines or {} }) do
			for _, l in ipairs(list) do lines[#lines+1] = l.line end
		end
		return { slot = slotName, name = it.name, base = it.baseName, rarity = it.rarity, type = it.type, mods = lines }
	end

	local function state()
		local nodes = {}
		for id, n in pairs(build.spec.allocNodes) do
			if n.type ~= "ClassStart" and n.type ~= "AscendClassStart" then nodes[#nodes+1] = nodeInfo(n) end
		end
		table.sort(nodes, function(a, b) return a.id < b.id end)
		local items = {}
		for _, slot in ipairs(build.itemsTab.orderedSlots) do
			local it = build.itemsTab.items[slot.selItemId]
			if it then items[#items+1] = itemInfo(slot.slotName, it) end
		end
		local cfg = {}
		for k, v in pairs(build.configTab.input or {}) do
			if type(v) ~= "table" then cfg[k] = v end
		end
		return { class = build.spec.curClassName, ascendancy = build.spec.curAscendClassName, level = build.characterLevel,
			points = select(1, build.spec:CountAllocNodes()), nodes = nodes, items = items, skills = H.listSkills(),
			mainGroup = build.mainSocketGroup, config = cfg, stats = cur() }
	end

	local function shortName(item) return (item.name or ""):match("^(.-),") or item.name end
	local function findUnique(name)
		for _, item in pairs(main.uniqueDB.list) do if item.name == name or shortName(item) == name then return item end end
	end
	-- path nodes allocated on behalf of a requested node, so removing it also removes the path it brought
	local brought = {}

	local function equip(slotName, item)
		local newItem = new("Item"):Item(item:BuildRaw())
		newItem:NormaliseQuality()
		build.itemsTab:AddItem(newItem, true)
		build.itemsTab.slots[slotName]:SetSelItemId(newItem.id)
		build.itemsTab:PopulateSlots()
		build.buildFlag = true
	end

	local function setGroup(index, text)
		local list = build.skillsTab.socketGroupList
		local before = #list
		build.skillsTab:PasteSocketGroup(text)
		if #list == before then H.warn("skill group not parsed") return end
		local g = table.remove(list)
		if index and list[index] then
			g.slot = list[index].slot
			g.label = list[index].label
			list[index] = g
		else
			list[#list+1] = g
		end
		build.skillsTab:ProcessSocketGroup(g)
		build.buildFlag = true
	end

	local function addGem(gi, name, level, quality)
		local g = build.skillsTab.socketGroupList[gi or build.mainSocketGroup]
		if not g then H.warn("no group " .. tostring(gi)) return end
		g.gemList[#g.gemList+1] = { nameSpec = name, level = level or 1, quality = quality or 0, enabled = true, count = 1,
			corrupted = false, corruptLevel = 0, enableGlobal1 = true, enableGlobal2 = true }
		build.skillsTab:ProcessSocketGroup(g)
		local gem = g.gemList[#g.gemList]
		if not gem.gemData then H.warn("gem not found: " .. name) table.remove(g.gemList) build.skillsTab:ProcessSocketGroup(g) end
		build.buildFlag = true
		return g
	end
	local function removeGem(gi, idx)
		local g = build.skillsTab.socketGroupList[gi or build.mainSocketGroup]
		if g and g.gemList[idx] then table.remove(g.gemList, idx) build.skillsTab:ProcessSocketGroup(g) build.buildFlag = true end
	end

	local function apply(r)
		if r.addGem then addGem(r.addGem.group, r.addGem.name, r.addGem.level, r.addGem.quality) end
		if r.removeGem then removeGem(r.removeGem.group, r.removeGem.gem) end
		if r.removeNodes then
			local keep = {}
			for _, ref in ipairs(r.removeNodes) do
				local n = H.findNode(ref)
				if n and n.alloc then
					local path = brought[n.id] or {}
					brought[n.id] = nil
					build.spec:DeallocNode(n)
					-- drop path nodes this node brought in, leaf first, unless another kept node needs them
					local needed = {}
					for _, list in pairs(brought) do for _, id in ipairs(list) do needed[id] = true end end
					local changed = true
					while changed do
						changed = false
						for _, id in ipairs(path) do
							local p = build.spec.nodes[id]
							if p and p.alloc and not needed[id] then
								local links = 0
								for _, o in ipairs(p.linked or {}) do if o.alloc then links = links + 1 end end
								if links <= 1 then build.spec:DeallocNode(p) changed = true end
							end
						end
					end
				else
					H.warn("node not allocated: " .. tostring(ref))
				end
			end
			build.buildFlag = true
		end
		if r.addNodes then
			for _, ref in ipairs(r.addNodes) do
				local n = H.findNode(ref)
				if n and not n.alloc then
					local before = {}
					for id in pairs(build.spec.allocNodes) do before[id] = true end
					H.allocNodes({ n.id }, false)
					local list = {}
					for id in pairs(build.spec.allocNodes) do if not before[id] and id ~= n.id then list[#list+1] = id end end
					brought[n.id] = list
				end
			end
		end
		for _, e in ipairs(r.equip or {}) do
			local slot = build.itemsTab.slots[e.slot]
			if not slot then H.warn("no slot " .. tostring(e.slot))
			elseif e.unique then
				local it = findUnique(e.unique)
				if it then equip(e.slot, it) else H.warn("unique not found: " .. e.unique) end
			elseif e.raw then
				local ok, err = pcall(function() equip(e.slot, new("Item"):Item(e.raw)) end)
				if not ok then H.warn("item failed: " .. tostring(err)) end
			end
		end
		for _, s in ipairs(r.unequip or {}) do
			local slot = build.itemsTab.slots[s]
			if slot then slot:SetSelItemId(0) build.itemsTab:PopulateSlots() build.buildFlag = true end
		end
		if r.setGroup then setGroup(r.setGroup.index, r.setGroup.text) end
		if r.addGroup then setGroup(nil, r.addGroup) end
		if r.removeGroup then table.remove(build.skillsTab.socketGroupList, r.removeGroup) build.buildFlag = true end
		if r.toggleGem then
			local g = build.skillsTab.socketGroupList[r.toggleGem.group]
			local gem = g and g.gemList[r.toggleGem.gem]
			if gem then gem.enabled = r.toggleGem.enabled ~= false build.skillsTab:ProcessSocketGroup(g) build.buildFlag = true end
		end
		if r.config then H.applyConfig(r.config) end
		runCallback("OnFrame")
		if r.mainSkill then H.selectMainSkill(r.mainSkill) end
		H.recalc()
	end

	local function preview(cands)
		local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
		local b = stats(baseOut)
		local res = {}
		-- gem candidates need a real recalc: add, measure, remove
		for i, c in ipairs(cands or {}) do
			if c.gem then
				local gi = c.group or build.mainSocketGroup
				local g = addGem(gi, c.gem, c.level, c.quality)
				if g and g.gemList[#g.gemList].nameSpec == c.gem then
					H.recalc()
					local s = cur()
					table.remove(g.gemList)
					build.skillsTab:ProcessSocketGroup(g)
					build.buildFlag = true
					H.recalc()
					res[i] = { ok = true, stats = s,
						dpsPct = (b.FullDPS or 0) ~= 0 and ((s.FullDPS or 0) - b.FullDPS) / b.FullDPS * 100 or nil,
						ehpPct = (b.TotalEHP or 0) ~= 0 and ((s.TotalEHP or 0) - b.TotalEHP) / b.TotalEHP * 100 or nil }
				else
					res[i] = { ok = false, error = "gem not added" }
				end
			end
		end
		calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
		for i, c in ipairs(cands or {}) do
			if c.gem then goto continue_cand end
			local ov, info = {}, {}
			if c.addNodes then
				ov.addNodes = {}
				for _, ref in ipairs(c.addNodes) do
					local n = H.findNode(ref)
					if n then for _, p in ipairs(n.path or { n }) do ov.addNodes[p] = true end info.points = (info.points or 0) + (n.path and #n.path or 1) end
				end
			end
			if c.removeNodes then
				ov.removeNodes = {}
				for _, ref in ipairs(c.removeNodes) do
					local n = H.findNode(ref)
					if n then
						ov.removeNodes[n] = true
						for _, d in ipairs(n.depends or {}) do ov.removeNodes[d] = true end
					end
				end
			end
			if c.unique then
				local it = findUnique(c.unique)
				if it then ov.repSlotName = c.slot or it:GetPrimarySlot() ov.repItem = it end
			end
			local ok, out = pcall(calcFunc, ov, true)
			if ok and out then
				local s = stats(out)
				res[i] = { ok = true, stats = s, points = info.points,
					dpsPct = (b.FullDPS or 0) ~= 0 and ((s.FullDPS or 0) - b.FullDPS) / b.FullDPS * 100 or nil,
					ehpPct = (b.TotalEHP or 0) ~= 0 and ((s.TotalEHP or 0) - b.TotalEHP) / b.TotalEHP * 100 or nil }
			else
				res[i] = { ok = false, error = tostring(out) }
			end
			::continue_cand::
		end
		return { base = b, results = res }
	end

	local function findNodes(text, limit)
		local want = (text or ""):lower()
		local res = {}
		for _, n in pairs(build.spec.nodes) do
			if not n.alloc and (n.type == "Notable" or n.type == "Keystone" or (n.ascendancyName and n.ascendancyName == build.spec.curAscendClassName)) and n.dn then
				local hay = n.dn:lower() .. " " .. table.concat(n.sd or {}, " "):lower()
				if want == "" or hay:find(want, 1, true) then res[#res+1] = nodeInfo(n) end
			end
		end
		table.sort(res, function(a, b) return (a.points or 999) < (b.points or 999) end)
		local cut = {}
		for i = 1, math.min(limit or 50, #res) do cut[i] = res[i] end
		return cut
	end

	local function gemList(supportOnly)
		local res = {}
		for id, gd in pairs(build.data.gems) do
			local ge = gd.grantedEffect
			if ge and not ge.legacy and not ge.fromItem and not ge.fromTree and (supportOnly == nil or (ge.support or false) == supportOnly) then
				res[#res+1] = { name = gd.name, support = ge.support or false, lineage = ge.isLineage or false }
			end
		end
		table.sort(res, function(a, b) return a.name < b.name end)
		return res
	end

	local function uniques(slotFilter)
		local res = {}
		for _, item in pairs(main.uniqueDB.list) do
			local slot = item:GetPrimarySlot()
			if not slotFilter or (slot and slot:find(slotFilter, 1, true)) or (item.type or ""):find(slotFilter, 1, true) then
				res[#res+1] = { name = shortName(item), base = item.baseName, type = item.type, slot = slot }
			end
		end
		table.sort(res, function(a, b) return a.name < b.name end)
		return res
	end

	local function process(r)
		for k in pairs(H.warnings) do H.warnings[k] = nil end
		local t0 = os.clock()
		local resp
		if type(r) ~= "table" then
			resp = { ok = false, error = "bad json" }
		elseif not r.op then
			resp = H.handle(r)
		else
			local ok, out = xpcall(function()
				local before = cur()
				if r.op == "load" then
					if r.code and not r.xml then
						local b64 = r.code:gsub("%s", ""):gsub("-", "+"):gsub("_", "/")
						local xml = Inflate(common.base64.decode(b64))
						if not xml or xml == "" then error("could not decode build code") end
						r.xml = xml
					end
					if not r.xml then error("no build code") end
					H.loadBase(r)
					brought = {}
					return { state = state() }
				elseif r.op == "state" then
					return { state = state() }
				elseif r.op == "apply" then
					apply(r)
					local after = cur()
					return { state = state(), before = before, after = after, delta = H.delta(before, after) }
				elseif r.op == "preview" then
					return preview(r.candidates)
				elseif r.op == "findNodes" then
					return { nodes = findNodes(r.text, r.limit) }
				elseif r.op == "uniques" then
					return { uniques = uniques(r.slot) }
				elseif r.op == "gems" then
					return { gems = gemList(r.support) }
				elseif r.op == "update" then
					-- cwd is pob/src; update.ps1 sits in the package root
					os.remove("../../update.log")
					os.execute('powershell -NoProfile -ExecutionPolicy Bypass -File "..\\..\\update.ps1" > "..\\..\\update.log" 2>&1')
					local f = io.open("../../update.log", "rb")
					local log = f and f:read("*a") or ""
					if f then f:close() end
					local done = log:find("UPDATE_OK", 1, true) ~= nil
					return { updated = done, log = log, restart = done }
				elseif r.op == "export" then
					local _, code = H.exportCode()
					return { code = code }
				else
					error("unknown op " .. tostring(r.op))
				end
			end, debug.traceback)
			resp = ok and out or { error = tostring(out) }
			resp.ok = ok
			resp.warnings = { unpack(H.warnings) }
		end
		resp.id = type(r) == "table" and r.id or nil
		resp.ms = math.floor((os.clock() - t0) * 1000)
		return resp
	end

	local mode = H.mode or "stdin"
	if mode == "stdin" then
		io.stdout:setvbuf("no")
		io.stdout:write(dk.encode({ ok = true, ready = true }), "\n")
		for line in io.stdin:lines() do
			if line ~= "" then io.stdout:write(dk.encode(process(dk.decode(line))), "\n") end
		end
	else
		return process
	end
end
