-- Condition catalog: every passive node, unique item, item affix / rune, and skill / support gem, read through
-- PoB's own parsed mods. For each effect line: what it requires (condition / count / threshold tags) and what it
-- produces (Condition:X / Multiplier:X / resource maxima / enemy conditions). Plus PoB's engine rules
-- (conditions the calculation derives from other values) and its config options, scanned from the source.
-- Written as JSON to r.out.
return function(H, build, r)
	local dk = H.dkjson
	local GATE = { Condition = true, ActorCondition = true, Multiplier = true, MultiplierThreshold = true, StatThreshold = true, PerStat = true,
		PercentStat = true, SkillType = false, SkillName = false, SocketedIn = false, ItemCondition = true, Limit = false, Condition_Or = true }
	local function tagRow(tag)
		local x = { type = tag.type }
		for _, k in ipairs({ "var", "stat", "threshold", "div", "limit", "actor", "neg", "upper", "percent", "thresholdVar", "thresholdStat", "itemSlot", "searchCond", "rarityCond" }) do
			local v = tag[k]
			if v ~= nil and type(v) ~= "table" and type(v) ~= "function" then x[k] = v end
		end
		if tag.varList then x.varList = {} for _, v in ipairs(tag.varList) do x.varList[#x.varList+1] = tostring(v) end end
		if tag.statList then x.statList = {} for _, v in ipairs(tag.statList) do x.statList[#x.statList+1] = tostring(v) end end
		return x
	end
	-- one parsed mod -> { name, type, value, req = {tags}, prod = {produced things} }, unwrapping enemy / minion / aura wrappers
	local function modInfo(mod, wrap)
		local o = { n = mod.name, t = mod.type }
		if type(mod.value) == "number" or type(mod.value) == "boolean" or type(mod.value) == "string" then o.v = mod.value end
		local req = {}
		for _, tag in ipairs(mod) do if GATE[tag.type] or (tag.type and tag.type:match("Condition")) then req[#req+1] = tagRow(tag) end end
		if #req > 0 then o.req = req end
		local prod = {}
		local function addProd(m, actor)
			local c = m.name and m.name:match("^Condition:(.+)$")
			if c then prod[#prod+1] = { kind = "condition", var = c, actor = actor } end
			local mu = m.name and m.name:match("^Multiplier:(.+)$")
			if mu then prod[#prod+1] = { kind = "multiplier", var = mu, actor = actor } end
			if m.name and (m.name:match("ChargesMax$") or m.name == "MaximumRage" or m.name:match("^Maximum%a+Stacks?$")) then prod[#prod+1] = { kind = "max", var = m.name, actor = actor } end
			if m.name and m.name:match("^Can%u") and m.type == "FLAG" then prod[#prod+1] = { kind = "flag", var = m.name, actor = actor } end
		end
		addProd(mod, wrap)
		if type(mod.value) == "table" and mod.value.mod then
			local inner = mod.value.mod
			local actor = (mod.name == "EnemyModifier" and "enemy") or (mod.name == "MinionModifier" and "minion") or (mod.name:match("Aura") and "aura") or (mod.name:match("Curse") and "curse") or mod.name
			o.inner = modInfo(inner, actor)
			for _, p in ipairs(o.inner.prod or {}) do prod[#prod+1] = p end
			for _, q in ipairs(o.inner.req or {}) do o.req = o.req or {} q.inner = actor o.req[#o.req+1] = q end
		end
		if #prod > 0 then o.prod = prod end
		return o
	end
	local function listInfo(list)
		local out, any = {}, false
		for _, mod in ipairs(list or {}) do
			local m = modInfo(mod)
			if m.req or m.prod then any = true end
			out[#out+1] = m
		end
		return out, any
	end
	local ents = {}
	local function push(e) ents[#ents+1] = e end

	------------------------------------------------------------------ passive tree (every node, all classes / ascendancies)
	local tree = build.spec.tree
	for id, n in pairs(tree.nodes) do
		if (n.modList and #n.modList > 0) or (n.sd and #n.sd > 0) then
			local mods, any = listInfo(n.modList)
			if any or (n.isNotable or n.isKeystone or n.ascendancyName or n.type == "Notable" or n.type == "Keystone") then
				local kind = n.isKeystone and "keystone" or n.isNotable and "notable" or n.type == "Keystone" and "keystone" or n.type == "Notable" and "notable" or "node"
				if n.ascendancyName then kind = "ascendancy" end
				local sd = {}
				for _, l in ipairs(n.sd or {}) do sd[#sd+1] = l end
				push({ k = kind, id = id, n = n.dn, asc = n.ascendancyName, lines = sd, mods = mods })
			end
		end
	end
	------------------------------------------------------------------ uniques
	for name, item in pairs(main.uniqueDB.list) do
		local list = item.modList or (item.slotModList and item.slotModList[1])
		if list then
			local mods, any = listInfo(list)
			do
				local lines = {}
				for _, ml in ipairs(item.explicitModLines or {}) do lines[#lines+1] = ml.line end
				for _, ml in ipairs(item.implicitModLines or {}) do table.insert(lines, 1, ml.line) end
				push({ k = "unique", n = item.name, base = item.baseName, type = item.type, slot = item:GetPrimarySlot(), lines = lines, mods = mods })
			end
		end
	end
	------------------------------------------------------------------ item affixes, runes, corruptions, jewels, flasks, charms
	local seenLine = {}
	for pool, mods in pairs(build.data.itemMods) do
		for id, m in pairs(mods) do
			for _, line in ipairs(m) do
				local key = pool .. "|" .. line
				if not seenLine[key] then
					seenLine[key] = true
					local ok, list = pcall(modLib.parseMod, line)
					if ok and list then
						local mi, any = listInfo(list)
						push({ k = "affix", pool = pool, id = id, n = m.affix or id, affixType = m.type, lines = { line }, mods = mi, tags = m.weightKey and #m.weightKey > 0 and m.weightKey or nil, parsed = any })
					end
				end
			end
		end
	end
	------------------------------------------------------------------ skill and support gems (base mods + every stat the gem has, mapped)
	local gemOf = {}
	for _, gd in pairs(build.data.gems) do
		if gd.grantedEffect then gemOf[gd.grantedEffect.id] = gd end
		if gd.secondaryGrantedEffect then gemOf[gd.secondaryGrantedEffect.id] = gemOf[gd.secondaryGrantedEffect.id] or gd end
	end
	for id, ge in pairs(build.data.skills) do
		local gd = gemOf[id]
		if gd or ge.support then
			local all = {}
			local stats = {}
			for _, part in ipairs({ ge, unpack(ge.statSets or {}) }) do
				for _, list in ipairs({ part.baseMods or {}, part.qualityMods or {} }) do
					for _, mod in ipairs(list) do
						if mod.name then all[#all+1] = mod else for _, mm in ipairs(mod) do all[#all+1] = mm end end
					end
				end
				local names = {}
				for _, c in ipairs(part.constantStats or {}) do names[#names+1] = c[1] end
				for _, s in ipairs(part.stats or {}) do names[#names+1] = s end
				for _, q in ipairs(part.qualityStats or {}) do names[#names+1] = q[1] end
				for _, s in ipairs(names) do
					if type(s) == "string" and not stats[s] then
						stats[s] = true
						local ok, map = pcall(function() return part.statMap and part.statMap[s] end)
						if ok and map then
							for _, mo in ipairs(map) do
								if mo.name then all[#all+1] = mo else for _, mm in ipairs(mo) do if mm.name then all[#all+1] = mm end end end
							end
						end
					end
				end
			end
			local mods, any = listInfo(all)
			do
				local st = {}
				for s in pairs(stats) do st[#st+1] = s end
				local lines = {}
				for _, part in ipairs({ ge, unpack(ge.statSets or {}) }) do
					if part.statDescriptionScope then
						local okS, stv = pcall(calcLib.buildSkillInstanceStats, { level = (gd and gd.naturalMaxLevel) or 20, quality = 0 }, ge, part)
						if okS and stv then
							local okD, desc = pcall(build.data.describeStats, stv, part.statDescriptionScope)
							if okD and desc then for _, l in ipairs(desc) do if type(l) == "string" then lines[#lines+1] = l end end end
						end
					end
				end
				if gd then push({ k = ge.support and "support" or "skill", id = id, n = ge.name, gem = gd and gd.name, mods = mods, stats = st, desc = ge.description, lines = lines }) end
			end
		end
	end

	------------------------------------------------------------------ PoB engine rules: conditions the calculation sets itself
	local rules = {}
	local function scanFile(path)
		local f = io.open(path, "r")
		if not f then return end
		local ln = 0
		local ctx = {}
		for line in f:lines() do
			ln = ln + 1
			local ifc = line:match("^%s*if%s+(.-)%s+then") or line:match("^%s*elseif%s+(.-)%s+then")
			if ifc then ctx[#ctx+1] = { ln = ln, text = ifc } if #ctx > 6 then table.remove(ctx, 1) end end
			local who, tbl, var, rhs = line:match('([%w_%.]*)%.?(conditions)%["([%w_]+)"%]%s*=%s*([^=].*)$')
			if not var then tbl, var, rhs = line:match('(condList)%["([%w_]+)"%]%s*=%s*([^=].*)$') who = "" end
			if not var then who, tbl, var, rhs = line:match('([%w_%.]*)%.?(multipliers)%["([%w_]+)"%]%s*=%s*([^=].*)$') end
			if not var then
				local nm, rest = line:match('NewMod%("(Condition:[%w_]+)"(.*)$')
				if not nm then nm, rest = line:match('NewMod%("(Multiplier:[%w_]+)"(.*)$') end
				if nm then tbl = nm:match("^Condition") and "conditions" or "multipliers" var = nm:match(":(.+)$") rhs = rest who = line:match("(%w*[Ee]nemy%w*)") or "" end
			end
			who = who or ""
			if tbl == "condList" then tbl = "conditions" end
			if var then
				local deps = {}
				local function collect(text)
					for v in text:gmatch('conditions%["([%w_]+)"%]') do deps[#deps+1] = { kind = "condition", var = v } end
					for v in text:gmatch('GetCondition%("([%w_]+)"') do deps[#deps+1] = { kind = "condition", var = v } end
					for v in text:gmatch('multipliers%["([%w_]+)"%]') do deps[#deps+1] = { kind = "multiplier", var = v } end
					for v in text:gmatch('GetMultiplier%("([%w_]+)"') do deps[#deps+1] = { kind = "multiplier", var = v } end
					for v in text:gmatch('output%.([%w_]+)') do deps[#deps+1] = { kind = "output", var = v } end
					for v in text:gmatch('Flag%([^,]*,%s*"([%w_:]+)"') do deps[#deps+1] = { kind = "flag", var = v } end
					for v in text:gmatch('Sum%("%u+",%s*[^,]*,%s*"([%w_:]+)"') do deps[#deps+1] = { kind = "stat", var = v } end
				end
				collect(rhs)
				local guard = ctx[#ctx] and (ln - ctx[#ctx].ln) <= 4 and ctx[#ctx].text or nil
				if guard then collect(guard) end
				rules[#rules+1] = { file = path:match("[^/]+$"), line = ln, actor = who:match("enemy") and "enemy" or who:match("minion") and "minion" or "player",
					kind = tbl == "conditions" and "condition" or "multiplier", var = var, expr = rhs:sub(1, 200), guard = guard and guard:sub(1, 200), deps = deps }
			end
		end
		f:close()
	end
	for _, fn in ipairs({ "CalcPerform", "CalcOffence", "CalcDefence", "CalcSetup", "CalcActiveSkill", "CalcTriggers", "CalcMirages", "Calcs" }) do scanFile("Modules/" .. fn .. ".lua") end

	------------------------------------------------------------------ config options: which condition each switch writes, and when it is shown
	local configs = {}
	do
		local f = io.open("Modules/ConfigOptions.lua", "r")
		local src = f:read("*a") f:close()
		local bodies, cur = {}, nil
		for line in (src .. "\n"):gmatch("([^\n]*)\n") do
			if line:match('^%s*{ var = "') then cur = { line } bodies[#bodies+1] = cur
			elseif line:match('^%s*{ section = ') then cur = nil
			elseif cur then cur[#cur+1] = line end
		end
		for _, b in ipairs(bodies) do
			local body = table.concat(b, "\n")
			local var = body:match('var = "([%w_]+)"')
			if var then
				local c = { var = var, label = body:match('label = "([^"]*)"'), type = body:match('type = "(%w+)"'), sets = {}, shownIf = {} }
				for k in ("ifCond ifEnemyCond ifMult ifEnemyMult ifFlag ifPlayerFlag ifMinionFlag ifOption ifSkill ifSkillData ifStat ifEnemyStat ifTagType ifNode ifSkillFlag"):gmatch("%S+") do
					local v = body:match("[%s,{]" .. k .. ' = "([^"]+)"')
					if v then c.shownIf[#c.shownIf+1] = { k = k, v = v } end
					local vl = body:match("[%s,{]" .. k .. ' = (%b{})')
					if vl then for x in vl:gmatch('"([^"]+)"') do c.shownIf[#c.shownIf+1] = { k = k, v = x } end end
				end
				for pre, nm in body:gmatch('(%w+):NewMod%("([%w_:]+)"') do c.sets[#c.sets+1] = (pre:match("enemy") and "enemy:" or "") .. nm end
				configs[#configs+1] = c
			end
		end
	end
	local out = { ents = ents, rules = rules, configs = configs, treeVersion = tree.treeVersion }
	local f = io.open(r.out, "w")
	f:write(dk.encode(out))
	f:close()
	return { count = #ents, rules = #rules, configs = #configs }
end
