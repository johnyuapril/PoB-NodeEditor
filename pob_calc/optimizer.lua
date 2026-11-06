-- optimizer.lua: greedy coordinate-ascent build search on top of headless PoB.
-- Loaded by driver.lua for requests with "optimize". Every step is scored by PoB's own calculator.
--
-- Search space (each phase picks the best single change, repeats until no gain):
--   supports  : every support gem (normal + lineage) that can support the main skill
--   spirit    : persistent/reservation skills (auras, heralds, buffs) within the Spirit budget
--   ascendancy: ascendancy notables (8 points)
--   tree      : notables/keystones/jewel sockets, ranked by score gain per passive point
--   uniques   : every unique that fits each gear slot (and unique jewels in allocated sockets)
-- Score = DPS x defence factor x penalties (resists, attribute requirements, reservation).

local O = {}

local function num(v) return (type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge) and v or 0 end

function O.run(H, opt)
	local log = {}
	local t0 = os.clock()
	local function note(fmt, ...) log[#log+1] = string.format("%6.1fs ", os.clock() - t0) .. string.format(fmt, ...) end
	local ehpTarget = opt.ehpTarget or 40000
	local ehpWeight = opt.ehpWeight or 1.0
	local useMinion = opt.minion

	local function dpsOf(o)
		local m = o.Minion or {}
		local d = num(o.CombinedDPS)
		if useMinion then d = math.max(d, num(m.CombinedDPS), num(m.TotalDPS)) end
		if opt.dpsStat and num(o[opt.dpsStat]) > 0 then d = num(o[opt.dpsStat]) end
		return d
	end
	local function score(o)
		if not o then return 0, {} end
		local d = dpsOf(o)
		local ehp = num(o.TotalEHP)
		local f = math.min(1, ehp / ehpTarget) ^ ehpWeight
		local pen = 1
		for _, r in ipairs({ "FireResist", "ColdResist", "LightningResist" }) do
			local v = num(o[r])
			if v < 75 then pen = pen * math.max(0.2, 1 - 0.015 * (75 - v)) end
		end
		local chaos = num(o.ChaosResist)
		if chaos < 0 then pen = pen * math.max(0.5, 1 + 0.004 * chaos) end
		for _, a in ipairs({ "Str", "Dex", "Int" }) do
			local need, have = num(o["Req" .. a]), num(o[a])
			if need > have then pen = pen * math.max(0.1, 1 - 0.01 * (need - have)) end
		end
		-- over-reserving is impossible in game: the penalty grows with the deficit, so reserving even more is never "free"
		if o.SpiritUnreserved and num(o.SpiritUnreserved) < 0 then pen = pen * 0.05 / (1 + -num(o.SpiritUnreserved) / 10) end
		if o.ManaUnreserved and num(o.ManaUnreserved) < 0 then pen = pen * 0.2 / (1 + -num(o.ManaUnreserved) / 20) end
		return d * f * pen, { dps = d, ehp = ehp, pen = pen }
	end

	local function fresh()
		H.recalc()
		local calcFunc, base = build.calcsTab:GetMiscCalculator()
		return calcFunc, base
	end
	local function current()
		H.recalc()
		return score(build.calcsTab.mainOutput)
	end

	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	assert(mainGroup, "no main skill group")
	local mainActive = function()
		return mainGroup.displaySkillList and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
	end

	-------------------------------------------------------------------------
	-- Phase: support gems
	-------------------------------------------------------------------------
	local function supportPhase(slots)
		local changed = false
		local gemList = mainGroup.gemList
		local function supportCount()
			local n = 0
			for _, g in ipairs(gemList) do if g.gemData and g.gemData.grantedEffect.support then n = n + 1 end end
			return n
		end
		local function have(gemData)
			for _, g in ipairs(gemList) do if g.gemData == gemData or (g.gemData and g.gemData.name == gemData.name) then return true end end
			return false
		end
		local function makeInst(gemData)
			return { level = gemData.naturalMaxLevel or 20, quality = 0, count = 1, enabled = true, enableGlobal1 = true, enableGlobal2 = true,
				gemId = gemData.id, nameSpec = gemData.name, skillId = gemData.grantedEffectId, gemData = gemData }
		end
		local function candidates()
			local act = mainActive()
			local list = {}
			if not act then return list end
			for _, gemData in pairs(build.data.gems) do
				local ge = gemData.grantedEffect
				if ge and ge.support and not ge.legacy and not ge.fromItem and not have(gemData)
					and calcLib.canGrantedEffectSupportActiveSkill(ge, act) then
					list[#list+1] = gemData
				end
			end
			return list
		end
		-- try one swap/add: returns score
		local function tryGem(calcFunc, idx, gemData)
			local old = gemList[idx]
			gemList[idx] = makeInst(gemData)
			local ok, out = pcall(calcFunc, nil, false)
			gemList[idx] = old
			if not ok then return 0 end
			return (score(out))
		end
		-- 1) fill empty slots greedily
		while supportCount() < slots do
			local calcFunc = fresh()
			local cur = current()
			local best, bestS = nil, -1   -- always fill: a gem that only pays off with others is fixed by the swap/drop passes
			local cl = candidates()
			local top = {}
			for _, gd in ipairs(cl) do
				local s = tryGem(calcFunc, #gemList + 1, gd)
				top[#top+1] = { gd.name, s }
				if s > bestS then best, bestS = gd, s end
			end
			if opt.debug then
				table.sort(top, function(a, b) return a[2] > b[2] end)
				local t = {}
				for i = 1, math.min(6, #top) do t[#t+1] = top[i][1] .. "=" .. string.format("%.0f", top[i][2]) end
				note("  %d candidates, cur %.0f, top: %s", #cl, cur, table.concat(t, ", "))
			end
			if not best then break end
			table.insert(gemList, makeInst(best))
			build.skillsTab:ProcessSocketGroup(mainGroup)
			note("support +%s  score %.0f -> %.0f", best.name, cur, bestS)
			changed = true
		end
		-- 2) try replacing each support with a better one
		local improved = true
		local rounds = 0
		while improved and rounds < 3 do
			improved, rounds = false, rounds + 1
			for idx = 1, #gemList do
				local g = gemList[idx]
				if g.gemData and g.gemData.grantedEffect.support then
					local calcFunc = fresh()
					local cur = current()
					local best, bestS = nil, cur * 1.002
					for _, gd in ipairs(candidates()) do
						local s = tryGem(calcFunc, idx, gd)
						if s > bestS then best, bestS = gd, s end
					end
					if best then
						note("support %s -> %s  score %.0f -> %.0f", g.nameSpec, best.name, cur, bestS)
						gemList[idx] = makeInst(best)
						build.skillsTab:ProcessSocketGroup(mainGroup)
						improved, changed = true, true
					end
				end
			end
		end
		-- 3) drop supports that hurt (e.g. lineage gems that want few supports)
		for idx = #gemList, 1, -1 do
			local g = gemList[idx]
			if g.gemData and g.gemData.grantedEffect.support then
				local cur = current()
				g.enabled = false
				build.skillsTab:ProcessSocketGroup(mainGroup)
				local s = current()
				if s > cur * 1.002 then
					note("support -%s  score %.0f -> %.0f", g.nameSpec, cur, s)
					table.remove(gemList, idx)
					changed = true
				else
					g.enabled = true
				end
				build.skillsTab:ProcessSocketGroup(mainGroup)
			end
		end
		H.recalc()
		return changed
	end

	-------------------------------------------------------------------------
	-- Phase: spirit / persistent buff skills (each as its own group)
	-------------------------------------------------------------------------
	local spiritGroups = {}
	local function spiritPhase()
		if opt.noSpirit then return false end
		local changed = false
		local tried = {}
		for _ = 1, opt.maxSpiritSkills or 4 do
			local cur = current()
			local cands = {}
			for _, gemData in pairs(build.data.gems) do
				local ge = gemData.grantedEffect
				if ge and not ge.support and not ge.legacy and not ge.fromItem and ge.skillTypes
					and (ge.skillTypes[SkillType.Persistent] or ge.skillTypes[SkillType.HasReservation])
					and not ge.skillTypes[SkillType.Meta] and not ge.minionList and not tried[gemData.name] then
					local used = false
					for _, g in ipairs(build.skillsTab.socketGroupList) do
						for _, gem in ipairs(g.gemList or {}) do if gem.nameSpec == gemData.name then used = true end end
					end
					if not used then cands[#cands+1] = gemData end
				end
			end
			local best, bestS = nil, cur * 1.005
			for _, gd in ipairs(cands) do
				local grp = { label = "opt:" .. gd.name, enabled = true, gemList = { { level = gd.naturalMaxLevel or 20, quality = 0, count = 1, enabled = true,
					enableGlobal1 = true, enableGlobal2 = true, gemId = gd.id, nameSpec = gd.name, skillId = gd.grantedEffectId, gemData = gd } } }
				table.insert(build.skillsTab.socketGroupList, grp)
				build.skillsTab:ProcessSocketGroup(grp)
				local ok = pcall(H.recalc)
				local mo = build.calcsTab.mainOutput or {}
				local s = ok and score(mo) or 0
				if num(mo.SpiritUnreserved) < 0 then s = 0 end   -- hard limit: a spirit skill you cannot afford is never added
				for gi = #build.skillsTab.socketGroupList, 1, -1 do
					if build.skillsTab.socketGroupList[gi] == grp then table.remove(build.skillsTab.socketGroupList, gi) break end
				end
				if s > bestS then best, bestS = gd, s end
			end
			if not best then break end
			tried[best.name] = true
			local grp = { label = "opt:" .. best.name, enabled = true, gemList = { { level = best.naturalMaxLevel or 20, quality = 0, count = 1, enabled = true,
				enableGlobal1 = true, enableGlobal2 = true, gemId = best.id, nameSpec = best.name, skillId = best.grantedEffectId, gemData = best } } }
			table.insert(build.skillsTab.socketGroupList, grp)
			build.skillsTab:ProcessSocketGroup(grp)
			spiritGroups[#spiritGroups+1] = grp
			note("spirit +%s  score %.0f -> %.0f", best.name, cur, bestS)
			changed = true
		end
		H.recalc()
		return changed
	end

	-------------------------------------------------------------------------
	-- Phase: passive nodes (ascendancy or main tree)
	-------------------------------------------------------------------------
	local function pathCost(n)
		local c = 0
		for _, p in ipairs(n.path or {}) do if not p.alloc then c = c + 1 end end
		return math.max(c, 1)
	end
	local function ascUsed()
		local n = 0
		for _, node in pairs(build.spec.allocNodes) do
			if node.ascendancyName and not node.isAscendancyStart and node.type ~= "AscendClassStart" then n = n + 1 end
		end
		return n
	end
	local function treeUsed()
		local used = build.spec:CountAllocNodes()
		return used
	end
	O.ascUsed = ascUsed
	local function nodePhase(isAsc, budget)
		local changed = false
		local spec = build.spec
		for _ = 1, 200 do
			local used = isAsc and ascUsed() or treeUsed()
			if used >= budget then break end
			local calcFunc = fresh()
			local cur = current()
			if cur <= 0 then cur = 1e-9 end
			local best, bestGain, bestS = nil, 0, cur
			for _, n in pairs(spec.nodes) do
				if not n.alloc and n.path and n.modKey ~= "" then
					local ok
					if isAsc then
						ok = n.ascendancyName and spec.curAscendClass and n.ascendancyName == spec.curAscendClass.name and not n.isAscendancyStart
							and (n.type == "Notable" or n.type == "Normal")
					else
						ok = not n.ascendancyName and (n.type == "Notable" or n.type == "Keystone" or n.type == "Socket" or (opt.smallNodes and n.type == "Normal"))
							and #n.path <= (opt.maxDistance or 7)
					end
					if ok then
						local cost = pathCost(n)
						if used + cost <= budget then
							local add = {}
							for _, p in ipairs(n.path) do add[p] = true end
							local okc, out = pcall(calcFunc, { addNodes = add }, false)
							if okc and out then
								local s = score(out)
								local gain = (s > 0 and math.log(s / cur) or -1) / cost
								if n.type == "Socket" then gain = gain + (opt.socketBonus or 0.004) / cost end
								if gain > bestGain then best, bestGain, bestS = n, gain, s end
							end
						end
					end
				end
			end
			if not best then break end
			local bc = pathCost(best)
			spec:AllocNode(best)
			note("%s +%s (%s, %d pts, used %d/%d)  score %.0f -> %.0f", isAsc and "asc" or "tree", tostring(best.dn), best.type, bc, (isAsc and ascUsed() or treeUsed()), budget, cur, bestS)
			changed = true
		end
		H.recalc()
		return changed
	end

	-- Ascendancy: exhaustive search over sets of up to 4 notables that fit the point budget
	local function ascSubsetPhase(budget)
		local spec = build.spec
		if not spec.curAscendClass then return false end
		local notables = {}
		for _, n in pairs(spec.nodes) do
			if n.ascendancyName == spec.curAscendClass.name and n.type == "Notable" and not n.alloc and n.path and n.modKey ~= "" then
				notables[#notables+1] = n
			end
		end
		table.sort(notables, function(a, b) return a.id < b.id end)
		local used = ascUsed()
		local calcFunc = fresh()
		local cur = current()
		local best, bestS = nil, cur * 1.001
		local maxK = #notables > 12 and 3 or 4
		local count = 0
		local function eval(set)
			local add, cost = {}, 0
			for _, n in ipairs(set) do
				for _, p in ipairs(n.path) do if not p.alloc and not add[p] then add[p] = true cost = cost + 1 end end
			end
			if used + cost > budget then return false end
			count = count + 1
			local okc, out = pcall(calcFunc, { addNodes = add }, false)
			if okc and out then
				local sc = score(out)
				if sc > bestS then
					best, bestS = {}, sc
					for i, n in ipairs(set) do best[i] = n end
				end
			end
			return true
		end
		local set = {}
		local function rec(start, depth)
			for i = start, #notables do
				set[depth] = notables[i]
				if eval(set) and depth < maxK then rec(i + 1, depth + 1) end
				set[depth] = nil
			end
		end
		rec(1, 1)
		if not best then return false end
		local names = {}
		for _, n in ipairs(best) do
			if not n.alloc then spec:AllocNode(n) end
			names[#names+1] = n.dn
		end
		note("asc set {%s} (%d sets tried)  score %.0f -> %.0f", table.concat(names, ", "), count, cur, bestS)
		H.recalc()
		return true
	end

	-- Weapon / off-hand variants supplied by the caller (rare templates), evaluated with PoB's item override
	local function weaponPhase()
		local changed = false
		for slotName, raws in pairs(opt.weaponVariants or {}) do
			if build.itemsTab.slots[slotName] then
				local calcFunc = fresh()
				local cur = current()
				if opt.debug then
					local okb, ob = pcall(calcFunc, nil, false)
					note("  weapon check %s: current %.0f, calcFunc(nil) %.0f", slotName, cur, okb and (score(ob)) or -1)
				end
				local best, bestS, bestRaw = nil, cur * 1.001, nil
				for _, raw in ipairs(raws) do
					local okI, item = pcall(function() local it = new("Item"):Item(raw) it:NormaliseQuality() it:BuildModList() return it end)
					if okI and item then
						local okc, out = pcall(calcFunc, { repSlotName = slotName, repItem = item }, false)
						if okc and out then
							local sc = score(out)
							if sc > bestS then best, bestS, bestRaw = item, sc, raw end
						end
					end
				end
				if best then
					local newItem = new("Item"):Item(bestRaw)
					newItem:NormaliseQuality()
					build.itemsTab:AddItem(newItem, true)
					build.itemsTab.slots[slotName]:SetSelItemId(newItem.id)
					build.itemsTab:PopulateSlots()
					build.buildFlag = true
					note("weapon %s: %s  score %.0f -> %.0f", slotName, bestRaw:match("^[^\n]*\n([^\n]*)") or "?", cur, bestS)
					changed = true
				end
			end
		end
		H.recalc()
		return changed
	end

	-------------------------------------------------------------------------
	-- Phase: unique items
	-------------------------------------------------------------------------
	local GEAR = { "Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring 1", "Ring 2", "Belt" }
	if opt.uniqueWeapons then table.insert(GEAR, 1, "Weapon 1") table.insert(GEAR, 2, "Weapon 2") end
	local function slotOf(item)
		local s = item:GetPrimarySlot()
		return s
	end
	local function uniquesFor(slotName)
		local list = {}
		for _, item in pairs(main.uniqueDB.list) do
			local p = slotOf(item)
			local fits = (p == slotName) or (slotName == "Ring 2" and p == "Ring 1") or (slotName:match("^Jewel") and item.type == "Jewel")
			if fits and not (opt.excludeUniques and opt.excludeUniques[item.name]) then list[#list+1] = item end
		end
		return list
	end
	local function equip(slotName, item)
		local raw = item:BuildRaw()
		local newItem = new("Item"):Item(raw)
		newItem:NormaliseQuality()
		build.itemsTab:AddItem(newItem, true)
		local slot = build.itemsTab.slots[slotName]
		slot:SetSelItemId(newItem.id)
		build.itemsTab:PopulateSlots()
		build.buildFlag = true
		return newItem
	end
	local function uniquePhase()
		local changed = false
		local slots = {}
		for _, s in ipairs(GEAR) do slots[#slots+1] = s end
		if not opt.noJewels then
			for _, slot in ipairs(build.itemsTab.orderedSlots) do
				if slot.nodeId and build.spec.allocNodes[slot.nodeId] then slots[#slots+1] = slot.slotName end
			end
		end
		local usedNames = {}
		for _, slot in ipairs(build.itemsTab.orderedSlots) do
			local it = build.itemsTab.items[slot.selItemId]
			if it and it.rarity == "UNIQUE" then usedNames[it.name] = true end
		end
		for _, slotName in ipairs(slots) do
			if build.itemsTab.slots[slotName] then
				local calcFunc = fresh()
				local cur = current()
				local best, bestS = nil, cur * 1.003
				for _, item in ipairs(uniquesFor(slotName)) do
					if not usedNames[item.name] then
						local okc, out = pcall(calcFunc, { repSlotName = slotName, repItem = item }, false)
						if okc and out then
							local s = score(out)
							if s > bestS then best, bestS = item, s end
						end
					end
				end
				if best then
					local old = build.itemsTab.items[build.itemsTab.slots[slotName].selItemId]
					if old and old.rarity == "UNIQUE" then usedNames[old.name] = nil end
					equip(slotName, best)
					usedNames[best.name] = true
					note("unique %s: %s  score %.0f -> %.0f", slotName, best.name, cur, bestS)
					changed = true
				end
			end
		end
		H.recalc()
		return changed
	end

	-------------------------------------------------------------------------
	-- Phase: craft rare items from the real affix pools (best tier of each mod group the base can roll)
	-------------------------------------------------------------------------
	local function affixPool(item)
		local bestByGroup = {}
		local ilvl = opt.itemLevel or 82
		for id, mod in pairs(item.affixes or {}) do
			if (mod.type == "Prefix" or mod.type == "Suffix") and (mod.level or 1) <= ilvl and item:GetModSpawnWeight(mod) > 0 then
				local g = mod.group or id
				if not bestByGroup[g] or (mod.level or 0) > (bestByGroup[g].level or 0) then bestByGroup[g] = mod end
			end
		end
		local pool = {}
		for g, mod in pairs(bestByGroup) do
			local lines = {}
			for i = 1, 4 do
				if mod[i] then lines[#lines+1] = itemLib.applyRange(mod[i], 1.0) end
			end
			if #lines > 0 then pool[#pool+1] = { type = mod.type, group = g, text = table.concat(lines, "\n") } end
		end
		table.sort(pool, function(a, b) return a.group < b.group end)
		return pool
	end
	local function craftRaw(name, baseName, mods)
		local lines = { "Rarity: RARE", name, baseName, "Item Level: " .. (opt.itemLevel or 82), "Quality: 20" }
		for _, m in ipairs(mods) do lines[#lines+1] = m.text end
		return table.concat(lines, "\n")
	end
	local function craftSlot(slotName, baseName, maxPre, maxSuf)
		local probe = new("Item"):Item("Rarity: RARE\nProbe\n" .. baseName)
		if not probe.base then return false end
		local pool = affixPool(probe)
		if #pool == 0 then return false end
		local calcFunc = fresh()
		local cur = current()
		local chosen = {}
		local function counts()
			local p, sfx = 0, 0
			for _, m in ipairs(chosen) do if m.type == "Prefix" then p = p + 1 else sfx = sfx + 1 end end
			return p, sfx
		end
		local function evalMods(mods)
			local okI, it = pcall(function() local x = new("Item"):Item(craftRaw("Crafted " .. slotName, baseName, mods)) x:NormaliseQuality() x:BuildModList() return x end)
			if not okI or not it then return 0 end
			local okc, out = pcall(calcFunc, { repSlotName = slotName, repItem = it }, false)
			return okc and out and (score(out)) or 0
		end
		local function inChosen(m) for _, c in ipairs(chosen) do if c.group == m.group then return true end end return false end
		-- greedy fill
		for _ = 1, maxPre + maxSuf do
			local p, sfx = counts()
			local best, bestS = nil, -1
			for _, m in ipairs(pool) do
				if not inChosen(m) and ((m.type == "Prefix" and p < maxPre) or (m.type == "Suffix" and sfx < maxSuf)) then
					chosen[#chosen+1] = m
					local sc = evalMods(chosen)
					chosen[#chosen] = nil
					if sc > bestS then best, bestS = m, sc end
				end
			end
			if not best then break end
			chosen[#chosen+1] = best
		end
		-- one swap pass
		for i = 1, #chosen do
			local keep = chosen[i]
			local bestS = evalMods(chosen)
			for _, m in ipairs(pool) do
				if m.type == keep.type and not inChosen(m) then
					chosen[i] = m
					local sc = evalMods(chosen)
					if sc > bestS * 1.001 then bestS, keep = sc, m end
				end
			end
			chosen[i] = keep
		end
		local finalS = evalMods(chosen)
		if finalS > cur * 1.001 then
			local newItem = new("Item"):Item(craftRaw("Crafted " .. slotName, baseName, chosen))
			newItem:NormaliseQuality()
			build.itemsTab:AddItem(newItem, true)
			build.itemsTab.slots[slotName]:SetSelItemId(newItem.id)
			build.itemsTab:PopulateSlots()
			build.buildFlag = true
			local names = {}
			for _, m in ipairs(chosen) do names[#names+1] = (m.text:gsub("\n", " / ")) end
			note("craft %s (%s): %s  score %.0f -> %.0f", slotName, baseName, table.concat(names, "; "), cur, finalS)
			H.recalc()
			return true
		end
		return false
	end
	local function craftPhase()
		local changed = false
		local slots = opt.craftSlots or { "Weapon 1", "Weapon 2", "Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring 1", "Ring 2", "Belt" }
		for _, slotName in ipairs(slots) do
			local slot = build.itemsTab.slots[slotName]
			local it = slot and build.itemsTab.items[slot.selItemId]
			if it and it.rarity ~= "UNIQUE" and it.base then
				local ok, res = pcall(craftSlot, slotName, it.baseName, opt.maxPrefix or 3, opt.maxSuffix or 3)
				if not ok then note("craft %s failed: %s", slotName, tostring(res)) elseif res then changed = true end
			end
		end
		-- rare jewels in allocated empty/rare sockets
		if not opt.noJewels then
			for _, slot in ipairs(build.itemsTab.orderedSlots) do
				if slot.nodeId and build.spec.allocNodes[slot.nodeId] then
					local it = build.itemsTab.items[slot.selItemId]
					if not it or it.rarity ~= "UNIQUE" then
						local bestRes = false
						for _, b in ipairs(opt.jewelBases or { "Ruby", "Emerald", "Sapphire" }) do
							local ok, res = pcall(craftSlot, slot.slotName, b, 2, 2)
							if ok and res then bestRes = true end
						end
						changed = changed or bestRes
					end
				end
			end
		end
		return changed
	end

	-------------------------------------------------------------------------
	-- Main loop
	-------------------------------------------------------------------------
	local phases = opt.phases or { "weapons", "supports", "spirit", "ascendancy", "tree", "uniques" }
	local s0, p0 = current()
	do
		local o = build.calcsTab.mainOutput
		note("start score %.0f dps %.0f ehp %.0f pen %.3f res %s/%s/%s chaos %s str %s/%s dex %s/%s int %s/%s spirit %s mana %s", s0, p0.dps or 0, p0.ehp or 0, p0.pen or 0,
			tostring(o.FireResist), tostring(o.ColdResist), tostring(o.LightningResist), tostring(o.ChaosResist), tostring(o.Str), tostring(o.ReqStr), tostring(o.Dex), tostring(o.ReqDex), tostring(o.Int), tostring(o.ReqInt), tostring(o.SpiritUnreserved), tostring(o.ManaUnreserved))
	end
	for iter = 1, opt.iterations or 2 do
		local any = false
		for _, ph in ipairs(phases) do
			local ok, res = pcall(function()
				if ph == "supports" then return supportPhase(opt.supportSlots or 5)
				elseif ph == "spirit" then return spiritPhase()
				elseif ph == "ascendancy" then return ascSubsetPhase(opt.ascPoints or 8)
				elseif ph == "ascendancyGreedy" then return nodePhase(true, opt.ascPoints or 8)
				elseif ph == "weapons" then return weaponPhase()
				elseif ph == "tree" then return nodePhase(false, opt.points or 123)
				elseif ph == "uniques" then return uniquePhase()
				elseif ph == "craft" then return craftPhase()
				end
			end)
			if not ok then note("phase %s failed: %s", ph, tostring(res)) elseif res then any = true end
		end
		note("iteration %d score %.0f", iter, (current()))
		if not any then break end
	end
	local final, parts = current()
	return { startScore = s0, score = final, dps = parts.dps, ehp = parts.ehp, penalty = parts.pen, log = log, seconds = os.clock() - t0 }
end

return O
