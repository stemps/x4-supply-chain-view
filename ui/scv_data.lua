-- Supply Chain View — the live reader.
--
-- Everything that touches the game lives here, so scv_graph stays testable and scv_menu
-- stays about layout. Its job is to turn station ids into the plain table
-- SCV_Graph.build expects, and to be paranoid while doing it.
--
-- THE GOODS RULE this file implements:
--   output = the station has a SELL offer for the ware, and no module on it CONSUMES it
--   input  = the station has a BUY  offer for the ware, and no module on it PRODUCES it
-- The trade offer is what makes a ware part of the chain at all - it is the station saying
-- "I will give you this" or "I want this". The module test strips internal intermediates:
-- a ware a station both makes and eats never really leaves, so it is not a link.
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
	-- Liveness gate. A destroyed component stops being a station, so this doubles as the
	-- "does it still exist" test without a second call.
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

-- How a station classifies each ware it deals in.
--
-- The engine already computes exactly the distinction the goods rule needs, and vanilla
-- reads it at helper.lua:11746 (Helper.getContainerWareType):
--     availableproducts  -> the station makes this and offers it        => OUTPUT
--     pureresources      -> the station needs this and does not make it => INPUT
--     intermediatewares  -> made AND consumed here                      => EXCLUDED
--     anything else in tradewares -> explicitly traded goods            => depends on
--                                    IsSellable / IsBuyable
-- "intermediatewares" IS the internal-consumer test, done by the engine, so we no longer
-- walk module recipes ourselves.
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

	local outputs, inputs, candidates = {}, {}, {}

	local function note(ware)
		candidates[ware] = true
	end

	for ware in pairs(products) do note(ware) end
	for ware in pairs(pureresources) do note(ware) end
	for ware in pairs(tradewares) do note(ware) end
	for ware in pairs(buildwares) do note(ware) end

	for ware in pairs(candidates) do
		-- The exclusion is applied explicitly rather than trusting the lists to be
		-- disjoint: vanilla's own classifier checks products BEFORE intermediates, which
		-- means a ware in both would read as a product there. The rule says an internal
		-- consumer disqualifies it, so intermediates lose either way.
		if not intermediates[ware] then
			if products[ware] then
				outputs[ware] = true
			end
			if pureresources[ware] or buildwares[ware] then
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
local function readTheoreticalRates(id64)
	local prod, cons = {}, {}
	local excludedProd, excludedCons = {}, {}
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
			-- Operational only: a wrecked or half-built module produces nothing.
			if isprod or isproc then
				local macro = GetComponentData(module, "macro")
				if macro then
					local rates = byMacro[macro]
					if not rates then
						local lib = GetMacroData(macro, "infolibrary")
						local md = lib and GetLibraryEntry(lib, macro)
						assert(md and type(md.products) == "table", "module recipe unavailable: " .. tostring(macro))
						local p, c = SCV_Graph.moduleRates(md and md.products)
						rates = { p = p, c = c }
						byMacro[macro] = rates
					end
					if C.IsComponentOperational(module) then
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
					else
						-- Do not claim an aggregate engine maximum excludes wrecks/construction
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
	return prod, cons, ok, excludedProd, excludedCons
end

-- Storage capacity by transport type (container / solid / liquid...), in VOLUME units.
-- Used only as the bar's fallback denominator when the engine reports no per-ware storage
-- allocation. The struct field is `transport` (helper.lua:91 StorageInfo), not
-- `transporttype`.
local function readCapacity(id64)
	local cap = {}
	pcall(function ()
		local n = C.GetNumCargoTransportTypes(id64, true)
		if n <= 0 then
			return
		end
		local buf = ffi.new("StorageInfo[?]", n)
		n = C.GetCargoTransportTypes(buf, n, id64, true, false)
		for i = 0, n - 1 do
			cap[ffi.string(buf[i].transport)] = tonumber(buf[i].capacity) or 0
		end
	end)
	return cap
end

-- ---------------------------------------------------------------------------------
-- Per-station read
-- ---------------------------------------------------------------------------------

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
	local ratesOut, ratesIn, inventoryKnown, excludedProd, excludedCons = readTheoreticalRates(id64)
	local capacity           = readCapacity(id64)
	local cargo   = safe(nil, GetComponentData, id64, "cargo")
	unlockedAmounts = unlockedAmounts and type(cargo) == "table"

	local wares = {}
	for ware in pairs(candidates) do
		local output = outputs[ware] or false
		local input  = inputs[ware] or false

		if output or input then
			local wname     = safe(ware, GetWareData, ware, "name")
			local transport = safe("container", GetWareData, ware, "transport")

			-- Native maximum rates include effective production modifiers and ignore
			-- temporary input/output stalls. Recipes identify measurable activity only;
			-- their unmodified amounts are NOT used as effective capacity.
			local production = safe(nil, function () return C.GetContainerWareProduction(id64, ware, true) end)
			local consumption = safe(nil, function () return C.GetContainerWareConsumption(id64, ware, true) end)
			local workforce = safe(nil, Helper.getWorkforceConsumption, id64, ware)
			local prodKnown = inventoryKnown and not excludedProd[ware] and ratesOut[ware] ~= nil and SCV_Graph.validRate(production)
			local consKnown = inventoryKnown and not excludedCons[ware] and not buildwares[ware]
				and (ratesIn[ware] ~= nil or (tonumber(workforce) or 0) > 0)
				and SCV_Graph.validRate(consumption) and SCV_Graph.validRate(workforce)
			local prodMax = prodKnown and tonumber(production) or 0
			local consMax = (inventoryKnown and not excludedCons[ware] and ratesIn[ware] ~= nil
				and SCV_Graph.validRate(consumption) and tonumber(consumption) or 0)
				+ (SCV_Graph.validRate(workforce) and tonumber(workforce) or 0)
			if not SCV_Graph.validRate(production) or not SCV_Graph.validRate(consumption) then
				warnOnce("rate:" .. ware, "maximum rate unavailable for " .. ware)
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

			if not unlockedAmounts then stock = 0 end
			if not unlockedCapacity then limit = 0 end    -- unknown, not zero-capacity

			local capacityUnits = 0
			if unlockedCapacity then
				local volume = tonumber(safe(0, GetWareData, ware, "volume")) or 0
				local cap = capacity[tostring(transport)] or 0
				if (volume > 0) and (cap > 0) then
					capacityUnits = math.floor(cap / volume)
				end
			end

			wares[ware] = {
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
				inbound     = ((reservations[ware] and reservations[ware].incoming) or 0) > 0,
				-- All displayed rates use this same full-operation basis.
				workforce   = tonumber(workforce) or 0,
				prodMax     = prodMax,
				consMax     = consMax,
				prodKnown   = prodKnown,
				consKnown   = consKnown,
				stockKnown  = unlockedAmounts,
				reservationsKnown = reservationsKnown,
				-- bar fallback when no per-ware allocation exists: the whole capacity for
				-- this transport type, converted from volume to units. Shared between every
				-- ware of that type, so it is an upper bound and the panel says so.
				capacityUnits = capacityUnits,
			}
		end
	end

	local desc = SCV_Data.describe(id64) or st
	return {
		id         = st.id,
		id64       = id64,
		name       = desc.name or st.name,
		sectorname = desc.sectorname or "",
		wares      = wares,
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
