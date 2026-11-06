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
		"FireResist", "ColdResist", "LightningResist", "ChaosResist", "CritChance", "CritMultiplier", "Speed", "AverageHit", "PhysicalMaximumHitTaken", "Str", "Dex", "Int", "ReqStr", "ReqDex", "ReqInt" }

	local function stats(out)
		local s = {}
		for _, k in ipairs(KEYS) do local v = out[k] if type(v) == "number" and v == v and v ~= math.huge then s[k] = v end end
		if out.Minion and type(out.Minion.CombinedDPS) == "number" then s.MinionDPS = out.Minion.CombinedDPS end
		return s
	end
	local function cur() return stats(build.calcsTab.mainOutput or {}) end
	-- the number the editor shows as DPS: main skill (or its minions), Full DPS only when nothing else is there
	local function dpsS(s) return math.max(s.CombinedDPS or 0, s.MinionDPS or 0) > 0 and math.max(s.CombinedDPS or 0, s.MinionDPS or 0) or (s.FullDPS or 0) end
	-- what would make a change impossible in the real game: spirit, attribute requirements (only problems the change adds)
	local ATTR = { Str = "힘", Dex = "민첩", Int = "지능" }
	local function problems(s, b, extra)
		local p = {}
		local su, bu = s.SpiritUnreserved or 0, b.SpiritUnreserved or 0
		if su < 0 and su < bu - 0.5 then p[#p+1] = string.format("정신력 부족 (남은 정신력 %d)", math.floor(su)) end
		for a, kr in pairs(ATTR) do
			local r, have, br, bh = s["Req" .. a] or 0, s[a] or 0, b["Req" .. a] or 0, b[a] or 0
			if r > have and (r > br or have < bh) then p[#p+1] = string.format("%s 부족 (요구 %d / 보유 %d)", kr, r, have) end
		end
		if extra then p[#p+1] = extra end
		return #p > 0 and p or nil
	end
	-- supports a socket group can hold: a skill gem has at most 5 support sockets
	local MAXSUP = 5
	local function supportCount(g)
		local n = 0
		for _, gem in ipairs(g.gemList) do if gem.gemData and gem.gemData.grantedEffect and gem.gemData.grantedEffect.support then n = n + 1 end end
		return n
	end
	local function pctD(s, b) local x, y = dpsS(s), dpsS(b) return y ~= 0 and (x - y) / y * 100 or nil end

	local function nodeInfo(n)
		return { id = n.id, name = n.dn, type = n.type, asc = n.ascendancyName, stats = n.sd, points = n.path and #n.path or nil, alloc = n.alloc or false,
			x = n.x, y = n.y }
	end

	local function itemInfo(slotName, it)
		local lines = {}
		for _, list in ipairs({ it.implicitModLines or {}, it.explicitModLines or {} }) do
			for _, l in ipairs(list) do lines[#lines+1] = l.line end
		end
		local okRaw, raw = pcall(function() return it:BuildRaw() end)
		return { slot = slotName, name = it.name, base = it.baseName, rarity = it.rarity, type = it.type, mods = lines, raw = okRaw and raw or nil, id = it.id }
	end

	-- the two weapon sets: what is in each hand, and which one PoB is calculating with
	local function weaponSets()
		local it = build.itemsTab
		local function nm(slot) local sl = it.slots[slot] local item = sl and it.items[sl.selItemId or 0] return item and (item.name or item.baseName) or nil end
		local act = it.activeItemSet and it.activeItemSet.useSecondWeaponSet and 2 or 1
		local env = build.calcsTab.mainEnv
		return { active = act, calc = env and env.weaponSet or act,
			set1 = { nm("Weapon 1"), nm("Weapon 2") }, set2 = { nm("Weapon 1 Swap"), nm("Weapon 2 Swap") } }
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
			mainGroup = build.mainSocketGroup, config = cfg, stats = cur(), weapons = weaponSets() }
	end

	local function treeAlloc()
		local spec = build.spec
		local list = {}
		for id, n in pairs(spec.allocNodes) do list[#list+1] = { id, n.allocMode or 0, n.isAttribute and n.dn or nil } end
		local used, asc, _, _, ws1, ws2 = spec:CountAllocNodes()
		local mo = build.calcsTab.mainOutput or {}
		local maxWS = (build.maxWeaponSets or 24) + (mo.PassivePointsToWeaponSetPoints or 0)
		return { nodes = list, used = used - math.min(ws1, ws2), usedMax = 99 + (build.maxWeaponSets or 24) + (mo.ExtraPoints or 0),
			asc = asc, ascMax = 8, ws1 = ws1, ws2 = ws2, wsMax = maxWS, allocMode = spec.allocMode or 0, attributeIndex = spec.attributeIndex or 1,
			class = spec.curClassName, ascendancy = spec.curAscendClassName }
	end

	-- is the tree something the game would accept: every allocated node connected to the start (PoB's own check),
	-- points within the budget, only the chosen ascendancy
	local function validateTree()
		local spec = build.spec
		local orphans, wrongAsc, keystones = {}, {}, {}
		for id, n in pairs(spec.allocNodes) do
			if not n.connectedToStart and n.type ~= "ClassStart" and n.type ~= "AscendClassStart" then orphans[#orphans+1] = { id = id, name = n.dn } end
			if n.ascendancyName and spec.curAscendClass and n.ascendancyName ~= spec.curAscendClass.name then wrongAsc[#wrongAsc+1] = { id = id, name = n.dn } end
			if n.type == "Keystone" then keystones[#keystones+1] = n.dn end
		end
		return { alloc = treeAlloc(), orphans = orphans, wrongAsc = wrongAsc, keystones = keystones, treeVersion = spec.treeVersion }
	end

	local function shortName(item) return (item.name or ""):match("^(.-),") or item.name end
	local function findUnique(name)
		for _, item in pairs(main.uniqueDB.list) do if item.name == name or shortName(item) == name then return item end end
	end
	-- path nodes allocated on behalf of a requested node, so removing it also removes the path it brought
	local brought = {}

	local itemGroupPos, collateral = {}, {}
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
			elseif e.id and build.itemsTab.items[e.id] then
				slot:SetSelItemId(e.id) build.itemsTab:PopulateSlots() build.buildFlag = true
			elseif e.raw then
				local ok, err = pcall(function() equip(e.slot, new("Item"):Item(e.raw)) end)
				if not ok then H.warn("item failed: " .. tostring(err)) end
			end
		end
		for _, s in ipairs(r.unequip or {}) do
			local slot = build.itemsTab.slots[s]
			if slot then
				-- skills the item grants lose their socket group while it is off; remember where it sat so switching
				-- the item back on puts it in the same place (group order changes what PoB calculates)
				for gi, g in ipairs(build.skillsTab.socketGroupList) do
					if g.source and g.slot == s then itemGroupPos[g.source .. "|" .. s] = gi end
				end
				-- a quiver drops off with its bow, an off-hand with a two-hander: remember those too
				local had = {}
				for name, sl in pairs(build.itemsTab.slots) do if name ~= s and (sl.selItemId or 0) ~= 0 then had[name] = sl.selItemId end end
				slot:SetSelItemId(0) build.itemsTab:PopulateSlots() build.buildFlag = true
				local lost = {}
				for name, id in pairs(had) do if (build.itemsTab.slots[name].selItemId or 0) == 0 then lost[name] = id end end
				if next(lost) then collateral[s] = lost end
			end
		end
		for _, e in ipairs(r.equip or {}) do
			local lost = collateral[e.slot]
			if lost then
				collateral[e.slot] = nil
				for name, id in pairs(lost) do
					local sl = build.itemsTab.slots[name]
					if sl and (sl.selItemId or 0) == 0 and build.itemsTab.items[id] then sl:SetSelItemId(id) end
				end
				build.itemsTab:PopulateSlots() build.buildFlag = true
			end
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
		if r.equip and next(itemGroupPos) then
			local list, moved = build.skillsTab.socketGroupList, false
			local main = list[build.mainSocketGroup]
			for gi = #list, 1, -1 do
				local g = list[gi]
				local want = g.source and itemGroupPos[g.source .. "|" .. tostring(g.slot)]
				if want and want ~= gi and want <= #list then
					table.remove(list, gi) table.insert(list, want, g)
					itemGroupPos[g.source .. "|" .. tostring(g.slot)] = nil moved = true
				end
			end
			if moved then
				for gi, g in ipairs(list) do if g == main then build.mainSocketGroup = gi build.calcsTab.input.skill_number = gi end end
				H.recalc()
			end
		end
	end

	local function preview(cands)
		local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
		local b = stats(baseOut)
		local res = {}
		-- gem candidates need a real recalc: add, measure, remove
		for i, c in ipairs(cands or {}) do
			if c.addGroup then
				local list = build.skillsTab.socketGroupList
				local n0, main = #list, list[build.mainSocketGroup]
				local okA = pcall(setGroup, nil, c.addGroup)
				if okA and #list > n0 then
					H.recalc()
					local s = cur()
					table.remove(list, #list)
					for gi, g in ipairs(list) do if g == main then build.mainSocketGroup = gi build.calcsTab.input.skill_number = gi end end
					build.buildFlag = true
					H.recalc()
					res[i] = { ok = true, stats = s, dpsPct = pctD(s, b), problems = problems(s, b),
						ehpPct = (b.TotalEHP or 0) ~= 0 and ((s.TotalEHP or 0) - b.TotalEHP) / b.TotalEHP * 100 or nil }
				else
					res[i] = { ok = false, error = "group not added" }
				end
			end
			if c.gem then
				local gi = c.group or build.mainSocketGroup
				local g0 = build.skillsTab.socketGroupList[gi]
				local full = g0 and supportCount(g0) >= MAXSUP and string.format("보조 칸 가득 (%d/%d)", supportCount(g0), MAXSUP) or nil
				local g = addGem(gi, c.gem, c.level, c.quality)
				if g and g.gemList[#g.gemList].nameSpec == c.gem then
					H.recalc()
					local s = cur()
					table.remove(g.gemList)
					build.skillsTab:ProcessSocketGroup(g)
					build.buildFlag = true
					H.recalc()
					res[i] = { ok = true, stats = s, problems = problems(s, b, full),
						dpsPct = pctD(s, b),
						ehpPct = (b.TotalEHP or 0) ~= 0 and ((s.TotalEHP or 0) - b.TotalEHP) / b.TotalEHP * 100 or nil }
				else
					res[i] = { ok = false, error = "gem not added" }
				end
			end
		end
		calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
		for i, c in ipairs(cands or {}) do
			if c.gem or c.addGroup then goto continue_cand end
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
				res[i] = { ok = true, stats = s, points = info.points, problems = problems(s, b),
					dpsPct = pctD(s, b),
					ehpPct = (b.TotalEHP or 0) ~= 0 and ((s.TotalEHP or 0) - b.TotalEHP) / b.TotalEHP * 100 or nil }
			else
				res[i] = { ok = false, error = tostring(out) }
			end
			::continue_cand::
		end
		return { base = b, results = res }
	end

	-- every support gem that can go into socket group gi, with what it does to that skill's DPS and to the main skill
	local function supportOptions(gi, names)
		local g = build.skillsTab.socketGroupList[gi or build.mainSocketGroup]
		if not g then return { ok = false, error = "no group" } end
		local have = {}
		for _, gem in ipairs(g.gemList) do if gem.gemData then have[gem.gemData.name] = true end end
		local want
		if names then want = {} for _, n in ipairs(names) do want[n] = true end end
		local cands = {}
		for id, gd in pairs(build.data.gems) do
			local ge = gd.grantedEffect
			if ge and ge.support and not ge.legacy and not have[gd.name] and (not want or want[gd.name]) then
				for _, sk in ipairs(g.displaySkillList or {}) do
					if calcLib.canGrantedEffectSupportActiveSkill(ge, sk) then cands[#cands+1] = gd break end
				end
			end
		end
		local calcFunc, mainBase = build.calcsTab:GetMiscCalculator()
		local function dpsOf(o) if not o then return 0 end local m = o.Minion and o.Minion.CombinedDPS or 0 return math.max(o.CombinedDPS or 0, m) end
		local ov = { mainSocketGroup = gi }
		local okb, skillBase = pcall(calcFunc, ov, false)
		local sb = okb and dpsOf(skillBase) or 0
		local mb = dpsOf(mainBase)
		local eb = mainBase.TotalEHP or 0
		local function pct(a, b) return b ~= 0 and (a - b) / b * 100 or nil end
		local res = {}
		local nsup = supportCount(g)
		local full = nsup >= MAXSUP and string.format("보조 칸 가득 (%d/%d)", nsup, MAXSUP) or nil
		local bS = stats(mainBase)
		for _, gd in ipairs(cands) do
			g.gemList[#g.gemList+1] = { nameSpec = gd.name, gemId = gd.id, skillId = gd.grantedEffectId, gemData = gd, level = gd.naturalMaxLevel or 1,
				quality = 0, count = 1, enabled = true, enableGlobal1 = true, enableGlobal2 = true, corrupted = false, corruptLevel = 0 }
			build.skillsTab:ProcessSocketGroup(g)
			local ok1, so = pcall(calcFunc, ov, false)
			local ok2, mo = true, so
			if gi ~= build.mainSocketGroup then ok2, mo = pcall(calcFunc, nil, false) end
			table.remove(g.gemList)
			build.skillsTab:ProcessSocketGroup(g)
			res[#res+1] = { name = gd.name, lineage = gd.grantedEffect.isLineage or false, ok = ok1 and ok2,
				skillPct = ok1 and pct(dpsOf(so), sb) or nil, mainPct = ok2 and pct(dpsOf(mo), mb) or nil,
				ehpPct = ok2 and mo and pct(mo.TotalEHP or 0, eb) or nil, problems = ok2 and mo and problems(stats(mo), bS, full) or nil }
		end
		build.skillsTab:ProcessSocketGroup(g)
		build.buildFlag = true
		H.recalc()
		return { ok = true, group = gi, supports = nsup, maxSupports = MAXSUP, skillDPS = sb, mainDPS = mb, isMain = gi == build.mainSocketGroup, options = res }
	end

	-- what each piece of the build is worth: take it out alone (item slot, tree node, gem) and measure
	local function contrib(parts)
		local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
		local b = stats(baseOut)
		local res = {}
		for i, c in ipairs(parts or {}) do
			local ok, out
			if c.slot then
				ok, out = pcall(calcFunc, { repSlotName = c.slot, repItem = nil }, false)
			elseif c.node then
				local n = build.spec.nodes[tonumber(c.node)]
				if n then ok, out = pcall(calcFunc, { removeNodes = { [n] = true } }, false) end
			elseif c.group and c.gem then
				local g = build.skillsTab.socketGroupList[c.group]
				local gem = g and g.gemList[c.gem]
				if gem and gem.enabled ~= false then
					gem.enabled = false build.skillsTab:ProcessSocketGroup(g)
					ok, out = pcall(calcFunc, nil, false)
					gem.enabled = true build.skillsTab:ProcessSocketGroup(g)
				end
			end
			if ok and out then
				local x = stats(out)
				res[i] = { key = c.key, dpsPct = pctD(x, b), ehpPct = (b.TotalEHP or 0) ~= 0 and ((x.TotalEHP or 0) - b.TotalEHP) / b.TotalEHP * 100 or nil }
			else
				res[i] = { key = c.key }
			end
		end
		build.buildFlag = true
		H.recalc()
		return { results = res }
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
				elseif r.op == "optimize" then
					-- greedy optimisation of the loaded build by PoB's own numbers; the old code comes back for undo
					local _, undo = H.exportCode()
					local b = cur()
					local v0 = validateTree()
					local cfg0 = {}
					for k, v in pairs(build.configTab.input or {}) do if type(v) ~= "table" then cfg0[k] = v end end
					local o = r.options or {}
					o.phases = o.phases or { "supports", "treeSwap" }
					o.points = o.points or treeAlloc().used   -- PoB's count: weapon sets 1 and 2 share their points
					o.ehpTarget = o.ehpTarget or (b.TotalEHP or 40000)
					o.iterations = o.iterations or 2
					if o.lockedNodes then o.locked = {} for _, id in ipairs(o.lockedNodes) do o.locked[tonumber(id)] = true end end
					local O = dofile(H.here .. "/optimizer.lua")
					local okO, res = xpcall(function() return O.run({ recalc = H.recalc, warn = H.warn }, o) end, debug.traceback)
					H.recalc()
					local a = cur()
					-- checks on the result: nothing newly cut off from the start, points within what the build had,
					-- the same combat settings and the same PoB calculation for both sides
					local v1 = validateTree()
					local had = {}
					for _, o0 in ipairs(v0.orphans) do had[o0.id] = true end
					local newOrphans = {}
					for _, o1 in ipairs(v1.orphans) do if not had[o1.id] then newOrphans[#newOrphans+1] = o1 end end
					local cfgChanged = {}
					for k, v in pairs(build.configTab.input or {}) do if type(v) ~= "table" and cfg0[k] ~= v then cfgChanged[#cfgChanged+1] = k end end
					for k in pairs(cfg0) do if build.configTab.input[k] == nil then cfgChanged[#cfgChanged+1] = k end end
					local checks = {
						{ key = "connected", ok = #newOrphans == 0, detail = newOrphans },
						{ key = "points", ok = v1.alloc.used <= math.max(v0.alloc.used, v0.alloc.usedMax), before = v0.alloc.used, after = v1.alloc.used, max = v1.alloc.usedMax },
						{ key = "weaponSets", ok = v1.alloc.ws1 == v0.alloc.ws1 and v1.alloc.ws2 == v0.alloc.ws2 and v1.alloc.ws1 <= v1.alloc.wsMax and v1.alloc.ws2 <= v1.alloc.wsMax,
							before = { v0.alloc.ws1, v0.alloc.ws2 }, after = { v1.alloc.ws1, v1.alloc.ws2 }, max = v1.alloc.wsMax },
						{ key = "ascendancy", ok = v1.alloc.asc <= v1.alloc.ascMax and #v1.wrongAsc == 0, before = v0.alloc.asc, after = v1.alloc.asc, max = v1.alloc.ascMax },
						{ key = "keystones", ok = true, before = v0.keystones, after = v1.keystones },
						{ key = "config", ok = #cfgChanged == 0, detail = cfgChanged },
						{ key = "version", ok = v0.treeVersion == v1.treeVersion, before = v0.treeVersion, after = v1.treeVersion },
					}
					return { state = state(), undo = undo, before = b, after = a, dpsPct = pctD(a, b), problems = problems(a, b), checks = checks,
						log = okO and res.log or { tostring(res) }, seconds = okO and res.seconds or nil }
				elseif r.op == "condContrib" then
					-- each condition the calculation assumes (a PoB config setting): switch it off alone, recalc, measure, restore
					local tab = build.configTab
					local b = cur()
					local res = {}
					for i, c in ipairs(r.conds or {}) do
						local saved = {}
						for k, v in pairs(c.config or {}) do saved[k] = tab.input[k] end
						H.applyConfig(c.config)
						H.recalc()
						local x = cur()
						for k in pairs(c.config or {}) do tab.input[k] = saved[k] end
						tab:BuildModList() build.buildFlag = true
						res[i] = { key = c.key, dpsPct = pctD(x, b), ehpPct = (b.TotalEHP or 0) ~= 0 and ((x.TotalEHP or 0) - b.TotalEHP) / b.TotalEHP * 100 or nil }
					end
					H.recalc()
					return { results = res }
				elseif r.op == "validate" then
					return validateTree()
				elseif r.op == "skillInfo" then
					-- one skill group as PoB's main skill: damage, speed, costs, reservation, how it is used/triggered
					local list = build.skillsTab.socketGroupList
					local gi = tonumber(r.group) or build.mainSocketGroup
					if not list[gi] then error("no group " .. tostring(r.group)) end
					local keep = build.mainSocketGroup
					local function setMain(i) build.mainSocketGroup = i build.calcsTab.input.skill_number = i build.buildFlag = true H.recalc() end
					if gi ~= keep then setMain(gi) end
					local o = build.calcsTab.mainOutput or {}
					local env = build.calcsTab.mainEnv
					local ms = env and env.player and env.player.mainSkill
					local info = { group = gi }
					for _, k in ipairs({ "CombinedDPS", "TotalDPS", "FullDPS", "TotalDot", "MinionDPS", "AverageHit", "AverageDamage", "Speed", "HitChance", "CritChance", "CritMultiplier",
						"ProjectileCount", "AreaOfEffectRadiusMetres", "Duration", "Cooldown", "SkillUseTime", "ManaCost", "ManaPerSecondCost", "LifeCost", "LifePerSecondCost", "ESCost", "RageCost", "SpiritUnreserved", "Spirit" }) do
						if type(o[k]) == "number" and o[k] ~= 0 then info[k] = o[k] end
					end
					if ms then
						local ge = ms.activeEffect and ms.activeEffect.grantedEffect
						info.name = ge and ge.name
						local types = {}
						if ge and ge.skillTypes and SkillType then
							for name, id in pairs(SkillType) do if ge.skillTypes[id] then types[#types+1] = name end end
							table.sort(types)
						end
						info.types = types
						local sd = ms.skillData or {}
						info.triggered = (sd.triggered or (ms.skillFlags and ms.skillFlags.triggered)) and true or nil
						info.triggerRate = o.SkillTriggerRate or o.TriggerRate
						info.triggeredBy = ms.triggeredBy and ms.triggeredBy.activeEffect and ms.triggeredBy.activeEffect.grantedEffect and ms.triggeredBy.activeEffect.grantedEffect.name or nil
						info.spirit = sd.SpiritReservedBase
						info.flags = {}
						for k, v in pairs(ms.skillFlags or {}) do if v == true then info.flags[#info.flags+1] = k end end
						table.sort(info.flags)
					end
					if gi ~= keep then setMain(keep) end
					return { info = info }
				elseif r.op == "reservations" then
					local env = build.calcsTab.mainEnv
					local out = {}
					for _, sk in ipairs(env and env.player.activeSkillList or {}) do
						local v = sk.skillData and sk.skillData.SpiritReservedBase
						if v and v > 0 then
							local g = sk.socketGroup
							out[#out+1] = { skill = sk.activeEffect.grantedEffect.name, spirit = v, group = g and g.label or g and g.displayLabel, slot = g and g.slot, enabled = g and g.enabled, mult = sk.skillModList:More(sk.skillCfg, "ReservationMultiplier") }
						end
					end
					local bd = env and env.player.breakdown and env.player.breakdown.SpiritReserved
					local rows = {}
					for _, r0 in ipairs(bd and bd.reservations or {}) do rows[#rows+1] = r0 end
					return { breakdown = rows, reservations = out, spirit = build.calcsTab.mainOutput.Spirit, unreserved = build.calcsTab.mainOutput.SpiritUnreserved }
				elseif r.op == "contrib" then
					return contrib(r.parts)
				elseif r.op == "supportOptions" then
					return supportOptions(r.group, r.names)
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
				elseif r.op == "tree" then
					-- the whole passive tree as PoB holds it (same ids, same paths), plus what is allocated now
					local spec = build.spec
					local out = { alloc = treeAlloc() }
					if r.layout then
						local nodes, groups = {}, {}
						local ascStart = {}
						for id, n in pairs(spec.nodes) do if n.type == "AscendClassStart" and n.ascendancyName then ascStart[n.ascendancyName] = n end end
						for id, n in pairs(spec.nodes) do
							if n.x and n.type ~= "OnlyImage" and n.group then
								local links = {}
								for _, c in ipairs(n.connections or {}) do
									local o = spec.nodes[c.id]
									if o and o.x and (o.ascendancyName == n.ascendancyName) and not n.classesStart and not o.classesStart then
										links[#links+1] = { c.id, c.orbit or 0 }
									end
								end
								local st = ascStart[n.ascendancyName or ""]
								nodes[#nodes+1] = { id = id, x = math.floor(n.x + 0.5), y = math.floor(n.y + 0.5), t = n.type, a = n.ascendancyName,
									g = n.g, o = n.o, gx = n.group and math.floor(n.group.x + 0.5) or nil, gy = n.group and math.floor(n.group.y + 0.5) or nil, dn = n.dn, sd = n.sd, l = links, attr = n.isAttribute or nil,
									cs = n.classesStart, ax = st and math.floor(st.x + 0.5) or nil, ay = st and math.floor(st.y + 0.5) or nil }
							end
						end
						local radii = {}
						for i, r0 in ipairs(spec.tree.orbitRadii or {}) do radii[i] = r0 end
						out.layout = { nodes = nodes, radii = radii, version = spec.treeVersion }
					end
					return out
				elseif r.op == "weaponSet" then
					-- the main weapon: switch PoB's active weapon set; if the main skill is tied to the other set,
					-- move the main skill to the strongest skill of the chosen set
					local want = tonumber(r.set) == 2
					build.itemsTab.activeItemSet.useSecondWeaponSet = want
					build.itemsTab:PopulateSlots()
					build.buildFlag = true
					local list = build.skillsTab.socketGroupList
					local target = want and 2 or 1
					if r.mainGroup and list[r.mainGroup] then
						build.mainSocketGroup = r.mainGroup build.calcsTab.input.skill_number = r.mainGroup
					elseif build.skillsTab:GetSocketGroupWeaponSet(list[build.mainSocketGroup]) ~= target then
						local best, bestD = nil, -1
						for gi, g in ipairs(list) do
							if g.enabled ~= false and build.skillsTab:GetSocketGroupWeaponSet(g) == target then
								build.mainSocketGroup = gi build.calcsTab.input.skill_number = gi build.buildFlag = true H.recalc()
								local d = dpsS(cur())
								if d > bestD then best, bestD = gi, d end
							end
						end
						if best then build.mainSocketGroup = best build.calcsTab.input.skill_number = best end
					end
					build.buildFlag = true
					H.recalc()
					local a = cur()
					return { state = state(), before = before, after = a, delta = H.delta(before, a) }
				elseif r.op == "treeMode" then
					-- where new points go: 0 normal, 1/2 weapon set; which attribute an attribute node takes
					if r.allocMode then build.spec.allocMode = r.allocMode end
					if r.attributeIndex then build.spec.attributeIndex = r.attributeIndex end
					if r.switchAttr then
						build.spec:SwitchAttributeNode(r.switchAttr, r.attributeIndex or build.spec.attributeIndex or 1)
						build.spec:BuildAllDependsAndPaths()
						build.buildFlag = true
						H.recalc()
					end
					return { state = state(), alloc = treeAlloc(), before = before, after = cur(), delta = H.delta(before, cur()) }
				elseif r.op == "treeClick" then
					-- the same as clicking a node in PoB: allocate with its path, or take it out with everything hanging off it
					local n = build.spec.nodes[tonumber(r.id)]
					if not n then error("no node " .. tostring(r.id)) end
					if n.alloc then
						if n.type == "ClassStart" or n.type == "AscendClassStart" then error("시작 지점은 뺄 수 없어요") end
						build.spec:DeallocNode(n)
					else
						if not n.path then error("이어진 길이 없어요") end
						build.spec:AllocNode(n)
					end
					build.buildFlag = true
					H.recalc()
					local a = cur()
					return { state = state(), alloc = treeAlloc(), before = before, after = a, delta = H.delta(before, a), problems = problems(a, before) }
				elseif r.op == "treeHover" then
					-- what a click would do, measured by PoB without changing anything
					local n = build.spec.nodes[tonumber(r.id)]
					if not n then error("no node " .. tostring(r.id)) end
					local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
					local b = stats(baseOut)
					local ov, ids = {}, {}
					if n.alloc then
						ov.removeNodes = {}
						for _, d in ipairs(n.depends or { n }) do ov.removeNodes[d] = true ids[#ids+1] = d.id end
					else
						if not n.path then return { reachable = false } end
						ov.addNodes = {}
						for _, p in ipairs(build.spec:GetEffectiveAllocationPath(n) or n.path) do ov.addNodes[p] = true ids[#ids+1] = p.id end
					end
					local ok, o = pcall(calcFunc, ov, true)
					if not ok then return { error = tostring(o) } end
					local s = stats(o)
					return { remove = n.alloc or false, nodes = ids, dpsPct = pctD(s, b), problems = problems(s, b),
						ehpPct = (b.TotalEHP or 0) ~= 0 and ((s.TotalEHP or 0) - b.TotalEHP) / b.TotalEHP * 100 or nil }
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
