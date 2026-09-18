-- Depends: scv_text.lua
-- Supply Chain View — the map context menu.
--
-- Right-click one or more stations on the map - yours or anyone's - and get a "Supply
-- Chain" group with the existing chains plus "Create new Supply Chain".
--
-- WHO PROVIDES THIS. Not SirNukes' Interact Menu API - its own source says of vanilla's
-- static config table: "Since config is static, there is no good way to create new
-- subsections. New actions should use existing sections." That is true of THAT api.
-- kuertee UI Extensions ships subst_01.dat, which SUBSTITUTES vanilla's
-- menu_interactmenu.lua and adds a real custom-group mechanism on top. Documented in its
-- README under "Add Nested Sub-Groups to a Custom Actions/Orders Group (via Lua)":
--     m.Add_Custom_Actions_Group(id, text)     -- once at load, idempotent
--     m.insertInteractionGroup(parentId, childId, text)   -- every menu open
--     m.insertInteractionContent(sectionId, entry)        -- every menu open
--     m.registerCallback("prepareSections_on_end", fn, modId)
-- galaxy_trader, kuertee_surface_element_targeting and kuertee_ui_trade_analytics all use
-- the same mechanism, so it is well-trodden rather than exotic.
--
-- UIX is required by both manifests. Keep runtime API probes so an incompatible build
-- does not throw during registration; the top-level tab remains available if an API
-- function is missing.
--
-- The "actions_" id prefix confines the group to the Custom ACTIONS sub-menu rather than
-- also appearing under Custom Orders (UIX README point 6). Stations are not given fleet
-- orders, so appearing under Orders would be noise.

local ffi = require("ffi")
local C = ffi.C

SCV_Interact = {}

local SECTION = "actions_scv_supply_chain"
local MOD_ID  = "supply_chain_view"

local config = {
	textPage = 90210,
	-- Beyond this many chains the context menu stops being a menu and starts being a list.
	-- The screen is the place to manage a large collection.
	maxListedChains = 12,
}

local function log(msg)
	DebugError("SCV: " .. tostring(msg))
end

local T = SCV_Text.forPage(config.textPage)

-- ---------------------------------------------------------------------------------
-- Which stations is this menu about
-- ---------------------------------------------------------------------------------

-- NO OWNERSHIP FILTER, deliberately.
--
-- Analysing another faction's supply chain is a legitimate and interesting use: seeing what
-- feeds an Argon shipyard, or where a rival's bottleneck is. Nothing downstream needs the
-- station to be ours - the ware roles come from the station's own configuration, and the
-- numbers that ARE privileged (stock levels, capacity) are already gated by
-- C.IsInfoUnlockedForPlayer in scv_data, which returns zeroes for anything unscanned rather
-- than leaking it.
--
-- So the only question is whether the thing is a station at all.
local function isStation(id64)
	if (not id64) or (id64 == 0) then
		return false
	end
	local ok, isstation = pcall(function () return C.IsComponentClass(id64, "station") end)
	return ok and isstation and true or false
end

-- The right-clicked object plus everything else currently selected.
--
-- menu.componentSlot.component is the target (vanilla member, documented by the sn api as
-- "Raw component UniverseID, the target of the menu"). menu.selectedotherobjects is the
-- rest of the selection - vanilla member at menu_interactmenu.lua:497, and the sn api
-- documents it as "other objects that are currently selected, eg. ships AND STATIONS",
-- which is what makes multi-select work here.
--
-- Deliberately NOT selectedplayerships: a ship is never a supply chain member.
local function gatherStations(m)
	local seen, out = {}, {}

	local function consider(raw)
		if not raw then
			return
		end
		local id64 = ConvertStringTo64Bit(tostring(raw))
		if (not id64) or seen[tostring(id64)] then
			return
		end
		if isStation(id64) then
			seen[tostring(id64)] = true
			-- A RECORD, not a bare id: the store keys membership on the station code,
			-- because the runtime id will be different after the next savegame load.
			local d = SCV_Data.describe(id64)
			out[#out + 1] = { id = tostring(id64), code = d and d.code or nil }
		end
	end

	if m.componentSlot then
		consider(m.componentSlot.component)
	end
	for _, obj in ipairs(m.selectedotherobjects or {}) do
		consider(obj)
	end

	return out
end

-- ---------------------------------------------------------------------------------
-- What the entries do
-- ---------------------------------------------------------------------------------

-- Both actions hand off through SCV_Store.pending rather than menu parameters. The context
-- menu and the screen share one Lua environment, so a shared table is simpler than the
-- parameter plumbing, and none of it needs to survive a save.
local function openScreen(m)
	-- Same call vanilla uses to jump from the interact menu into a full screen
	-- (menu_interactmenu.lua:3110 does this for the Logical Station Overview).
	Helper.closeMenuAndOpenNewMenu(m, "SCVSupplyChainMenu", { 0, 0 }, true)
end

local function actionCreate(m, stationIds)
	SCV_Store.setPending({ mode = "name", stations = stationIds })
	openScreen(m)
end

local function actionAddTo(m, index, stationIds)
	local added = SCV_Store.addStations(index, stationIds)
	SCV_Store.select(index)
	-- Report the count: "added 3" and "they were all already in there" look identical on
	-- screen otherwise, and the second one reads as a menu entry that did nothing.
	SCV_Store.setPending({ mode = "chain", index = index, added = added,
	                       requested = #stationIds })
	openScreen(m)
end

-- ---------------------------------------------------------------------------------
-- Building the group, every menu open
-- ---------------------------------------------------------------------------------

-- Action registrations are rebuilt from scratch on each menu open (UIX README point 5:
-- "Action registrations must be repeated on every ... signal"), which is exactly what we
-- want - the chain list and the selection both change between openings.
function SCV_Interact.buildActions()
	local m = Helper.getMenu("InteractMenu")
	if not m then
		return
	end

	local stations = gatherStations(m)
	if #stations == 0 then
		-- No station in the selection. Insert nothing; a custom group with no actions is not
		-- drawn, so the entry simply will not appear when right-clicking a ship or empty space.
		return
	end

	local ok, err = pcall(function ()
		m.insertInteractionContent(SECTION, {
			text   = T(2000),
			active = true,
			script = function () actionCreate(m, stations) end,
		})

		local chains = SCV_Store.chains()
		local shown = math.min(#chains, config.maxListedChains)
		for i = 1, shown do
			local chain = chains[i]
			-- Say how many of the selected stations are NOT yet in this chain, so picking
			-- the right one does not require remembering what is already where.
			local missing = 0
			for _, entry in ipairs(stations) do
				if not SCV_Store.contains(i, entry) then
					missing = missing + 1
				end
			end
			local label = T(2001, chain.name)       -- Add to "<name>"
			if missing == 0 then
				label = T(2002, label)              -- Add to "<name>" (already in)
			elseif #stations > 1 then
				label = T(2003, label, tostring(missing)) -- Add to "<name>" (+n)
			end

			m.insertInteractionContent(SECTION, {
				text   = label,
				active = true,
				script = function () actionAddTo(m, i, stations) end,
			})
		end

		if #chains > shown then
			m.insertInteractionContent(SECTION, {
				text   = T(2004, tostring(#chains - shown)),
				active = false,
			})
		end
	end)

	if not ok then
		log("context menu build failed: " .. tostring(err))
	end
end

-- ---------------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------------

local registered = false

function SCV_Interact.tryRegister()
	if registered then
		return true
	end

	local m = Helper and Helper.getMenu and Helper.getMenu("InteractMenu")
	if not m then
		return false
	end

	-- The provider is required, but an incompatible version may lack these functions.
	if (type(m.Add_Custom_Actions_Group) ~= "function")
			or (type(m.registerCallback) ~= "function")
			or (type(m.insertInteractionContent) ~= "function") then
		return false
	end

	local ok, err = pcall(function ()
		-- Idempotent per the UIX README, so calling it again after a /reloadui is safe.
		m.Add_Custom_Actions_Group(SECTION, T(1000))
		m.registerCallback("prepareSections_on_end", SCV_Interact.buildActions, MOD_ID)
	end)

	if not ok then
		log("interact menu registration failed: " .. tostring(err))
		return false
	end

	registered = true
	log("context menu registered (kuertee UI Extensions present)")
	return true
end

local function init()
	if SCV_Interact.tryRegister() then
		return
	end
	-- The InteractMenu may not be in the Menus registry yet at load time, depending on
	-- addon order. Retry once the game is actually up; sn_mod_support_apis provides a
	-- hook for exactly that, and if it is absent we retry on our own menu opening instead
	-- (see scv_menu.onShowMenu).
	if type(Register_OnLoad_Init) == "function" then
		Register_OnLoad_Init(SCV_Interact.tryRegister, "scv_interact")
	end
end

init()

return SCV_Interact
