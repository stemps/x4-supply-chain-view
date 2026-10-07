-- Supply Chain View — subordinate and drone reads.
-- Depends: scv_support.lua
local ffi = require("ffi")
local C = ffi.C
local safe, warnOnce = SCV_Support.safe, SCV_Support.warnOnce
SCV_Logistics = {}

local function nonnegativeInteger(value)
	local n = tonumber(value)
	return n and n >= 0 and n < math.huge and n == math.floor(n) and n or nil
end

function SCV_Logistics.read(id64, requestDocks)
	local result = { docks = {}, traders = {}, miners = {}, categories = {} }
	local owner = safe(nil, GetComponentData, id64, "owner")
	result.factionColor = owner and safe(nil, GetFactionData, owner, "color") or nil
	for _, role in ipairs({ "traders", "miners" }) do
		for _, size in ipairs({ "xs", "s", "m", "l", "xl" }) do
			result[role][size] = { total = 0, idle = 0 }
		end
	end
	-- Match vanilla's visibility. The map shows any station's subordinates by type
	-- (menu_map.lua:14481, ungated) but their idle state only for own or allied
	-- stations (menu_map.lua:9569, `isplayerowned or isally`). Dock counts stay
	-- player-only: vanilla shows no per-size free berths for any station, so never
	-- open the MD dock query to foreign stations.
	local playerOwned = safe(false, GetComponentData, id64, "isplayerowned") == true
	local idleVisible = playerOwned or safe(false, GetComponentData, id64, "isally") == true
	result.playerOwned, result.idleVisible = playerOwned, idleVisible
	do
		local ok, err = pcall(function ()
			if not IsValidComponent(id64) then error("station no longer exists") end
			local seen, queue, cursor = {}, { id64 }, 1
			result.shipsKnown, result.idleKnown = true, idleVisible
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
									local orders = idleVisible
										and nonnegativeInteger(safe(nil, function () return C.GetNumOrders(ConvertIDTo64Bit(ship)) end)) or nil
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
		if playerOwned then requestDocks(id64, result) end
	end
	local unitsVisible = safe(false, function () return C.IsInfoUnlockedForPlayer(id64, "units_amount") end)
		and safe(false, function () return C.IsInfoUnlockedForPlayer(id64, "units_details") end)
	if unitsVisible then
		result.drones = nonnegativeInteger(safe(nil, function () return C.GetNumStoredUnits(id64, "transport", false) end))
	end
	return result
end


return SCV_Logistics
