-- Supply Chain View — asynchronous dock request session.
-- Depends: scv_support.lua
local ffi = require("ffi")
local C = ffi.C
local safe = SCV_Support.safe
SCV_DockSession = {}
SCV_DockSession.__index = SCV_DockSession

-- The bound callback remains identical for registration and unregistration.
function SCV_DockSession.new(getInterval)
	local self = setmetatable({ pending = {}, stations = {}, serial = 0,
		last = {}, active = false, getInterval = getInterval }, SCV_DockSession)
	self.boundCallback = function () self:onDockCapacity() end
	return self
end

local function nonnegativeInteger(value)
	local n = tonumber(value)
	return n and n >= 0 and n < math.huge and n == math.floor(n) and n or nil
end

-- MD responses are a token-keyed mailbox, so several responses arriving before
-- Lua dispatch cannot overwrite one another. Values are lists, avoiding MD's
-- dollar-prefixed named keys at the Lua boundary. Nothing is saved in __SCV_GROUPS.
local dockEvent = "scv_dock_capacity_ready"
local dockMailbox = "$scv_dock_results"




local function clearDockMailbox()
	return safe(nil, function ()
		local player = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
		SetNPCBlackboard(player, dockMailbox, nil)
	end)
end

function SCV_DockSession:stop()
	if self.active then
		UnregisterEvent(dockEvent, self.boundCallback)
		-- MD keeps a dock queue watch armed only while SCV asks. Its own watchdog
		-- disarms it too, so a lost stop event costs at most one linger period.
		safe(nil, AddUITriggeredEvent, "SCVSupplyChainMenu", "dock_watch_stop")
	end
	self.active, self.callback, self.session = false, nil, nil
	self.pending, self.stations = {}, {}
	self.last = {}
end

function SCV_DockSession:start(callback)
	self:stop()
	self.active, self.callback = true, callback
	self.session = tostring({}) .. ":" .. tostring(getElapsedTime())
	clearDockMailbox()
	RegisterEvent(dockEvent, self.boundCallback)
end

function SCV_DockSession:request(id64, logistics)
	if not self.active then
		return
	end
	self:expire(getElapsedTime())
	local id = tostring(id64)
	local pending = self.stations[id] and self.pending[self.stations[id]]
	if self.stations[id] then self.pending[self.stations[id]] = nil end
	self.serial = self.serial + 1
	-- MD string table keys must start with '$' (scriptproperties.xml, table).
	local token = "$scv_" .. self.session .. ":" .. tostring(self.serial)
	local code = safe(nil, GetComponentData, id64, "idcode")
	if type(code) ~= "string" or code == "" then
		return
	end
	-- Preserve the last successful sample while its replacement is in flight.
	-- The cache is session-local and guarded by the station's persistent code.
	local previous = self.last[id]
	if previous and previous.code == code then logistics.docks, logistics.queue = previous.docks, previous.queue end
	self.stations[id] = token
	self.pending[token] = { id = id, code = code, logistics = logistics,
		deadline = pending and pending.code == code and pending.deadline or getElapsedTime() + self.getInterval() }
	safe(nil, AddUITriggeredEvent, "SCVSupplyChainMenu", "dock_capacity",
		{ ConvertStringToLuaID(tostring(id64)), token, code })
end

-- Dock fields are free/total per size for own stations and -1 for foreign
-- ones, where vanilla shows no per-size berths. Returns nil for any other shape.
local function parseDocks(values, owned)
	local docks = {}
	for i, size in ipairs({ "s", "m", "l" }) do
		local free, total = values[2 * i], values[2 * i + 1]
		if owned then
			free, total = nonnegativeInteger(free), nonnegativeInteger(total)
			if free == nil or total == nil or free > total then return nil end
			docks[size] = { free = free, total = total }
		elseif free ~= -1 or total ~= -1 then
			return nil
		end
	end
	return docks
end

-- count is nil while the MD watch is still warming up: a fresh listener has not
-- yet seen a full re-request cycle, so zero would be a guess.
local function parseQueue(values)
	local count = values[8] ~= -1 and nonnegativeInteger(values[8]) or nil
	local traffic = nonnegativeInteger(values[9])
	if (count == nil and values[8] ~= -1) or traffic == nil or traffic > 2 or type(values[10]) ~= "table" then
		return nil
	end
	local ships = {}
	for _, name in ipairs(values[10]) do
		if type(name) ~= "string" then return nil end
		ships[#ships + 1] = name
	end
	if count ~= nil and #ships > count then return nil end
	return { count = count, traffic = traffic, ships = ships }
end

local function clearSample(logistics)
	local had = next(logistics.docks) ~= nil or logistics.queue ~= nil
	logistics.docks, logistics.queue = {}, nil
	return had
end

function SCV_DockSession:expire(now)
	local changed = false
	for token, request in pairs(self.pending) do
		if now >= request.deadline then
			self.pending[token], self.stations[request.id] = nil, nil
			self.last[request.id] = nil
			if clearSample(request.logistics) then changed = true end
		end
	end
	if changed and self.callback then self.callback() end
end

function SCV_DockSession:onDockCapacity()
	if not self.active then return end
	self:expire(getElapsedTime())
	local results = safe(nil, function () return GetNPCBlackboard(ConvertStringTo64Bit(tostring(C.GetPlayerID())), dockMailbox) end)
	if type(results) ~= "table" then return end
	clearDockMailbox()
	local changed = false
	for token, values in pairs(results) do
		-- MD string keys require '$', but the blackboard bridge strips that
		-- prefix on the Lua side. Accept both bridge representations.
		local correlationToken = type(token) == "string" and token:sub(1, 1) ~= "$" and ("$" .. token) or token
		local request = self.pending[correlationToken]
		if request then
			self.pending[correlationToken], self.stations[request.id] = nil, nil
			local id64 = ConvertStringTo64Bit(request.id)
			local docks, queue
			if type(values) == "table" and #values == 10 and values[1] == request.code
				and safe(false, IsValidComponent, id64)
				and safe(nil, GetComponentData, id64, "idcode") == request.code then
				docks = parseDocks(values, safe(false, GetComponentData, id64, "isplayerowned") == true)
				queue = docks and parseQueue(values)
			end
			if docks and queue then
				request.logistics.docks, request.logistics.queue = docks, queue
				self.last[request.id] = { code = request.code, docks = docks, queue = queue }
				changed = true
			else
				self.last[request.id] = nil
				if clearSample(request.logistics) then changed = true end
			end
		end
	end
	if changed and self.callback then self.callback() end
end


return SCV_DockSession
