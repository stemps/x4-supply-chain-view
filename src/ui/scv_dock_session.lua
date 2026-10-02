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
	if self.active then UnregisterEvent(dockEvent, self.boundCallback) end
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
	if previous and previous.code == code then logistics.docks = previous.docks end
	self.stations[id] = token
	self.pending[token] = { id = id, code = code, logistics = logistics,
		deadline = pending and pending.code == code and pending.deadline or getElapsedTime() + self.getInterval() }
	safe(nil, AddUITriggeredEvent, "SCVSupplyChainMenu", "dock_capacity",
		{ ConvertStringToLuaID(tostring(id64)), token, code })
end

function SCV_DockSession:expire(now)
	local changed = false
	for token, request in pairs(self.pending) do
		if now >= request.deadline then
			self.pending[token], self.stations[request.id] = nil, nil
			self.last[request.id] = nil
			if next(request.logistics.docks) then changed = true end
			request.logistics.docks = {}
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
				self.last[request.id] = { code = request.code, docks = docks }
				changed = true
			else
				self.last[request.id] = nil
				if next(request.logistics.docks) then changed = true end
				request.logistics.docks = {}
			end
		end
	end
	if changed and self.callback then self.callback() end
end


return SCV_DockSession
