-- Supply Chain View — the live reader.
--
-- Everything that touches the game lives here, so scv_graph stays testable and scv_menu
-- stays about layout. Its job is to turn station ids into the plain table
-- SCV_Graph.build expects, and to be paranoid while doing it.
--
-- THE GOODS RULE this file implements:
--   output = configured product or sellable trade ware, without internal production/build use
--   input  = configured resource, build resource or buyable trade ware, unless output wins
-- Roles do not depend on current stock or live offers. Internal intermediates are excluded;
-- workforce consumption alone does not disqualify an output.
--
-- Consequence worth knowing: a ware that is produced, partly consumed internally, AND sold
-- in surplus does NOT count as an output, because an internal consumer exists. That is the
-- literal rule as specified; a threshold version (sold > internally consumed) would be the
-- natural place to relax it later.

local ffi = require("ffi")
local C = ffi.C

SCV_Data = {}

-- Cache keyed by station id string.
SCV_Data.cache = {}

-- How many stations to (re)read per refresh tick. Small enough that a big chain spreads
-- over a few frames instead of stalling one.
SCV_Data.SCAN_CHUNK = 4
SCV_Data.REFRESH_INTERVAL = 5
SCV_Data.REFRESH_ENABLED = true

local function log(msg)
	DebugError("SCV: " .. tostring(msg))
end

-- pcall wrapper for engine reads.
--
-- IT MUST COMPLAIN. An earlier version returned the fallback in silence, and that hid a
-- real bug for a whole test cycle: GetContainerWareConsumption is FFI-ONLY (declared in
-- helper.lua:322, always called as C.GetContainerWareConsumption). Calling it as a bare
-- global made `fn` nil, pcall failed, and every station reported zero consumption.
-- Messages are de-duplicated, so a per-frame call cannot spam debug.txt.
local warned = {}
local function warnOnce(key, msg)
	if not warned[key] then
		warned[key] = true
		log(msg)
	end
end

local function safe(fallback, fn, ...)
	if type(fn) ~= "function" then
		warnOnce("notafunction", "an engine API name is wrong (got " .. type(fn)
			.. " instead of a function) - check C.X vs global X")
		return fallback
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warnOnce(tostring(result), "engine call failed: " .. tostring(result))
		return fallback
	end
	if result == nil then
		return fallback
	end
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
-- own stored ids through SCV_Data.describe. Re-introducing one would re-introduce the bug.

-- Cheap identity read: name and location only, no ware scan. Used by the context menu and
-- by the member list, both of which run far too often to pay for a full read.
--
-- Returns nil when the id no longer resolves to a live station - destroyed, sold, or from
-- an older save. That nil is the ONLY membership test the mod does: resolving stored ids
-- directly is what keeps a chain independent of any galaxy-wide enumeration.
function SCV_Data.describe(id64)
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

function SCV_Data.lookupCode(code)
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
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	for _, entry in ipairs(list) do
		local ware
		if type(entry) == "string" then
			ware = entry
		elseif type(entry) == "table" then
			ware = entry.ware
		end
		if ware and (ware ~= "") then
			out[ware] = true
		end
	end
	return out
end

-- Wares a station consumes through BUILD processes rather than production modules.
--
-- A shipyard, wharf or equipment dock is a sink for hull parts, claytronics and the rest,
-- but none of them appear in pureresources: that consumption is driven by the build queue,
-- not by a production module. Without this the biggest consumer in a network looks like it
-- needs nothing at all.
local function readBuildResources(id64)
	local out = {}
	pcall(function ()
		local n = C.GetNumContainerBuildResources(id64)
		if n <= 0 then
			return
		end
		local buf = ffi.new("const char*[?]", n)
		n = C.GetContainerBuildResources(buf, n, id64)
		for i = 0, n - 1 do
			out[ffi.string(buf[i])] = true
		end
	end)
	return out
end

-- Future module inventory is classification-only. Never pass these recipes to the
-- operational rate/storage readers. The live engine lists cover completed modules.
-- Vanilla: menu_map.getStationModules and station_overview's planned recipe nodes.
local function readFutureWareRoles(id64)
	local products, resources = {}, {}
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
		if not ok then warnOnce("future-recipe:" .. macro, "planned module " .. macro .. ": " .. tostring(err)) end
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
		n = C.GetStationModules(buf, n, id64, true, true)
		for i = 0, n - 1 do readComponent(ConvertStringTo64Bit(tostring(buf[i]))) end
	end)
	if not ok then warnOnce("future-components", "unfinished module read failed: " .. tostring(err)) end
	ok, err = pcall(function ()
		-- size_t is 64-bit cdata in LuaJIT; numeric for loops require a Lua number.
		local n = tonumber(C.GetNumPlannedStationModules(id64, false))
		if n <= 0 then return end
		local buf = ffi.new("UIConstructionPlanEntry[?]", n)
		n = tonumber(C.GetPlannedStationModules(buf, n, id64, false))
		for i = 0, n - 1 do
			if buf[i].componentid ~= 0 then
				readComponent(ConvertStringTo64Bit(tostring(buf[i].componentid)))
			else
				readMacro(ffi.string(buf[i].macroid))
			end
		end
	end)
	if not ok then warnOnce("future-plan", "planned module read failed: " .. tostring(err)) end
	return products, resources
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
local function readWareRoles(id64)
	local products      = normalizeWareList(safe({}, GetComponentData, id64, "availableproducts"))
	local pureresources = normalizeWareList(safe({}, GetComponentData, id64, "pureresources"))
	local intermediates = normalizeWareList(safe({}, GetComponentData, id64, "intermediatewares"))
	local tradewares    = normalizeWareList(safe({}, GetComponentData, id64, "tradewares"))
	local buildwares    = readBuildResources(id64)
	local futureProducts, futureResources = readFutureWareRoles(id64)
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

	return outputs, inputs, candidates, intermediates, buildwares
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
	local excludedProd, excludedCons = {}, {}
	local processing = { feedstocks = {}, inputs = {}, outputs = {},
		production = {}, consumption = {}, excludedProd = {}, excludedCons = {} }
	local ok, err = pcall(function ()
		local n = C.GetNumStationModules(id64, true, true)
		if n <= 0 then
			return
		end
		local buf = ffi.new("UniverseID[?]", n)
		n = C.GetStationModules(buf, n, id64, true, true)
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
				if macro then
					local rates = byMacro[macro]
					if not rates then
						local lib = GetMacroData(macro, "infolibrary")
						local md = lib and GetLibraryEntry(lib, macro)
						assert(md and type(md.products) == "table", "module recipe unavailable: " .. tostring(macro))
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
	return prod, cons, ok, excludedProd, excludedCons, processing
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

-- Property-owned ship summary: menu_map.getPropertyOwnedFleetDataInternal and
-- getPropertyOwnedGroupIcons_getData. The map's empty order queue defines idle;
-- default orders, cargo and ship speed do not. These C declarations belong to the
-- ego_detailmonitor dependency (menu_map.lua), not Lua globals.
local function nonnegativeInteger(value)
	local n = tonumber(value)
	return n and n >= 0 and n < math.huge and n == math.floor(n) and n or nil
end

function SCV_Data.readLogistics(id64)
	local result = { docks = {}, traders = {}, miners = {}, categories = {} }
	local owner = safe(nil, GetComponentData, id64, "owner")
	result.factionColor = owner and safe(nil, GetFactionData, owner, "color") or nil
	for _, role in ipairs({ "traders", "miners" }) do
		for _, size in ipairs({ "xs", "s", "m", "l", "xl" }) do
			result[role][size] = { total = 0, idle = 0 }
		end
	end
	-- Vanilla's property-owned summary is player-only. Do not expose foreign
	-- subordinate orders or unscanned dock modules through an MD back door.
	if safe(false, GetComponentData, id64, "isplayerowned") == true then
		local ok, err = pcall(function ()
			if not IsValidComponent(id64) then error("station no longer exists") end
			local seen, queue, cursor = {}, { id64 }, 1
			result.shipsKnown, result.idleKnown = true, true
			while cursor <= #queue do
				local ship = queue[cursor]
				cursor = cursor + 1
				local key = tostring(ConvertIDTo64Bit(ship))
				if not seen[key] then
					seen[key] = true
					if IsValidComponent(ship) then
						if key ~= tostring(ConvertIDTo64Bit(id64)) then
							local macro = GetComponentData(ship, "macro")
							local purpose = GetMacroData(macro, "primarypurpose")
							if type(purpose) ~= "string" then error("ship purpose unavailable") end
							local role = purpose == "trade" and "traders" or purpose == "mine" and "miners" or nil
							do
								local size
								for _, candidate in ipairs({ "xl", "l", "m", "s", "xs" }) do
									if C.IsComponentClass(ConvertIDTo64Bit(ship), "ship_" .. candidate) then size = candidate; break end
								end
								if size then
									local ranks = { fight = 5, auxiliary = 4, trade = 3, mine = 2, build = 1 }
									local rank = ({ xs = 10, s = 20, m = 30, l = 40, xl = 50 })[size] + (ranks[purpose] or 0)
									local bucket = result.categories[rank]
									if not bucket then
										bucket = { total = 0, idle = 0, size = size, purpose = purpose, rank = rank }
										bucket.name = safe(nil, GetComponentData, ship, "shiptypename")
										result.categories[rank] = bucket
										if role then result[role][size] = bucket end
									end
									if not bucket.icon then
										local icon = safe(nil, GetMacroData, macro, "primarypurposeicon")
										if type(icon) ~= "string" or icon == "" then icon = safe(nil, GetMacroData, macro, "icon") end
										if type(icon) == "string" and icon ~= "" then bucket.icon = icon end
									end
									bucket.total = bucket.total + 1
									local orders = nonnegativeInteger(safe(nil, function () return C.GetNumOrders(ConvertIDTo64Bit(ship)) end))
									if orders == nil then
										bucket.idleUnknown = true
										if role then result.idleKnown = false end
									elseif orders == 0 then bucket.idle = bucket.idle + 1 end
								else
									result.shipsKnown, result.idleKnown = false, false
								end
							end
						end
						local children = GetSubordinates(ship)
						if type(children) ~= "table" then error("subordinate list unavailable") end
						for _, child in ipairs(children) do queue[#queue + 1] = child end
					end
				end
			end
		end)
		if not ok then
			result.shipsKnown, result.idleKnown = false, false
			warnOnce("logistics-ships:" .. tostring(err), "ship logistics unavailable: " .. tostring(err))
		end
		SCV_Data.requestDocks(id64, result)
	end
	local unitsVisible = safe(false, function () return C.IsInfoUnlockedForPlayer(id64, "units_amount") end)
		and safe(false, function () return C.IsInfoUnlockedForPlayer(id64, "units_details") end)
	if unitsVisible then
		result.drones = nonnegativeInteger(safe(nil, function () return C.GetNumStoredUnits(id64, "transport", false) end))
	end
	return result
end

-- MD responses are a token-keyed mailbox, so several responses arriving before
-- Lua dispatch cannot overwrite one another. Values are lists, avoiding MD's
-- dollar-prefixed named keys at the Lua boundary. Nothing is saved in __SCV_GROUPS.
local dockEvent = "scv_dock_capacity_ready"
local dockMailbox = "$scv_dock_results"
local dockPending, dockStations, dockSerial = {}, {}, 0
local dockLast = {}
local dockActive, dockCallback, dockSession = false, nil, nil

local function clearDockMailbox()
	return safe(nil, function ()
		local player = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
		SetNPCBlackboard(player, dockMailbox, nil)
	end)
end

function SCV_Data.stopLogistics()
	if dockActive then UnregisterEvent(dockEvent, SCV_Data.onDockCapacity) end
	dockActive, dockCallback, dockSession = false, nil, nil
	dockPending, dockStations = {}, {}
	dockLast = {}
end

function SCV_Data.startLogistics(callback)
	SCV_Data.stopLogistics()
	dockActive, dockCallback = true, callback
	dockSession = tostring({}) .. ":" .. tostring(getElapsedTime())
	clearDockMailbox()
	RegisterEvent(dockEvent, SCV_Data.onDockCapacity)
end

function SCV_Data.requestDocks(id64, logistics)
	if not dockActive then return end
	SCV_Data.expireDockRequests(getElapsedTime())
	local id = tostring(id64)
	local pending = dockStations[id] and dockPending[dockStations[id]]
	if dockStations[id] then dockPending[dockStations[id]] = nil end
	dockSerial = dockSerial + 1
	-- MD string table keys must start with '$' (scriptproperties.xml, table).
	local token = "$scv_" .. dockSession .. ":" .. tostring(dockSerial)
	local code = safe(nil, GetComponentData, id64, "idcode")
	if type(code) ~= "string" or code == "" then return end
	-- Preserve the last successful sample while its replacement is in flight.
	-- The cache is session-local and guarded by the station's persistent code.
	local previous = dockLast[id]
	if previous and previous.code == code then logistics.docks = previous.docks end
	dockStations[id] = token
	dockPending[token] = { id = id, code = code, logistics = logistics,
		deadline = pending and pending.code == code and pending.deadline or getElapsedTime() + SCV_Data.REFRESH_INTERVAL }
	safe(nil, AddUITriggeredEvent, "SCVSupplyChainMenu", "dock_capacity",
		{ ConvertStringToLuaID(tostring(id64)), token, code })
end

function SCV_Data.expireDockRequests(now)
	local changed = false
	for token, request in pairs(dockPending) do
		if now >= request.deadline then
			dockPending[token], dockStations[request.id] = nil, nil
			dockLast[request.id] = nil
			if next(request.logistics.docks) then changed = true end
			request.logistics.docks = {}
		end
	end
	if changed and dockCallback then dockCallback() end
end

function SCV_Data.onDockCapacity()
	if not dockActive then return end
	SCV_Data.expireDockRequests(getElapsedTime())
	local results = safe(nil, function () return GetNPCBlackboard(ConvertStringTo64Bit(tostring(C.GetPlayerID())), dockMailbox) end)
	if type(results) ~= "table" then return end
	clearDockMailbox()
	local changed = false
	for token, values in pairs(results) do
		-- MD string keys require '$', but the blackboard bridge strips that
		-- prefix on the Lua side. Accept both bridge representations.
		local correlationToken = type(token) == "string" and token:sub(1, 1) ~= "$" and ("$" .. token) or token
		local request = dockPending[correlationToken]
		if request then
			dockPending[correlationToken], dockStations[request.id] = nil, nil
			local id64 = ConvertStringTo64Bit(request.id)
			local valid = type(values) == "table" and #values == 7 and values[1] == request.code
				and safe(false, IsValidComponent, id64)
				and safe(nil, GetComponentData, id64, "idcode") == request.code
				and safe(false, GetComponentData, id64, "isplayerowned") == true
			local docks = {}
			if valid then
				for i, size in ipairs({ "s", "m", "l" }) do
					local free, total = nonnegativeInteger(values[2 * i]), nonnegativeInteger(values[2 * i + 1])
					if free == nil or total == nil or free > total then valid = false; break end
					docks[size] = { free = free, total = total }
				end
			end
			if valid then
				request.logistics.docks = docks
				dockLast[request.id] = { code = request.code, docks = docks }
				changed = true
			else
				dockLast[request.id] = nil
				if next(request.logistics.docks) then changed = true end
				request.logistics.docks = {}
			end
		end
	end
	if changed and dockCallback then dockCallback() end
end

function SCV_Data.readStation(st)
	local id64 = st.id64

	-- Info gating. This matters far more now that chains may contain OTHER FACTIONS'
	-- stations: storage amounts and capacity are scan-gated, and vanilla checks them even
	-- for the player's own (menu_station_overview.lua:558). A locked station still takes
	-- part in the diagram - its ROLE in the chain is public - but its numbers read as zero,
	-- so the screen is told and can say so rather than showing a fake empty warehouse.
	local unlockedAmounts  = safe(false, function () return C.IsInfoUnlockedForPlayer(id64, "storage_amounts") end)
	local unlockedCapacity = safe(false, function () return C.IsInfoUnlockedForPlayer(id64, "storage_capacity") end)

	local outputs, inputs, candidates, _, buildwares = readWareRoles(id64)
	local reservations, reservationsKnown = readReservations(id64)
	local ratesOut, ratesIn, inventoryKnown, excludedProd, excludedCons, processing = readTheoreticalRates(id64)
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
				and (ratesIn[ware] ~= nil or processing.inputs[ware] or (tonumber(workforce) or 0) > 0)
				and SCV_Graph.validRate(consumption) and SCV_Graph.validRate(workforce)
			local prodMax = prodKnown and ((ratesOut[ware] ~= nil and tonumber(production) or 0)
				+ (processing.production[ware] or 0)) or 0
			local consMax = (inventoryKnown and not excludedCons[ware] and ratesIn[ware] ~= nil
				and SCV_Graph.validRate(consumption) and tonumber(consumption) or 0)
				+ (processing.consumption[ware] or 0)
				+ (SCV_Graph.validRate(workforce) and tonumber(workforce) or 0)
			local feedstock = processing.feedstocks[ware]

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
				-- reserved trades, for the detail panel's bars
				incoming    = (reservations[ware] and reservations[ware].incoming) or 0,
				outgoing    = (reservations[ware] and reservations[ware].outgoing) or 0,
				-- All displayed rates use this same full-operation basis.
				workforce   = tonumber(workforce) or 0,
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

	local desc = SCV_Data.describe(id64) or st
	return {
		id         = st.id,
		id64       = id64,
		name       = desc.name or st.name,
		code       = desc.code or st.code,
		sectorname = desc.sectorname or "",
		wares      = wares,
		logistics  = SCV_Data.readLogistics(id64),
		-- Not scanned far enough to read stock levels. The links are still right; the
		-- numbers on them are not.
		locked     = (not unlockedAmounts) or (not unlockedCapacity),
	}
end

-- ---------------------------------------------------------------------------------
-- Chunked scanning
-- ---------------------------------------------------------------------------------

-- Read up to SCAN_CHUNK stations per call, and report whether more work remains. The menu
-- calls this from onUpdate until it returns done, so a twelve-station chain costs three
-- quiet frames instead of one long one - a full rescan inside a single callback is a known
-- crash risk.
--
-- Returns: stations (array, cached entries included), done (bool)
function SCV_Data.scanGroup(members, force)
	local pending, out = {}, {}

	for _, st in ipairs(members) do
		local cached = SCV_Data.cache[st.id]
		if force or (not cached) then
			pending[#pending + 1] = st
		else
			out[#out + 1] = cached
		end
	end

	local budget, i = SCV_Data.SCAN_CHUNK, 1
	while (i <= #pending) and (budget > 0) do
		local st = pending[i]
		local ok, result = pcall(SCV_Data.readStation, st)
		if ok and result then
			SCV_Data.cache[st.id] = result
			out[#out + 1] = result
		else
			log("failed to read station " .. tostring(st.name) .. ": " .. tostring(result))
			-- Keep a stub so the station still appears rather than vanishing silently.
			local stub = { id = st.id, id64 = st.id64, name = st.name, wares = {}, failed = true }
			SCV_Data.cache[st.id] = stub
			out[#out + 1] = stub
		end
		budget = budget - 1
		i = i + 1
	end

	return out, (i > #pending)
end

function SCV_Data.invalidate(id)
	if id then
		SCV_Data.cache[id] = nil
	else
		SCV_Data.cache = {}
	end
	-- A changed chain cannot accept replies requested by its predecessor.
	if dockActive then
		local callback = dockCallback
		SCV_Data.startLogistics(callback)
	end
end

-- The menu owns this short-lived state. Dropping it cancels the sweep, with no
-- partial writes to the displayed records or shared cache. Keep a separate cursor:
-- scanGroup(force=true) would repeatedly read the first SCAN_CHUNK members.
function SCV_Data.newRefresh(members, now)
	local copy = {}
	for _, st in ipairs(members) do
		copy[#copy + 1] = { id = st.id, id64 = st.id64, name = st.name, code = st.code }
	end
	return { members = copy, nextStart = now + SCV_Data.REFRESH_INTERVAL }
end

function SCV_Data.refreshStep(state, now)
	if not SCV_Data.REFRESH_ENABLED or #state.members == 0 then return nil end
	if not state.pending then
		if now < state.nextStart then return nil end
		state.pending, state.cursor = {}, 1
		state.nextStart = now + SCV_Data.REFRESH_INTERVAL
	end
	local st = state.members[state.cursor]
	local ok, result = pcall(function ()
		local live = SCV_Data.describe(st.id64 or st.id)
		if not live or (st.code and live.code ~= st.code) then
			return { id = st.id, name = st.name, wares = {}, missing = true }
		end
		return SCV_Data.readStation(st)
	end)
	if not ok or not result then
		warnOnce("refresh:" .. st.id, "refresh failed for station " .. tostring(st.name) .. ": " .. tostring(result))
		result = { id = st.id, name = st.name, wares = {}, failed = true }
	end
	state.pending[#state.pending + 1] = result
	state.cursor = state.cursor + 1
	if state.cursor > #state.members then
		local snapshot = state.pending
		state.pending, state.cursor = nil, nil
		return snapshot
	end
	return nil
end

local function init()
	SCV_Data.version = 2
	if not SCV_Graph then
		-- The ui.xml load order guarantees scv_graph runs first. If this fires, that
		-- ordering has been broken and everything downstream would fail confusingly.
		log("SCV_Graph missing - check the <file> order in ui.xml")
	end
end

init()

return SCV_Data
