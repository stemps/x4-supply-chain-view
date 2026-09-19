-- Supply Chain View — engine station and ware reads.
-- Depends: scv_support.lua, scv_graph.lua, scv_metrics.lua
local ffi = require("ffi")
local C = ffi.C
local log, warnOnce, safe = SCV_Support.log, SCV_Support.warnOnce, SCV_Support.safe
SCV_Reader = {}

-- Identical to the station overview ABI. Helper already declares WorkForceInfo.
-- Guard typedefs because other vanilla menus may have loaded first.
if ffi.cdef and ffi.typeof then
	local definitions = {
		{ "UIWorkforceInfluence", [[typedef struct { const char* type; const char* name; float value; bool active; } UIWorkforceInfluence;]] },
		{ "WorkforceInfluenceCounts", [[typedef struct { uint32_t numcapacityinfluences; uint32_t numgrowthinfluences; } WorkforceInfluenceCounts;]] },
		{ "WorkforceInfluenceInfo", [[typedef struct {
			uint32_t numcapacityinfluences; UIWorkforceInfluence* capacityinfluences;
			uint32_t numgrowthinfluences; UIWorkforceInfluence* growthinfluences;
			float basegrowth; uint32_t capacity; uint32_t current; uint32_t sustainable;
			uint32_t target; int32_t change;
		} WorkforceInfluenceInfo;]] },
	}
	for _, definition in ipairs(definitions) do
		if not pcall(ffi.typeof, definition[1]) then ffi.cdef(definition[2]) end
	end
	ffi.cdef[[
		WorkforceInfluenceCounts GetNumContainerWorkforceInfluence(UniverseID containerid, const char* raceid, bool force);
		void GetContainerWorkforceInfluence(WorkforceInfluenceInfo* result, UniverseID containerid, const char* raceid);
	]]
end

-- Same recipe arithmetic as Helper.getWorkforceConsumption, but at full staffing.
local function readWorkforceReserve(id64)
	local result = { wares = {}, reserve = {}, known = false, membershipKnown = false }
	local ok, err = pcall(function ()
		local recipes = GetWorkForceRaceResources(id64)
		assert(type(recipes) == "table", "workforce recipes unavailable")
		local total = C.GetWorkForceInfo(id64, "")
		local optimal, current, capacity = tonumber(total.optimal), tonumber(total.current), tonumber(total.capacity)
		assert(SCV_Graph.validRate(optimal) and SCV_Graph.validRate(current) and SCV_Graph.validRate(capacity), "invalid workforce totals")
		local races, seen, sumCurrent, sumCapacity = {}, {}, 0, 0
		for _, recipe in ipairs(recipes) do
			assert(type(recipe.race) == "string" and not seen[recipe.race], "duplicate workforce race")
			seen[recipe.race] = true
			local info = C.GetWorkForceInfo(id64, recipe.race)
			local count, cap = tonumber(info.current), tonumber(info.capacity)
			assert(SCV_Graph.validRate(count) and SCV_Graph.validRate(cap), "invalid race workforce")
			sumCurrent, sumCapacity = sumCurrent + count, sumCapacity + cap
			if cap > 0 or count > 0 then
				assert(type(recipe.resources) == "table" and SCV_Graph.validRate(recipe.productamount)
					and recipe.productamount > 0 and #recipe.resources > 0, "workforce resource recipe unavailable")
				for _, resource in ipairs(recipe.resources) do
					assert(type(resource.ware) == "string" and SCV_Graph.validRate(resource.cycle)
						and SCV_Graph.validRate(resource.cycleduration) and resource.cycleduration > 0, "invalid workforce resource")
					result.wares[resource.ware] = true
				end
				races[#races + 1] = recipe
			end
		end
		assert(sumCurrent == current and sumCapacity == capacity, "incomplete workforce race coverage")
		result.membershipKnown = true
		local allocated = 0
		for _, recipe in ipairs(races) do
			local target
			if #races == 1 then
				target = optimal
			else
				local counts = C.GetNumContainerWorkforceInfluence(id64, recipe.race, false)
				local buf = ffi.new("WorkforceInfluenceInfo")
				buf.numcapacityinfluences, buf.numgrowthinfluences = counts.numcapacityinfluences, counts.numgrowthinfluences
				local capacityBuffer = ffi.new("UIWorkforceInfluence[?]", counts.numcapacityinfluences)
				local growthBuffer = ffi.new("UIWorkforceInfluence[?]", counts.numgrowthinfluences)
				buf.capacityinfluences, buf.growthinfluences = capacityBuffer, growthBuffer
				C.GetContainerWorkforceInfluence(buf, id64, recipe.race)
				target = tonumber(buf.target)
			end
			assert(SCV_Graph.validRate(target), "invalid workforce target")
			allocated = allocated + target
			for _, resource in ipairs(recipe.resources) do
				local amount = math.floor(resource.cycle * 3600 / resource.cycleduration * target / recipe.productamount + 0.5)
				result.reserve[resource.ware] = (result.reserve[resource.ware] or 0) + amount
			end
		end
		-- Empty habitat set establishes no local workforce demand, not a race guess.
		assert(#races == 0 or allocated == optimal, "race targets do not match optimal workforce")
		result.known = true
	end)
	if not ok then warnOnce("workforce-reserve:" .. tostring(err), "export reserve unavailable: " .. tostring(err)) end
	return result
end

-- ---------------------------------------------------------------------------------
-- Station enumeration
-- ---------------------------------------------------------------------------------

-- DELIBERATELY NO galaxy-wide station enumeration here.
--
-- There was one, built on GetContainedStationsByOwner("player", nil, true), and chain
-- membership was validated against it - which silently dropped stations that the call did
-- not return. Both vanilla uses of it (menu_map.lua:5132 and :28809) are build-PLOT code,
-- so it is not the general "all my stations" list it looks like. Nothing in this mod needs
-- such a list: the context menu works from the current selection, and a chain resolves its
-- own stored ids through SCV_Reader.describe. Re-introducing one would re-introduce the bug.

-- Cheap identity read: name and location only, no ware scan. Used by the context menu and
-- by the member list, both of which run far too often to pay for a full read.
--
-- Returns nil when the id no longer resolves to a live station - destroyed, sold, or from
-- an older save. That nil is the ONLY membership test the mod does: resolving stored ids
-- directly is what keeps a chain independent of any galaxy-wide enumeration.
function SCV_Reader.describe(id64)
	if type(id64) == "string" then
		id64 = ConvertStringTo64Bit(id64)
	end
	if (not id64) or (id64 == 0) then
		return nil
	end
	-- Vanilla menu_station_overview.lua:2442 checks validity before component reads.
	-- IsComponentClass logs stale IDs even inside pcall.
	if not IsValidComponent(id64) then return nil end
	local ok, isstation = pcall(function () return C.IsComponentClass(id64, "station") end)
	if (not ok) or (not isstation) then
		return nil
	end
	local name       = safe("", GetComponentData, id64, "name")
	local sectorid   = safe(nil, GetComponentData, id64, "sectorid")
	local sectorname = sectorid and safe("", GetComponentData, sectorid, "name") or ""
	-- The station code ("HEA-485"). Unlike the runtime id it is persisted with the station
	-- and survives a savegame load, which makes it the durable identity SCV_Store keys
	-- chain membership on. Same key vanilla reads (menu_map, "idcode").
	local code       = safe("", GetComponentData, id64, "idcode")
	return {
		id         = tostring(id64),
		id64       = id64,
		name       = (name ~= "" and name) or tostring(id64),
		sectorname = tostring(sectorname),
		code       = (code ~= "") and tostring(code) or nil,
	}
end

-- Current id of the station with a given code, for re-linking chain members after a load.
--
-- Built once per Lua environment, on first need, the way vanilla walks the galaxy:
-- GetClusters(true), then GetContainedStations(cluster, true) for each
-- (menu_encyclopedia.lua:524 and :2727). One cheap read per station, and only when a
-- member's stored id has gone stale - within a session the fast path never gets here.
--
-- A /reloadui re-runs this file and so starts a fresh index; a new game session always
-- does. Within a session a station built after the index was made will not be in it,
-- which only matters for re-linking, and a freshly built station has a current id anyway.
local codeIndex = nil

function SCV_Reader.lookupCode(code)
	if (not code) or (code == "") then
		return nil
	end
	if not codeIndex then
		codeIndex = {}
		local n = 0
		local clusters = safe({}, GetClusters, true)
		for _, cluster in ipairs(clusters) do
			local stations = safe({}, GetContainedStations, cluster, true)
			for _, st in ipairs(stations) do
				local id64 = ConvertStringTo64Bit(tostring(st))
				local c = id64 and safe("", GetComponentData, id64, "idcode") or ""
				if c ~= "" then
					if codeIndex[c] then
						-- Codes are three letters and three digits; a clash is unlikely but
						-- not impossible. Keep the first and say so rather than guess.
						warnOnce("dupcode" .. c, "two stations share the code " .. c
							.. " - re-linking by code may pick the wrong one")
					else
						codeIndex[c] = tostring(id64)
						n = n + 1
					end
				end
			end
		end
		log("indexed " .. n .. " station(s) by code for re-linking")
	end
	return codeIndex[code]
end

-- ---------------------------------------------------------------------------------
-- The two halves of the goods rule
-- ---------------------------------------------------------------------------------

-- Engine ware lists (availableproducts / pureresources / intermediatewares / tradewares)
-- are arrays of ware-id STRINGS - confirmed by vanilla using the elements directly as table
-- keys at helper.lua:11756-11764. Some other call sites hand back arrays of tables with a
-- .ware field, so accept both rather than betting on one.
local function normalizeWareList(list)
	local out, known = {}, true
	if type(list) ~= "table" then
		return out, false
	end
	for _, entry in ipairs(list) do
		local ware
		if type(entry) == "string" then
			ware = entry
		elseif type(entry) == "table" then
			ware = entry.ware
		end
		if type(ware) == "string" and ware ~= "" then
			out[ware] = true
		else
			known = false
		end
	end
	return out, known
end

-- Wares a station consumes through BUILD processes rather than production modules.
--
-- A shipyard, wharf or equipment dock is a sink for hull parts, claytronics and the rest,
-- but none of them appear in pureresources: that consumption is driven by the build queue,
-- not by a production module. Without this the biggest consumer in a network looks like it
-- needs nothing at all.
local function readBuildResources(id64)
	local out = {}
	local known = pcall(function ()
		local n = C.GetNumContainerBuildResources(id64)
		if n <= 0 then
			return
		end
		local buf = ffi.new("const char*[?]", n)
		local expected = n
		n = C.GetContainerBuildResources(buf, n, id64)
		assert(n == expected, "incomplete build resource inventory")
		for i = 0, n - 1 do
			out[ffi.string(buf[i])] = true
		end
	end)
	return out, known
end

-- Future module inventory is classification-only. Never pass these recipes to the
-- operational rate/storage readers. The live engine lists cover completed modules.
-- Vanilla: menu_map.getStationModules and station_overview's planned recipe nodes.
local function readFutureWareRoles(id64)
	local products, resources = {}, {}
	local known = true
	local seenComponents, seenMacros = {}, {}
	local function readMacro(macro)
		if not macro or macro == "" or seenMacros[macro] then return end
		seenMacros[macro] = true
		local ok, err = pcall(function ()
			if IsMacroClass(macro, "production") or IsMacroClass(macro, "processingmodule") then
				local data = GetLibraryEntry(GetMacroData(macro, "infolibrary"), macro)
				assert(data and type(data.products) == "table", "module recipe unavailable")
				for _, product in ipairs(data.products) do
					if product.ware then products[product.ware] = true end
					for _, resource in ipairs(product.resources or {}) do
						if resource.ware then resources[resource.ware] = true end
					end
				end
			elseif IsMacroClass(macro, "buildmodule") then
				local data = GetLibraryEntry("moduletypes_build", macro)
				assert(data and type(data.buildresources) == "table", "build recipe unavailable")
				for _, resource in ipairs(data.buildresources) do
					if resource.ware then resources[resource.ware] = true end
				end
			end
		end)
		if not ok then known = false; warnOnce("future-recipe:" .. macro, "planned module " .. macro .. ": " .. tostring(err)) end
	end
	local function readComponent(module)
		local key = tostring(module)
		if seenComponents[key] then return end
		seenComponents[key] = true
		if IsValidComponent(module) and IsComponentConstruction(module) then
			readMacro(GetComponentData(module, "macro"))
		end
	end
	-- Separate protected reads: failure of either list must not discard the other.
	local ok, err = pcall(function ()
		local n = C.GetNumStationModules(id64, true, true)
		if n <= 0 then return end
		local buf = ffi.new("UniverseID[?]", n)
		local expected = n
		n = C.GetStationModules(buf, n, id64, true, true)
		assert(n == expected, "incomplete future module inventory")
		for i = 0, n - 1 do readComponent(ConvertStringTo64Bit(tostring(buf[i]))) end
	end)
	if not ok then known = false; warnOnce("future-components", "unfinished module read failed: " .. tostring(err)) end
	ok, err = pcall(function ()
		-- size_t is 64-bit cdata in LuaJIT; numeric for loops require a Lua number.
		local n = tonumber(C.GetNumPlannedStationModules(id64, false))
		if n <= 0 then return end
		local buf = ffi.new("UIConstructionPlanEntry[?]", n)
		local expected = n
		n = tonumber(C.GetPlannedStationModules(buf, n, id64, false))
		assert(n == expected, "incomplete planned module inventory")
		for i = 0, n - 1 do
			if buf[i].componentid ~= 0 then
				readComponent(ConvertStringTo64Bit(tostring(buf[i].componentid)))
			else
				readMacro(ffi.string(buf[i].macroid))
			end
		end
	end)
	if not ok then known = false; warnOnce("future-plan", "planned module read failed: " .. tostring(err)) end
	return products, resources, known
end

-- How a station classifies each ware it deals in.
--
-- The engine already computes exactly the distinction the goods rule needs, and vanilla
-- reads it at helper.lua:11746 (Helper.getContainerWareType):
--     availableproducts  -> the station makes this and offers it        => OUTPUT
--     pureresources      -> the station needs this and does not make it => INPUT
--     intermediatewares  -> made AND consumed here                      => EXCLUDED
--     anything else in tradewares -> explicitly traded goods            => depends on
--                                    IsSellable / IsBuyable
-- Supplement the engine's completed-module roles with committed future recipes.
--
-- WHY NOT GetTradeList. The first version of this used live trade offers, and that made a
-- BROKEN chain INVISIBLE: a starved factory has produced nothing, so it has no sell offer,
-- so it had no outgoing link - precisely when the diagram is most needed. Offers depend on
-- current stock; this classification depends on how the station is configured, so the link
-- is drawn whether or not anything is flowing through it right now.
--
-- Reading the three keys directly rather than calling Helper.getContainerWareType per ware:
-- that function caches into Helper.wareTypeBuffer, but reassigns the buffer table AFTER
-- stamping the container and timestamp on it (helper.lua:11747 then :11750), so the cache
-- never actually hits and every call re-reads. One read per station is cheaper and clearer.
local function readWareRoles(id64, recipes)
	local products, productsKnown = normalizeWareList(safe(nil, GetComponentData, id64, "availableproducts"))
	local pureresources, resourcesKnown = normalizeWareList(safe(nil, GetComponentData, id64, "pureresources"))
	local intermediates, intermediatesKnown = normalizeWareList(safe(nil, GetComponentData, id64, "intermediatewares"))
	local tradewares, tradeKnown = normalizeWareList(safe(nil, GetComponentData, id64, "tradewares"))
	local buildwares, buildKnown = readBuildResources(id64)
	local futureProducts, futureResources, futureKnown = readFutureWareRoles(id64)
	local rolesKnown = recipes.known and buildKnown and futureKnown
		and productsKnown and resourcesKnown and intermediatesKnown and tradeKnown
	-- Observed completed products remain provisional if another inventory read fails.
	-- An observed recipe consumer is still a real intermediate, even if the engine
	-- omitted it from intermediatewares. Workforce recipes are deliberately separate.
	for ware in pairs(recipes.outputs) do
		if recipes.inputs[ware] then
			intermediates[ware] = true
		elseif not buildwares[ware] and not futureResources[ware] then
			products[ware], intermediates[ware] = true, nil
		end
	end
	for ware in pairs(futureResources) do
		if products[ware] or futureProducts[ware] then intermediates[ware] = true end
	end
	for ware in pairs(futureProducts) do
		if pureresources[ware] or buildwares[ware] then intermediates[ware] = true end
	end

	local outputs, inputs, candidates = {}, {}, {}

	local function note(ware)
		candidates[ware] = true
	end

	for ware in pairs(products) do note(ware) end
	for ware in pairs(futureProducts) do note(ware) end
	for ware in pairs(pureresources) do note(ware) end
	for ware in pairs(tradewares) do note(ware) end
	for ware in pairs(buildwares) do note(ware) end
	for ware in pairs(futureResources) do note(ware) end

	for ware in pairs(candidates) do
		-- The exclusion is applied explicitly rather than trusting the lists to be
		-- disjoint: vanilla's own classifier checks products BEFORE intermediates, which
		-- means a ware in both would read as a product there. The rule says an internal
		-- consumer disqualifies it, so intermediates lose either way.
		if not intermediates[ware] then
			if products[ware] or futureProducts[ware] then
				outputs[ware] = true
			end
			if pureresources[ware] or buildwares[ware] or futureResources[ware] then
				inputs[ware] = true
			end
			-- Explicitly traded goods: a mining hub's ore is neither a product nor a
			-- resource of any module, it is simply bought and sold. Ask the station whether
			-- it is configured to sell or buy it.
			if tradewares[ware] and (not products[ware]) and (not pureresources[ware]) then
				local sellable = safe(false, function () return C.GetContainerWareIsSellable(id64, ware) end)
				local buyable  = safe(false, function () return C.GetContainerWareIsBuyable(id64, ware) end)
				if sellable then
					outputs[ware] = true
				end
				if buyable then
					inputs[ware] = true
				end
			end
		end
	end

	-- OUTPUT WINS when a station both buys and sells the same ware.
	--
	-- Mining hubs are the normal case: they buy ore from their own miners and sell it on,
	-- so ore is configured both ways. Counting it as an input too makes the hub a consumer
	-- of the very ware it exists to supply - it draws an edge back into the hub, turns
	-- every hub into a false bottleneck, and manufactures a cycle out of what is really a
	-- one-way flow. What the chain cares about is where the ware GOES.
	-- Build resources are internal consumers even if the engine also lists the ware
	-- as a product or sellable trade good. Workforce use is deliberately not a veto.
	for ware in pairs(buildwares) do
		outputs[ware] = nil
		if not intermediates[ware] then inputs[ware] = true end
	end
	for ware in pairs(futureResources) do outputs[ware] = nil end
	for ware in pairs(outputs) do
		inputs[ware] = nil
	end

	return outputs, inputs, candidates, intermediates, buildwares, futureResources, rolesKnown, futureProducts, tradewares
end

-- Reserved trades per ware: how much is on its way IN and how much is committed to go OUT.
--
-- Parsing matches vanilla's own storage panel exactly (Helper.onExpandLSOStorageNode):
--     local buyflag = buf[i].isbuyreservation and "selloffer" or "buyoffer"
--         -- sic! Reservation to buy -> container is selling
-- so isbuyreservation TRUE is an OUTGOING pickup and FALSE is an INCOMING delivery. The
-- field name reads the opposite way; vanilla's comment is the authority.
--
-- Two filters, both vanilla's:
--   * issupply  - ship resupply (drones, missiles), not ware storage. An earlier version of
--                 this reader did not skip these, so a station restocking its defence drones
--                 could show as having a ware delivery inbound.
--   * dirty     - deals already being torn down; counting them shows phantom movement.
local function readReservations(id64)
	local res = {}
	local ok, err = pcall(function ()
		local n = C.GetNumContainerWareReservations2(id64, false, false, true)
		if n <= 0 then
			return
		end
		local buf = ffi.new("WareReservationInfo2[?]", n)
		n = C.GetContainerWareReservations2(buf, n, id64, false, false, true)
		for i = 0, n - 1 do
			if not buf[i].issupply then
				local deal = tostring(buf[i].tradedealid)
				local dirty = Helper.dirtyreservations and Helper.dirtyreservations[deal]
				if not dirty then
					local ware = ffi.string(buf[i].ware)
					local r = res[ware] or { incoming = 0, outgoing = 0 }
					local amount = tonumber(buf[i].amount) or 0
					if buf[i].isbuyreservation then
						r.outgoing = r.outgoing + amount
					else
						r.incoming = r.incoming + amount
					end
					res[ware] = r
				end
			end
		end
	end)
	if not ok then
		warnOnce(tostring(err), "reservation read failed: " .. tostring(err))
		return {}, false
	end
	return res, true
end

-- Base recipe inventory identifies wares with measurable production-module activity.
-- These values are NOT displayed: effective maximum rates come from the native API.
-- Walk modules as the LSO does (menu_station_overview.lua:664).
--
-- Cache recipes per macro within one read; never cache station-specific engine modifiers
-- by macro, because sunlight and workforce can differ between stations.
-- Processor amountperhour describes full processing speed even while waiting for
-- resources (engine capture 2026-09-13, recorded in the toolkit knowledgebase). Never turn
-- missing or zero activity-shaped data into a claimed maximum. Scope failures
-- per ware, and do not substitute unmodified recipe values.
local function accumulateProcessingRates(entries, inventory, total, excluded)
	local values, invalid = {}, {}
	for _, entry in ipairs(type(entries) == "table" and entries or {}) do
		local ware = entry.ware
		if ware and inventory[ware] ~= nil then
			if SCV_Graph.validRate(entry.amountperhour) and tonumber(entry.amountperhour) > 0 then
				values[ware] = (values[ware] or 0) + tonumber(entry.amountperhour)
			else
				invalid[ware] = true
			end
		end
	end
	for ware in pairs(inventory) do
		if not invalid[ware] and values[ware] ~= nil then total[ware] = (total[ware] or 0) + values[ware]
		else excluded[ware] = true end
	end
end

local function readTheoreticalRates(id64)
	local prod, cons = {}, {}
	local recipes = { outputs = {}, inputs = {}, counts = {} }
	local excludedProd, excludedCons = {}, {}
	local processing = { feedstocks = {}, inputs = {}, outputs = {},
		production = {}, consumption = {}, excludedProd = {}, excludedCons = {} }
	local ok, err = pcall(function ()
		local n = C.GetNumStationModules(id64, true, true)
		if n <= 0 then
			return
		end
		local buf = ffi.new("UniverseID[?]", n)
		local expected = n
		n = C.GetStationModules(buf, n, id64, true, true)
		assert(n == expected, "incomplete production module inventory")
		local byMacro = {}
		for i = 0, n - 1 do
			local module = ConvertStringTo64Bit(tostring(buf[i]))
			local isprod = C.IsRealComponentClass(module, "production")
			local isproc = C.IsRealComponentClass(module, "processingmodule")
			-- Construction is future capacity, just like a module still in the build
			-- plan. Skip its recipe and scan gates so it cannot veto completed rates.
			local unbuiltProduction = isprod and not isproc and IsComponentConstruction(module)
			if (isprod or isproc) and not unbuiltProduction then
				local macro = GetComponentData(module, "macro")
				assert(type(macro) == "string" and macro ~= "", "module identity unavailable")
				if macro then
					local rates = byMacro[macro]
					if not rates then
						local lib = GetMacroData(macro, "infolibrary")
						local md = lib and GetLibraryEntry(lib, macro)
						assert(md and type(md.products) == "table", "module recipe unavailable: " .. tostring(macro))
						for _, product in ipairs(md.products) do
							if product.ware then recipes.outputs[product.ware] = true end
							for _, resource in ipairs(product.resources or {}) do
								if resource.ware then recipes.inputs[resource.ware] = true end
							end
						end
						local p, c = {}, {}
						if isproc then
							-- Vanilla omits ordinary queue arithmetic for processing
							-- (menu_encyclopedia.lua:3090). Only inventory
							-- membership is needed here; effective rates come from the engine.
							for _, product in ipairs(md.products) do
								if product.ware then p[product.ware] = 0 end
								for _, resource in ipairs(product.resources or {}) do
									if resource.ware then c[resource.ware] = 0 end
								end
							end
						else
							p, c = SCV_Graph.moduleRates(md.products)
						end
						rates = { p = p, c = c }
						byMacro[macro] = rates
					end
					local operational = C.IsComponentOperational(module)
					if isproc then
						-- Match vanilla's validity and status checks, not its catch-all
						-- 'producing' branch (station_overview.lua:2680 and :3044).
						local valid = IsValidComponent(module)
						local construction = IsComponentConstruction(module)
						local functional = GetComponentData(module, "isfunctional")
						local eligible = valid and not construction and functional == true
						local unlocked = C.IsInfoUnlockedForPlayer(module, "production_rate")
							and C.IsInfoUnlockedForPlayer(module, "production_resources")
						-- IsRealComponentClass includes unfinished modules. Querying their
						-- processing data logs an engine error every sweep (observed live).
						local data = eligible and unlocked and safe(nil, GetProcessingModuleData, module) or nil
						for w in pairs(rates.p) do processing.outputs[w] = true end
						if eligible then
							for ware in pairs(rates.p) do recipes.counts[ware] = (recipes.counts[ware] or 0) + 1 end
							accumulateProcessingRates(type(data) == "table" and data.products, rates.p,
								processing.production, processing.excludedProd)
							accumulateProcessingRates(type(data) == "table" and data.resources, rates.c,
								processing.consumption, processing.excludedCons)
						elseif valid and not construction and (type(functional) ~= "boolean" or not unlocked) then
							-- Unknown eligibility cannot establish a known zero contribution.
							for w in pairs(rates.p) do processing.excludedProd[w] = true end
							for w in pairs(rates.c) do processing.excludedCons[w] = true end
						end
						for w in pairs(rates.c) do
							processing.inputs[w] = true
							-- Same classification vanilla uses to suppress ordinary missing
							-- resource warnings (station_overview.lua:4945).
							if GetWareData(w, "isprocessed") == true then
								processing.feedstocks[w] = true
							end
						end
					end
					-- Station-level rates cover ordinary production only. Processing
					-- is summed separately above; unfinished processors cannot veto it.
					if not isproc and operational then
						for ware in pairs(rates.p) do recipes.counts[ware] = (recipes.counts[ware] or 0) + 1 end
						for w, v in pairs(rates.p) do prod[w] = (prod[w] or 0) + v end
						for w, v in pairs(rates.c) do cons[w] = (cons[w] or 0) + v end
						-- Match vanilla's module-level rate/resource scan gates. Unknown
						-- information is not evidence for a genuine zero rate.
						if not C.IsInfoUnlockedForPlayer(module, "production_rate") then
							for w in pairs(rates.p) do excludedProd[w] = true end
							for w in pairs(rates.c) do excludedCons[w] = true end
						elseif not C.IsInfoUnlockedForPlayer(module, "production_resources") then
							for w in pairs(rates.c) do excludedCons[w] = true end
						end
					elseif not isproc then
						-- Do not claim an aggregate engine maximum excludes other inactive modules
						-- without evidence. Only affected wares lose a complete maximum.
						for w in pairs(rates.p) do excludedProd[w] = true end
						for w in pairs(rates.c) do excludedCons[w] = true end
					end
				else
					error("module macro unavailable")
				end
			end
		end
	end)
	if not ok then warnOnce(tostring(err), "module inventory failed: " .. tostring(err)) end
	recipes.known = ok
	return prod, cons, ok, excludedProd, excludedCons, processing, recipes
end

-- Storage capacity by transport type (container / solid / liquid...), in VOLUME units.
-- Used only as the bar's fallback denominator when the engine reports no per-ware storage
-- allocation. The struct field is `transport` (helper.lua:91 StorageInfo), not
-- `transporttype`.
local function readCapacity(id64)
	local cap = {}
	local ok = pcall(function ()
		local n = C.GetNumCargoTransportTypes(id64, true)
		assert(SCV_Graph.validRate(n) and n == math.floor(n), "invalid storage count")
		if n == 0 then
			return
		end
		local buf = ffi.new("StorageInfo[?]", n)
		local count = C.GetCargoTransportTypes(buf, n, id64, true, false)
		assert(count == n, "incomplete storage read")
		for i = 0, n - 1 do
			-- Vanilla transport strings may contain several tags (universal storage).
			local tags = ffi.string(buf[i].transport)
			local amount = tonumber(buf[i].capacity)
			assert(string.find(tags, "%S") and SCV_Graph.validRate(amount), "invalid storage entry")
			local seen = {}
			for tag in string.gmatch(tags, "%S+") do
				if not seen[tag] then
					cap[tag] = (cap[tag] or 0) + amount
					seen[tag] = true
				end
			end
		end
	end)
	return cap, ok
end

-- ---------------------------------------------------------------------------------
-- Per-station read
-- ---------------------------------------------------------------------------------

function SCV_Reader.readStation(st, deps)
	local id64 = st.id64

	-- Info gating. This matters far more now that chains may contain OTHER FACTIONS'
	-- stations: storage amounts and capacity are scan-gated, and vanilla checks them even
	-- for the player's own (menu_station_overview.lua:558). A locked station still takes
	-- part in the diagram - its ROLE in the chain is public - but its numbers read as zero,
	-- so the screen is told and can say so rather than showing a fake empty warehouse.
	local unlockedAmounts  = safe(false, function () return C.IsInfoUnlockedForPlayer(id64, "storage_amounts") end)
	local unlockedCapacity = safe(false, function () return C.IsInfoUnlockedForPlayer(id64, "storage_capacity") end)

	local ratesOut, ratesIn, inventoryKnown, excludedProd, excludedCons, processing, recipes = readTheoreticalRates(id64)
	local outputs, inputs, candidates, _, buildwares, futureResources, rolesKnown, futureProducts, tradewares = readWareRoles(id64, recipes)
	local workforceReserve = readWorkforceReserve(id64)
	local reservations, reservationsKnown = readReservations(id64)
	local capacity, capacityRead = readCapacity(id64)
	local cargo   = safe(nil, GetComponentData, id64, "cargo")
	-- Raw scrap lives in the processing resource buffer, not cargo. Vanilla's
	-- Helper.getResourceBufferAmount (helper.lua:12330) reads this exact property.
	local resourcebuffer = next(processing.feedstocks) and safe(nil, GetComponentData, id64, "resourcebuffer") or nil
	local bufferKnown = unlockedAmounts and type(resourcebuffer) == "table"
	unlockedAmounts = unlockedAmounts and type(cargo) == "table"

	local wares = {}
	for ware in pairs(candidates) do
		local output = outputs[ware] or false
		local input  = inputs[ware] or false

		if output or input then
			local wname     = safe(ware, GetWareData, ware, "name")
			local transport = safe(nil, GetWareData, ware, "transport")

			-- Native station maxima exclude processing: measured with 16 running
			-- scrap processors, 2 waiting Kha'ak processors, and 18 recyclers.
			-- Add the non-overlapping per-processor rates, never recipe base rates.
			local production = safe(nil, function () return C.GetContainerWareProduction(id64, ware, true) end)
			local consumption = safe(nil, function () return C.GetContainerWareConsumption(id64, ware, true) end)
			local workforce = safe(nil, Helper.getWorkforceConsumption, id64, ware)
			local prodKnown = inventoryKnown and not excludedProd[ware] and not processing.excludedProd[ware]
				and (ratesOut[ware] ~= nil or processing.outputs[ware] == true) and SCV_Graph.validRate(production)
			local consKnown = inventoryKnown and not excludedCons[ware] and not processing.excludedCons[ware] and not buildwares[ware]
				and (ratesIn[ware] ~= nil or processing.inputs[ware] or workforceReserve.wares[ware] or (tonumber(workforce) or 0) > 0)
				and SCV_Graph.validRate(consumption) and SCV_Graph.validRate(workforce)
			local prodMax = prodKnown and ((ratesOut[ware] ~= nil and tonumber(production) or 0)
				+ (processing.production[ware] or 0)) or 0
			local consMax = (inventoryKnown and not excludedCons[ware] and ratesIn[ware] ~= nil
				and SCV_Graph.validRate(consumption) and tonumber(consumption) or 0)
				+ (processing.consumption[ware] or 0)
				+ (SCV_Graph.validRate(workforce) and tonumber(workforce) or 0)
			local feedstock = processing.feedstocks[ware]
			local metricOutput = output
			local metricInput = input or (output and (workforceReserve.wares[ware]
				or not workforceReserve.membershipKnown or not SCV_Graph.validRate(workforce) or tonumber(workforce) > 0)) or false
			local workforceOnly = rolesKnown and workforceReserve.membershipKnown and workforceReserve.wares[ware]
				and not recipes.inputs[ware] and not buildwares[ware] and not futureResources[ware] and not tradewares[ware]
			local export
			if output and (recipes.outputs[ware] or futureProducts[ware] or not inventoryKnown)
				and (workforceReserve.wares[ware] or not workforceReserve.membershipKnown or (tonumber(workforce) or 0) > 0) then
				local reserve = workforceReserve.known and SCV_Graph.validRate(workforce)
					and math.max(workforceReserve.reserve[ware] or 0, tonumber(workforce)) or nil
				export = SCV_Metrics.exportDecision(prodKnown and prodMax or nil, reserve, recipes.counts[ware],
					rolesKnown and prodKnown and workforceReserve.known and reserve ~= nil)
				output = export.state == "export" or export.state == "unknown"
				input = export.state == "import"
			end

			-- The GLOBAL GetWareProductionLimit, not C.GetContainerStockLimit, which often
			-- returns 0 (KNOWLEDGEBASE, field-tested).
			--
			-- 0 here means UNKNOWN, not "no capacity", and it is common: a pure trade ware
			-- such as a mining hub's ore has no production limit at all. The previous version
			-- papered over that with limit = max(limit, stock), which had two bad effects -
			-- the fill bar read 100% forever, and hoursToFull saw headroom == 0 and declared
			-- the ware CRITICALLY BACKED UP the moment anything produced it. Keep the raw
			-- value and let consumers of this record decide what an unknown limit means.
			local limit = tonumber(safe(0, GetWareProductionLimit, id64, ware)) or 0
			local stock = tonumber((type(cargo) == "table") and cargo[ware] or 0) or 0
			local stockKnown = unlockedAmounts
			if feedstock then
				stockKnown = bufferKnown
				stock = tonumber(bufferKnown and resourcebuffer[ware] or 0) or 0
			end

			if not stockKnown then stock = 0 end
			if not unlockedCapacity then limit = 0 end    -- unknown, not zero-capacity

			local capacityUnits = 0
			local volume = tonumber(safe(nil, GetWareData, ware, "volume"))
			local capacityUnitsKnown = unlockedCapacity and capacityRead
				and type(transport) == "string" and string.match(transport, "^%S+$") ~= nil
				and SCV_Graph.validRate(volume) and volume > 0
			if capacityUnitsKnown then
				local cap = capacity[tostring(transport)] or 0
				capacityUnits = math.floor(cap / volume)
			end

			wares[ware] = {
				rateBasis   = processing.inputs[ware] and "continuousProcessing" or nil,
				consumptionParts = processing.inputs[ware] and consKnown and {
					processing = processing.consumption[ware] or 0,
					production = ratesIn[ware] ~= nil and tonumber(consumption) or 0,
					workforce = tonumber(workforce), total = consMax } or nil,
				name        = tostring(wname),
				transport   = tostring(transport),
				stock       = stock,
				limit       = limit,                       -- 0 == unknown
				limitKnown  = (limit > 0),
				production  = prodMax,
				consumption = consMax,
				output      = output,
				input       = input,
				metricOutput = metricOutput,
				metricInput = metricInput,
				inputProvenance = workforceOnly and "workforce" or "other",
				export = export,
				-- reserved trades, for the detail panel's bars
				incoming    = (reservations[ware] and reservations[ware].incoming) or 0,
				outgoing    = (reservations[ware] and reservations[ware].outgoing) or 0,
				-- All displayed rates use this same full-operation basis.
				workforce   = tonumber(workforce) or 0,
				workforceKnown = SCV_Graph.validRate(workforce),
				prodMax     = prodMax,
				consMax     = consMax,
				prodKnown   = prodKnown,
				consKnown   = consKnown,
				stockKnown  = stockKnown,
				reservationsKnown = reservationsKnown,
				-- bar fallback when no per-ware allocation exists: the whole capacity for
				-- this transport type, converted from volume to units. Shared between every
				-- ware of that type, so it is an upper bound and the panel says so.
				capacityUnits = capacityUnits,
				capacityUnitsKnown = capacityUnitsKnown,
			}
		end
	end

	local desc = deps.describe(id64) or st
	return {
		id         = st.id,
		id64       = id64,
		name       = desc.name or st.name,
		code       = desc.code or st.code,
		sectorname = desc.sectorname or "",
		wares      = wares,
		logistics  = deps.readLogistics(id64),
		-- Not scanned far enough to read stock levels. The links are still right; the
		-- numbers on them are not.
		locked     = (not unlockedAmounts) or (not unlockedCapacity),
	}
end

-- ---------------------------------------------------------------------------------

return SCV_Reader
