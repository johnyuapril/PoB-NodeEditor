-- Detailed build mechanics, read straight out of PoB's own calculation of the loaded build.
--   formula : how the main skill's hit is put together. For each factor (increased / more damage, crit chance,
--             crit damage, speed, penetration, gain-as / conversion, projectiles) the total and every source
--             with its evaluated value, its condition tags, and roughly how much damage that one line is worth.
--   mechs   : for each assumed condition the client sends, the PoB conditions / multipliers it drives
--             (diffed with it on and off), every mod in the build gated or scaled by them with source and value,
--             and the sources of its maximum (max charges, max rage).
--   curves  : damage at each stack count of charges / rage, so the value of one more stack is visible.
local lineMap
return function(H, build, r, helpers)
	local cur, pctD = helpers.cur, helpers.pctD
	local tab = build.configTab
	local spec = build.spec

	local function srcInfo(s)
		s = tostring(s or "")
		local kind, rest = s:match("^([^:]+):?(.*)$")
		local o = { raw = s, kind = kind }
		if kind == "Tree" then
			local id = tonumber(rest:match("^(%d+)"))
			local n = id and spec.nodes[id]
			o.id = id
			o.name = n and n.dn or rest
			o.nodeType = n and n.type
		elseif kind == "Item" then
			local id, nm = rest:match("^(%d+):(.*)$")
			o.id = tonumber(id)
			local it = o.id and build.itemsTab.items[o.id]
			o.name = it and it.title or it and it.name or nm or rest
			o.rarity = it and it.rarity
			o.base = it and it.baseName
		elseif kind == "Skill" then
			local gd = build.data.skills[rest]
			o.id = rest
			o.name = gd and gd.name or rest
			o.support = gd and gd.support or nil
		else
			o.name = rest ~= "" and rest or kind
		end
		return o
	end
	local function tagsOf(mod)
		local t = {}
		for _, tag in ipairs(mod) do
			local x = { type = tag.type }
			for _, k in ipairs({ "var", "stat", "threshold", "div", "limit", "actor", "neg", "skillType", "skillName", "keyword", "effectType", "percent", "upper" }) do
				local v = tag[k]
				if v ~= nil and type(v) ~= "table" and type(v) ~= "function" then x[k] = v end
			end
			if tag.varList then x.varList = {} for _, v in ipairs(tag.varList) do x.varList[#x.varList+1] = tostring(v) end end
			if tag.skillTypeList then x.n = #tag.skillTypeList end
			t[#t+1] = x
		end
		return t
	end
	local function modRow(e, mod)
		local v = e and e.value or mod.value
		return { name = mod.name, type = mod.type, value = type(v) == "number" and v or nil, base = type(mod.value) == "number" and mod.value or nil,
			flag = type(v) == "boolean" and v or nil, src = srcInfo(mod.source), tags = tagsOf(mod), flags = mod.flags, kw = mod.keywordFlags }
	end

	H.recalc()
	local env = build.calcsTab.mainEnv
	local actor = env.player
	local skill = actor.mainSkill
	if not skill then return { ok = false, error = "no main skill" } end
	local cfg = skill.skillCfg
	local ml = skill.skillModList
	local out = actor.output or {}

	------------------------------------------------------------------ the hit formula
	local TYPES = { "Physical", "Lightning", "Cold", "Fire", "Chaos" }
	local used = {}
	for _, t in ipairs(TYPES) do
		local v = out[t .. "HitAverage"]
		if type(v) ~= "number" and out.MainHand then v = out.MainHand[t .. "HitAverage"] end
		if type(v) == "number" and v > 0 then used[t] = v end
	end
	local hitTot = 0 for _, v in pairs(used) do hitTot = hitTot + v end
	-- share of the final hit a damage-type line touches (Cold damage only scales the cold part, Elemental the three)
	local function shareOf(name)
		if hitTot <= 0 then return 1 end
		if name == "Damage" then return 1 end
		if name == "ElementalDamage" then return ((used.Fire or 0) + (used.Cold or 0) + (used.Lightning or 0)) / hitTot end
		local t = name:match("^(%a-)Damage$")
		if t and used[t] ~= nil then return used[t] / hitTot end
		if t then for _, x in ipairs(TYPES) do if x == t then return 0 end end end
		return 1
	end
	local DMG = { "Damage", "PhysicalDamage", "LightningDamage", "ColdDamage", "FireDamage", "ChaosDamage", "ElementalDamage" }
	local function group(key, modType, names, mode)
		local list = ml:Tabulate(modType, cfg, unpack(names))
		local rows, tot = {}, (mode == "more") and 1 or 0
		for _, e in ipairs(list) do
			if type(e.value) == "number" then
				local row = modRow(e, e.mod)
				row.share = shareOf(e.mod.name)
				rows[#rows+1] = row
				if mode == "more" then tot = tot * (1 + e.value / 100) else tot = tot + e.value end
			end
		end
		-- worth of each line: roughly what the hit loses without it, the others held fixed (per damage type it touches)
		local function applies(name, t)
			if name == "Damage" then return true end
			if name == "ElementalDamage" then return t == "Fire" or t == "Cold" or t == "Lightning" end
			return name == t .. "Damage"
		end
		local pool = {}
		if mode == "inc" then
			for t in pairs(used) do pool[t] = 0 for _, x in ipairs(rows) do if applies(x.name, t) then pool[t] = pool[t] + x.value end end end
		end
		for _, row in ipairs(rows) do
			local v = row.value
			local w
			if mode == "inc" and key == "incDamage" and hitTot > 0 then
				w = 0
				for t, hv in pairs(used) do if applies(row.name, t) then w = w - (hv / hitTot) * v / (100 + pool[t]) end end
			elseif mode == "inc" then
				w = -(v / (100 + tot))
			elseif mode == "more" then
				w = ((1 / (1 + v / 100)) - 1) * (row.share or 1)
			end
			row.worth = w and w * 100 or nil
		end
		table.sort(rows, function(a, b) return math.abs(a.worth or a.value or 0) > math.abs(b.worth or b.value or 0) end)
		return { key = key, type = modType, total = tot, rows = rows }
	end
	local formula = {
		group("incDamage", "INC", DMG, "inc"),
		group("moreDamage", "MORE", DMG, "more"),
		group("critChance", "INC", { "CritChance" }, "inc"),
		group("critChanceBase", "BASE", { "CritChance" }, "sum"),
		group("critMulti", "BASE", { "CritMultiplier" }, "sum"),
		group("critMultiInc", "INC", { "CritMultiplier" }, "inc"),
		group("speed", "INC", { "Speed" }, "inc"),
		group("speedMore", "MORE", { "Speed" }, "more"),
		group("pen", "BASE", { "ElementalPenetration", "ColdPenetration", "FirePenetration", "LightningPenetration", "ChaosPenetration" }, "sum"),
		group("projectiles", "BASE", { "ProjectileCount" }, "sum"),
	}
	-- conversion and gain-as lines are many differently named mods: scan everything the skill sees
	local conv = { key = "conversion", rows = {} }
	local seen = {}
	local function scanList(list)
		for _, mod in ipairs(list) do
			if (mod.name:match("GainAs") or mod.name:match("ConvertTo")) and not seen[mod] then
				seen[mod] = true
				local v = mod[1] and ml:EvalMod(mod, cfg) or mod.value
				if type(v) == "number" and v ~= 0 then local row = modRow({ value = v }, mod) conv.rows[#conv.rows+1] = row end
			end
		end
	end
	scanList(ml)
	for name, list in pairs(actor.modDB.mods) do if name:match("GainAs") or name:match("ConvertTo") then scanList(list) end end
	formula[#formula+1] = conv
	local outKeys = {}
	for _, k in ipairs({ "CritChance", "CritMultiplier", "CritEffect", "Speed", "HitChance", "AverageHit", "AverageDamage", "TotalDPS", "CombinedDPS", "ProjectileCount",
		"ColdEffMult", "FireEffMult", "LightningEffMult", "PhysicalEffMult", "ChaosEffMult", "EnemyColdResist", "EnemyFireResist", "EnemyLightningResist", "DoubleDamageChance", "ScaledDamageEffect" }) do
		local v = out[k]
		if type(v) ~= "number" and out.MainHand then v = out.MainHand[k] end
		if type(v) == "number" and v == v and v ~= math.huge then outKeys[k] = v end
	end

	------------------------------------------------------------------ conditions → what they drive
	-- every var any mod's tags refer to, read through PoB's own GetCondition / GetMultiplier (so vars a config
	-- writes as a Condition:X flag or Multiplier:X mod count too, not only the raw tables)
	local function tagVars(db, set)
		local function add(mod) for _, tag in ipairs(mod) do
			if tag.var then set[tag.var] = set[tag.var] or tag.type end
			if tag.varList then for _, v in ipairs(tag.varList) do set[v] = set[v] or tag.type end end
		end end
		for _, list in pairs(db.mods or {}) do for _, mod in ipairs(list) do add(mod) end end
	end
	local function snapVars()
		local e = build.calcsTab.mainEnv
		local sk = e.player.mainSkill
		local s = { cond = {}, mult = {}, econd = {}, emult = {} }
		local function read(db, cfgx, set, C, M)
			for v in pairs(set) do
				local okc, c = pcall(db.GetCondition, db, v, cfgx)
				if okc and c then C[v] = true end
				local okm, m = pcall(db.GetMultiplier, db, v, cfgx)
				if okm and type(m) == "number" and m ~= 0 then M[v] = m end
			end
		end
		local pv, ev = {}, {}
		tagVars(e.player.modDB, pv)
		for _, mod in ipairs(sk.skillModList) do for _, tag in ipairs(mod) do if tag.var then pv[tag.var] = true end if tag.varList then for _, v in ipairs(tag.varList) do pv[v] = true end end end end
		for k in pairs(e.player.modDB.conditions or {}) do pv[k] = true end
		for k in pairs(e.player.modDB.multipliers or {}) do pv[k] = true end
		read(sk.skillModList, sk.skillCfg, pv, s.cond, s.mult)
		if e.enemy then
			tagVars(e.enemy.modDB, ev)
			for k in pairs(e.enemy.modDB.conditions or {}) do ev[k] = true end
			for k in pairs(e.enemy.modDB.multipliers or {}) do ev[k] = true end
			for k in pairs(pv) do ev[k] = true end   -- ActorCondition:enemy tags live on player mods
			read(e.enemy.modDB, nil, ev, s.econd, s.emult)
		end
		return s
	end
	local function refersTo(mod, vars)
		for _, tag in ipairs(mod) do
			if tag.var and vars[tag.var] then return true end
			if tag.varList then for _, v in ipairs(tag.varList) do if vars[v] then return true end end end
		end
		return false
	end
	-- each formula line keyed by what it is (name, type, source, unevaluated value), with its evaluated value now
	local LINES = { { "incDamage", "INC", DMG }, { "moreDamage", "MORE", DMG }, { "critChance", "INC", { "CritChance" } }, { "critChanceBase", "BASE", { "CritChance" } },
		{ "critMultiInc", "INC", { "CritMultiplier" } }, { "critMulti", "BASE", { "CritMultiplier" } }, { "speed", "INC", { "Speed" } }, { "speedMore", "MORE", { "Speed" } },
		{ "pen", "BASE", { "ElementalPenetration", "ColdPenetration", "FirePenetration", "LightningPenetration", "ChaosPenetration" } } }
	function lineMap()
		local e = build.calcsTab.mainEnv
		local sk = e.player.mainSkill
		local m = {}
		if not sk then return m end
		for _, L in ipairs(LINES) do
			for _, x in ipairs(sk.skillModList:Tabulate(L[2], sk.skillCfg, unpack(L[3]))) do
				if type(x.value) == "number" then
					local k = L[1] .. "|" .. x.mod.name .. "|" .. x.mod.type .. "|" .. tostring(x.mod.source) .. "|" .. tostring(x.mod.value)
					local prev = m[k]
					m[k] = { value = (prev and prev.value or 0) + x.value, mod = x.mod, group = L[1] }
				end
			end
		end
		return m
	end
	local onLines = lineMap()
	local on = snapVars()
	local base = cur()
	local mechs = {}
	for i, c in ipairs(r.conds or {}) do
		local saved = {}
		for k in pairs(c.config or {}) do saved[k] = { v = tab.input[k] } end
		H.applyConfig(c.config)
		H.recalc()
		local off = snapVars()
		local offStats = cur()
		local offLines = lineMap()
		for k, sv in pairs(saved) do tab.input[k] = sv.v end
		tab:BuildModList() build.buildFlag = true
		H.recalc()
		local vars, changed = {}, {}
		for _, part in ipairs({ { "cond", "player", "조건" }, { "mult", "player", "수치" }, { "econd", "enemy", "조건" }, { "emult", "enemy", "수치" } }) do
			local A, B = on[part[1]], off[part[1]]
			local keys = {}
			for k in pairs(A) do keys[k] = true end
			for k in pairs(B) do keys[k] = true end
			for k in pairs(keys) do
				if A[k] ~= B[k] then
					vars[k] = true
					changed[#changed+1] = { var = k, actor = part[2], kind = part[1]:match("cond") and "condition" or "multiplier", on = A[k], off = B[k] }
				end
			end
		end
		-- also the condition names the config writes directly (Condition:X flags that only live as mods)
		for k in pairs(c.vars or {}) do vars[k] = true end
		local env2 = build.calcsTab.mainEnv
		local sk2 = env2.player.mainSkill
		local ml2, cfg2 = sk2.skillModList, sk2.skillCfg
		local rows, seenM = {}, {}
		local function scan(list, actorName, db)
			for _, mod in ipairs(list) do
				if not seenM[mod] and mod[1] and refersTo(mod, vars) then
					seenM[mod] = true
					local okE, v = pcall(db.EvalMod, db, mod, cfg2)
					local row = modRow({ value = okE and v or nil }, mod)
					row.actor = actorName
					row.active = okE and v ~= nil and v ~= 0 and v ~= false
					rows[#rows+1] = row
				end
			end
		end
		-- the skill's list sits on its base list, which sits on the player's modDB: walk the whole chain
		local node = ml2
		while node do
			if node.mods then for _, list in pairs(node.mods) do scan(list, "player", ml2) end else scan(node, "player", ml2) end
			node = node.parent
		end
		if env2.enemy then for _, list in pairs(env2.enemy.modDB.mods) do scan(list, "enemy", env2.enemy.modDB) end end
		table.sort(rows, function(a, b) return (a.active and 1 or 0) > (b.active and 1 or 0) end)
		-- every line of the hit formula whose value moves when the condition goes, including ones PoB computes
		-- without a tag (Rage's own more damage, thresholds on charge counts)
		local lost = {}
		for k, x in pairs(onLines) do
			local y = offLines[k]
			if not y or math.abs((y.value or 0) - (x.value or 0)) > 1e-6 then
				local row = modRow({ value = x.value }, x.mod)
				row.offValue = y and y.value or 0
				row.group = x.group
				lost[#lost+1] = row
			end
		end
		for k, y in pairs(offLines) do if not onLines[k] then local row = modRow({ value = 0 }, y.mod) row.offValue = y.value row.group = y.group lost[#lost+1] = row end end
		table.sort(lost, function(a, b) return math.abs((a.value or 0) - (a.offValue or 0)) > math.abs((b.value or 0) - (b.offValue or 0)) end)
		mechs[i] = { key = c.key, dpsPct = pctD(offStats, base), changed = changed, mods = rows, lost = lost }
	end
	-- where the maximum of each pool comes from
	local maxSrc = {}
	for _, nm in ipairs({ "PowerChargesMax", "FrenzyChargesMax", "EnduranceChargesMax", "MaximumRage", "RageEffect" }) do
		local t = {}
		for _, e in ipairs(actor.modDB:Tabulate(nil, nil, nm)) do if type(e.value) == "number" then t[#t+1] = modRow(e, e.mod) end end
		maxSrc[nm] = t
	end

	------------------------------------------------------------------ stack curves
	local curves = {}
	local POOLS = {
		{ key = "PowerCharge", use = "usePowerCharges", ov = "overridePowerCharges", max = "PowerChargesMax" },
		{ key = "FrenzyCharge", use = "useFrenzyCharges", ov = "overrideFrenzyCharges", max = "FrenzyChargesMax" },
		{ key = "EnduranceCharge", use = "useEnduranceCharges", ov = "overrideEnduranceCharges", max = "EnduranceChargesMax" },
		{ key = "Rage", ov = "multiplierRage", max = "MaximumRage" },
	}
	local want = {}
	for _, k in ipairs(r.curves or {}) do want[k] = true end
	for _, P in ipairs(POOLS) do
		local mx = out[P.max]
		if want[P.key] and type(mx) == "number" and mx > 0 and (not P.use or tab.input[P.use]) then
			local saved = { [P.ov] = { v = tab.input[P.ov] } }
			local pts = {}
			local step = mx > 12 and math.ceil(mx / 10) or 1
			local n = 0
			while n <= mx do
				local cfgx = { [P.ov] = n }
				if n == 0 and P.use then saved[P.use] = saved[P.use] or { v = tab.input[P.use] } cfgx = { [P.use] = false } end
				H.applyConfig(cfgx)
				H.recalc()
				pts[#pts+1] = { n = n, dpsPct = pctD(cur(), base) }
				if n == 0 and P.use then tab.input[P.use] = saved[P.use].v end
				if n == mx then break end
				n = math.min(mx, n + step)
			end
			for k, sv in pairs(saved) do tab.input[k] = sv.v end
			tab:BuildModList() build.buildFlag = true
			H.recalc()
			curves[P.key] = { max = mx, points = pts }
		end
	end
	------------------------------------------------------------------ every conditional line in the build
	-- each mod gated or scaled by a condition / count, evaluated now: on lines are what the build gets,
	-- off lines are effects the build carries but whose condition is not met in this calculation
	H.recalc()
	local env3 = build.calcsTab.mainEnv
	local sk3 = env3.player.mainSkill
	local condRows, seen3 = {}, {}
	local GATE = { Condition = true, ActorCondition = true, Multiplier = true, MultiplierThreshold = true, StatThreshold = true, PerStat = true }
	local function scan3(list, db)
		for _, mod in ipairs(list) do
			if not seen3[mod] and mod[1] and mod.source and not tostring(mod.source):match("^Config") and not tostring(mod.source):match("^Base") then
				local gated
				for _, tag in ipairs(mod) do if GATE[tag.type] then gated = true break end end
				if gated then
					seen3[mod] = true
					local okE, v = pcall(db.EvalMod, db, mod, sk3.skillCfg)
					local row = modRow({ value = okE and v or nil }, mod)
					row.active = okE and v ~= nil and v ~= 0 and v ~= false
					condRows[#condRows+1] = row
				end
			end
		end
	end
	local node3 = sk3 and sk3.skillModList
	while node3 do
		if node3.mods then for _, list in pairs(node3.mods) do scan3(list, sk3.skillModList) end else scan3(node3, sk3.skillModList) end
		node3 = node3.parent
	end

	------------------------------------------------------------------ ways to push a mechanic further
	-- passives and uniques outside the build whose parsed mods raise the mechanic's maximum or are gated /
	-- scaled by it, each measured by PoB
	local expand = {}
	local MAXOF = { PowerCharge = "PowerChargesMax", FrenzyCharge = "FrenzyChargesMax", EnduranceCharge = "EnduranceChargesMax", Rage = "MaximumRage" }
	if r.expand and helpers.preview then
		local ascName = spec.curAscendClassName
		for i, m in ipairs(mechs) do
			local vars = {}
			for _, c in ipairs(m.changed) do vars[c.var] = true end
			local mx = MAXOF[m.key]
			local function why(list)
				local hits = {}
				for _, mod in ipairs(list or {}) do
					if (mx and mod.name == mx) or refersTo(mod, vars) or (mx and mod.name == m.key .. "sMax") then hits[#hits+1] = modRow(nil, mod) end
				end
				return hits
			end
			local cands, meta = {}, {}
			for id, n in pairs(spec.nodes) do
				if not n.alloc and (n.type == "Notable" or n.type == "Keystone") and (not n.ascendancyName or n.ascendancyName == ascName) and n.modList then
					local hits = why(n.modList)
					if #hits > 0 then cands[#cands+1] = { addNodes = { id } } meta[#meta+1] = { kind = n.type == "Keystone" and "keystone" or "notable", id = id, name = n.dn, mods = hits } end
				end
				if #cands >= 60 then break end
			end
			for _, item in pairs(main.uniqueDB.list) do
				local hits = why(item.modList or (item.slotModList and item.slotModList[1]))
				if #hits > 0 then
					local slot = item:GetPrimarySlot()
					if slot then cands[#cands+1] = { unique = item.name, slot = slot } meta[#meta+1] = { kind = "unique", name = item.name, slot = slot, mods = hits } end
				end
				if #cands >= 90 then break end
			end
			if #cands > 0 then
				-- PoB's rage is min(setting, maximum): lift the setting so a bigger maximum shows (assumes rage is kept full)
				local savedRage
				if m.key == "Rage" then savedRage = { v = tab.input.multiplierRage } H.applyConfig({ multiplierRage = 9999 }) H.recalc() end
				local pr = helpers.preview(cands)
				if savedRage then tab.input.multiplierRage = savedRage.v tab:BuildModList() build.buildFlag = true H.recalc() end
				for j, x in ipairs(pr.results or {}) do meta[j].pv = { ok = x.ok, dpsPct = x.dpsPct, ehpPct = x.ehpPct, points = x.points, problems = x.problems } end
			end
			expand[m.key] = meta
		end
	end
	H.recalc()
	return { formula = formula, cond = condRows, expand = expand, out = outKeys, hit = used, mechs = mechs, maxSrc = maxSrc, curves = curves,
		skill = { name = skill.activeEffect and skill.activeEffect.grantedEffect and skill.activeEffect.grantedEffect.name } }
end
