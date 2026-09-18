-- Supply Chain View — public data facade and initial scan cache.
-- Depends: scv_support.lua, scv_graph.lua, scv_reader.lua, scv_logistics.lua, scv_dock_session.lua, scv_refresh.lua
SCV_Data = { cache = {}, SCAN_CHUNK = 4, REFRESH_INTERVAL = 5 }
local log = SCV_Support.log
local dock = SCV_DockSession.new(function () return SCV_Data.REFRESH_INTERVAL end)
-- Resolve facade methods at call time: UI integrations and tests may replace them.
local deps = {
	describe = function (...) return SCV_Data.describe(...) end,
	readStation = function (...) return SCV_Data.readStation(...) end,
	readLogistics = function (...) return SCV_Data.readLogistics(...) end,
	getInterval = function () return SCV_Data.REFRESH_INTERVAL end,
}
function SCV_Data.describe(...) return SCV_Reader.describe(...) end
function SCV_Data.lookupCode(...) return SCV_Reader.lookupCode(...) end
function SCV_Data.readStation(st) return SCV_Reader.readStation(st, deps) end
function SCV_Data.readLogistics(id64)
	return SCV_Logistics.read(id64, function (...) return SCV_Data.requestDocks(...) end)
end
function SCV_Data.stopLogistics() return dock:stop() end
function SCV_Data.startLogistics(callback) return dock:start(callback) end
function SCV_Data.requestDocks(...) return dock:request(...) end
function SCV_Data.expireDockRequests(now) return dock:expire(now) end
function SCV_Data.onDockCapacity() return dock:onDockCapacity() end
function SCV_Data.newRefresh(members, now) return SCV_Refresh.new(members, now, deps) end
function SCV_Data.refreshStep(state, now) return state:step(now) end

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
	if dock.active then
		local callback = dock.callback
		SCV_Data.startLogistics(callback)
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
