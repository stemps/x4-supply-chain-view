-- Supply Chain View — the screen.
--
-- Two modes only:
--   "name"  a new chain is being created; enter a name and confirm
--   "chain" the diagram for the selected chain
-- Chains are CREATED and stations are ADDED from the map context menu (scv_interact), so
-- this file no longer carries a group editor.
--
-- Structure and lifecycle follow menu_research.lua, the smallest complete flowchart menu
-- in the game. The node/junction/edge render loop follows
-- menu_station_overview.lua:1774-1915, the one that drives a Helper.setupDAGLayout result
-- rather than placing nodes by hand.

local ffi = require("ffi")
local C = ffi.C

local menu = {
	name = "SCVSupplyChainMenu",
}

local config = {
	mainFrameLayer         = 5,
	expandedMenuFrameLayer = 4,
	topLevelId             = "scv_supplychain",
	textPage               = 90210,
	-- Station names run long ("2 - Factory - Asteroid Belt - Computronic Substrate") and the
	-- node must also fit a status figure on the right; at 250px they were cut off mid-word.
	-- Ware names are short, and widening them too would only fit fewer tiers on screen.
	stationNodeWidth       = 310,
	wareNodeWidth          = 260,
	nodeOffsetX            = 20,
	sideWidth              = 320,
	-- Capacity balance bar runs 0 .. this; 1.0x (supply equals demand) sits in the middle so
	-- a shortfall and a surplus get equal room.
	balanceScale           = 2,
	-- Net flow smaller than this fraction of demand capacity counts as flat, so the stock
	-- figure does not flicker between green and red on a balanced ware.
	trendDeadband          = 0.02,
	nameFieldWidth         = 420,
	savedVersion           = 2,
	consumptionColor       = { r = 255, g = 150, b = 150, a = 100, glow = 0 },
}

local function log(msg)
	DebugError("SCV: " .. tostring(msg))
end

-- NEVER returns nil. A nil handed to createText leaves the cell empty, which the widget
-- system escalates into "Content element is missing" and then aborts the ENTIRE frame -
-- the screen simply stops updating with no clue why. A visible placeholder beats a frozen
-- menu.
local warnedText = {}

local function T(id, ...)
	local ok, s = pcall(ReadText, config.textPage, id)

	-- A text id the engine cannot resolve comes back as the literal placeholder
	-- "=ReadText90210-3016=", which is a perfectly good non-empty string and so sailed
	-- straight through the old check and into the UI.
	--
	-- The usual cause is not a missing entry: /reloadui reloads LUA ONLY, not t/ files, so
	-- any string added in the same edit is absent until the game is restarted. Rather than
	-- render the placeholder, fall back to the format ARGUMENTS - they are the actual data,
	-- so "12.4k 0/h" still tells you something where "=ReadText90210-3016=" tells you
	-- nothing. Log once per id so debug.txt names exactly which ones are unresolved.
	local unresolved = (not ok) or (type(s) ~= "string") or (s == "")
			or (string.sub(s, 1, 9) == "=ReadText")

	if unresolved then
		if not warnedText[id] then
			warnedText[id] = true
			log("text id " .. tostring(id) .. " unresolved - restart the game if it was just "
				.. "added (/reloadui does not reload t/ files)")
		end
		if select("#", ...) > 0 then
			local parts = {}
			for i = 1, select("#", ...) do
				parts[#parts + 1] = tostring((select(i, ...)))
			end
			return table.concat(parts, " ")
		end
		return "SCV#" .. tostring(id)
	end

	if select("#", ...) > 0 then
		local okf, formatted = pcall(string.format, s, ...)
		if okf then
			return formatted
		end
	end
	return s
end

-- ---------------------------------------------------------------------------------
-- Menu registration
-- ---------------------------------------------------------------------------------

local function registerTopLevel()
	if (not Helper) or (type(Helper.topLevelMenus) ~= "table") then
		log("Helper.topLevelMenus unavailable - top level tab skipped")
		return
	end
	for _, entry in ipairs(Helper.topLevelMenus) do
		if entry.id == config.topLevelId then
			return    -- already inserted; a UI reload re-runs this file
		end
	end
	-- No gating fields. Every check in Helper.checkTopLevelConditions is guarded by
	-- "if (entry.X ~= nil)", so an entry declaring none of them always passes. The icon is
	-- an existing vanilla one, so no texture ships with this mod.
	table.insert(Helper.topLevelMenus, {
		id              = config.topLevelId,
		name            = T(1000),
		icon            = "mapob_factory",
		shortcut        = "",
		menu            = menu.name,
		helpOverlayID   = "toplevel_" .. config.topLevelId,
		helpOverlayText = " ",
		param           = { 0, 0 },
	})
end

-- Idempotent: a UI reload (/reloadui, dispatched through ExecuteDebugCommand from the chat
-- window) re-runs this file, and whether the Lua environment is rebuilt or reused is not
-- something we control. Registering twice would leave two copies in the Menus registry and
-- two tabs in the top-level bar.
local function init()
	Menus = Menus or {}
	for _, existing in ipairs(Menus) do
		if existing.name == menu.name then
			return
		end
	end
	table.insert(Menus, menu)
	if Helper then
		Helper.registerMenu(menu)
	end
	registerTopLevel()
end

function menu.cleanup()
	menu.mode            = "chain"
	menu.graph           = nil
	menu.scanDone        = nil
	menu.pendingStations = nil
	menu.nameText        = nil
	menu.notice          = nil
	menu.expandedNode    = nil
	menu.expandedMenuFrame = nil
	menu.refresh         = nil
	menu.topLevelOffsetY = nil
	menu.flowchart       = nil
end

function menu.onShowMenu()
	SCV_Store.load()

	-- The InteractMenu may not have existed in the Menus registry when scv_interact loaded.
	-- Opening this screen is a cheap, reliable moment to try again.
	if SCV_Interact and SCV_Interact.tryRegister then
		pcall(SCV_Interact.tryRegister)
	end

	menu.mode   = "chain"
	menu.notice = nil

	-- Handoff from the context menu.
	local pending = SCV_Store.takePending()
	if pending then
		if pending.mode == "name" then
			menu.mode            = "name"
			menu.pendingStations = pending.stations or {}
			menu.nameText        = T(1014, tostring(SCV_Store.count() + 1))
		elseif pending.mode == "chain" then
			SCV_Store.select(pending.index)
			if (pending.added or 0) == 0 then
				menu.notice = T(3020)                                   -- already in this chain
			else
				menu.notice = T(3021, tostring(pending.added))          -- added n station(s)
			end
		end
	end

	-- No galaxy-wide station scan here any more: chains resolve their own ids, and the
	-- name-entry preview describes the ids the context menu handed over.
	SCV_Data.invalidate()
	menu.scanDone = false

	menu.display()
end

menu.updateInterval = 0.2

function menu.onUpdate()
	-- Chunked scanning: pull stations in a few at a time until the chain is fully read,
	-- then redraw once. A full rescan inside one callback is the crash risk this avoids.
	if not menu.scanDone then
		local members = menu.currentMembers()
		if #members == 0 then
			menu.scanDone = true
		else
			local _, done = SCV_Data.scanGroup(members, false)
			if done then
				menu.scanDone = true
				menu.display()
			end
		end
	end

	if menu.refresh and (menu.refresh <= getElapsedTime()) then
		menu.refresh = nil
		menu.display()
	end
end

function menu.onCloseElement(dueToClose, layer)
	if (layer == config.expandedMenuFrameLayer) and menu.expandedNode then
		menu.expandedNode:collapse()
		return
	end
	Helper.closeMenu(menu, dueToClose)
	menu.cleanup()
end

function menu.createTopLevel(frame)
	menu.topLevelOffsetY = Helper.createTopLevelTab(menu, config.topLevelId, frame, "", nil, true)
end

function menu.onTabScroll(direction)
	if direction == "right" then
		Helper.scrollTopLevel(menu, config.topLevelId, 1)
	elseif direction == "left" then
		Helper.scrollTopLevel(menu, config.topLevelId, -1)
	end
end

-- ---------------------------------------------------------------------------------
-- Chain helpers
-- ---------------------------------------------------------------------------------

-- Resolve the chain's stored ids DIRECTLY, one at a time.
--
-- An earlier version looked each id up in a galaxy-wide GetContainedStationsByOwner list
-- and dropped anything absent from it. That silently lost stations: both vanilla uses of
-- that call are build-plot code, so it is not a general "all my stations" enumeration, and
-- membership must not depend on one. A chain owns its ids; the only question per id is
-- whether that station still exists, which SCV_Data.describe answers by returning nil.
--
-- Stations that have genuinely gone (destroyed, sold) are counted so the screen can say so
-- instead of quietly showing a shorter chain than the one you built.
function menu.currentMembers()
	local chain, idx = SCV_Store.selected()
	if not chain then
		menu.missingMembers = 0
		return {}
	end
	-- Re-link members to the live world. Runtime ids change on every savegame load, so a
	-- member is verified by its station CODE and re-found by code when its id has gone
	-- stale; SCV_Store.reconcile saves the fresh ids so later sessions take the fast path.
	local live, missing = SCV_Store.reconcile(idx, SCV_Data.describe, SCV_Data.lookupCode)
	menu.missingMembers = missing
	return live
end

function menu.markDirty()
	SCV_Data.invalidate()
	menu.scanDone = false
	menu.refresh = getElapsedTime() + 0.05
end

-- ---------------------------------------------------------------------------------
-- Node decoration
-- ---------------------------------------------------------------------------------

local function severityColor(severity)
	if severity == "critical" then
		return Color["icon_error"]
	elseif severity == "warning" then
		return Color["icon_warning"]
	end
	return nil
end

local function severityIcon(severity)
	if severity == "critical" then
		return "lso_error"
	elseif severity == "warning" then
		return "lso_warning"
	end
	return nil
end

-- Compact amounts: a chain deals in tens of thousands, and "12400" in a node status is
-- noise where "12.4k" is a number you can read at a glance.
local function formatAmount(n)
	n = tonumber(n) or 0
	local a = math.abs(n)
	if a >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	elseif a >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	return string.format("%.0f", n)
end

local function formatRate(n)
	return formatAmount(n) .. "/h"
end

local function formatPartial(n, known, rate)
	local value = rate and formatRate(n) or formatAmount(n)
	if known then return value end
	return (n or 0) > 0 and (value .. " + ?") or (rate and "? /h" or "?")
end

-- Hours as something readable. Below an hour, minutes are what you act on.
local function formatHours(hours)
	if not hours then
		return T(5002)
	end
	if hours < 1 then
		return T(5001, tostring(math.max(1, math.floor(hours * 60))))
	end
	return T(5000, string.format("%.1f", hours))
end

local function warningReason(name, health)
	if not health or health.severity == "ok" then return nil end
	local label = health.reason == "backedup" and T(3004) or T(3003)
	local threshold = health.severity == "critical" and SCV_Graph.THRESHOLDS.criticalHours
		or SCV_Graph.THRESHOLDS.warningHours
	return T(3066, name, label, formatHours(health.hours),
		T(health.severity == "critical" and 3067 or 3068), formatHours(threshold))
end

-- Turn SCV_Graph's structural nodes into the shape the flowchart render loop wants: a
-- table whose ARRAY part holds one entry per stacked sub-cell, each with .properties. The
-- clearest statement of that contract is vanilla's own dummy node builder
-- (getFlowchartDummyProductionNodes, menu_station_overview.lua:1610).
--
-- Decorating IN PLACE matters: Helper.setupDAGLayout keys predecessors by table identity,
-- so these must be the very tables SCV_Graph linked together, not copies.
function menu.decorateNodes(graph)
	for _, node in ipairs(graph.nodes) do
		if node.scvkind == "station" then
			local parts = {}
			if node.worstWare then
				local w = node.wares[node.worstWare]
				local h = w and w.health
				if h and (h.severity ~= "ok") then
					parts[#parts + 1] = warningReason(w.name or node.worstWare, h)
				end
			end
			if #node.unmet > 0 then
				parts[#parts + 1] = T(3005) .. ": " .. #node.unmet
			end
			if #node.unsold > 0 then
				parts[#parts + 1] = T(3006) .. ": " .. #node.unsold
			end
			if #node.collapsed > 0 then
				parts[#parts + 1] = T(4002, tostring(#node.collapsed))
			end
			if not node.healthKnown then parts[#parts + 1] = T(3065) end

			node.text = node.name
			node.type = "container"
			node[1] = {
				properties = {
					shape         = "rectangle",
					width         = config.stationNodeWidth,
					mouseOverText = (#parts > 0) and table.concat(parts, "\n") or T(3014),
				},
				statuscolor = severityColor(node.severity),
				color       = (node.severity == "critical") and Color["lso_node_error"] or nil,
			}
			-- statusText and statusIcon are mutually exclusive in the render loop
			-- (setStatusText wins), so only set the icon when there is no text.
			-- The bare figure was ambiguous: "1m" meant time-to-EMPTY for a starved input
			-- but time-to-FULL for a backed-up output - opposite meanings, identical glyph.
			-- Prefixing it costs three characters and removes the guesswork.
			if node.severity ~= "ok" then
				local w = node.wares[node.worstWare]
				local h = w and w.health
				local hours = formatHours(h and h.hours)
				if h and (h.reason == "backedup") then
					node[1].statusText = T(3027, hours)     -- "full <t>"
				else
					node[1].statusText = T(3028, hours)     -- "dry <t>"
				end
			else
				node[1].statusIcon = severityIcon(node.severity)
			end
		else
			-- WARE NODE: three questions, one cell.
			--
			--   BAR      can the chain SUSTAIN it?   capacity balance, supply / demand
			--   STATUS   how much is BANKED?          total stock, coloured by trend
			--   OUTLINE  is anyone about to STALL?    the consumer that runs dry first
			--
			-- The bar used to be hours of cover capped at 4.5h, and it saturated: food and
			-- medical supplies buffered for hundreds of hours all read 100%, so a ware holding
			-- 636k and one holding 54k looked identical and nothing short of an imminent stall
			-- showed at all.

			-- BAR: capacity balance on a 0 - 2x scale, both sliders parked on 1.0x.
			-- With step = 0 the sliders are shading, not handles (helper.lua flowchartnode
			-- defaults), and their two rules combine into a readable bar:
			--   slider1 shades from the value UP to it   -> short of 1.0x: the missing
			--                                              capacity shows in orange
			--   slider2 shades from it UP to the value   -> past 1.0x: the spare capacity
			--                                              shows in green
			-- so blue reaches as far as supply meets demand, orange is the shortfall and
			-- green is the headroom.
			local barValue, barMax, s1, s2 = 0, 1, -1, -1
			if node.balance then
				barMax   = config.balanceScale
				barValue = math.min(node.balance, config.balanceScale)
				s1, s2   = 1, 1
			end

			-- ONE full-operation line. supplyCap and demandCap used to be printed TWICE -
			-- once as a ratio and once as a difference - and because the two lines were
			-- worded differently they read as two contradicting measurements of the same
			-- ware. netRate is defined as supplyCap - demandCap, so the second line never
			-- carried information the first did not.
			local lines = {}
			lines[#lines + 1] = T(3015, tostring(#node.producers), tostring(#node.consumers))
			lines[#lines + 1] = T(3050,
				formatPartial(node.supplyCap, node.supplyKnown, true),
				formatPartial(node.demandCap, node.demandKnown, true),
				node.balance and string.format("%.2fx", node.balance) or "?")
			if node.balance then
				-- The shortfall in units/h belongs here, where it explains the orange: a
				-- ratio says how bad, this says by how much.
				if node.balance < 1 then
					lines[#lines + 1] = T(3072, formatRate(math.abs(node.netRate or 0)))
				end
			elseif node.balanceUnknown == "supply" then
				lines[#lines + 1] = T(3051)
			elseif node.balanceUnknown == "zero-demand" then
				lines[#lines + 1] = T(3063)
			else
				lines[#lines + 1] = T(3052)
			end
			lines[#lines + 1] = T(3053, formatPartial(node.supplyStock, node.supplyStockKnown), formatPartial(node.demandStock, node.demandStockKnown))
			if node.worstConsumer and node.worstCover then
				local sn = graph.stationNodes[node.worstConsumer]
				lines[#lines + 1] = T(3055, (sn and sn.name) or "?", formatHours(node.worstCover))
				local w = sn and sn.wares[node.scvware]
				local reason = warningReason((sn and sn.name) or "?", w and w.health)
				if reason then lines[#lines + 1] = reason end
			end
			lines[#lines + 1] = node.inbound and T(3010) or T(3011)

			-- Colour shows production balance at full operation, not observed stock movement.
			local trend = not node.netKnown and Color["text_inactive"] or nil
			local deadband = math.max(1, node.demandCap * config.trendDeadband)
			if node.netKnown and node.netRate > deadband then
				trend = Color["text_positive"]
			elseif node.netKnown and node.netRate < -deadband then
				trend = Color["text_negative"]
				lines[#lines + 1] = T(3073)
			end

			-- OUTLINE: urgency from the consumer that runs dry first.
			local outline = nil
			if node.severity == "critical" then
				outline = Color["lso_node_error"]
			elseif node.severity == "warning" then
				outline = Color["lso_node_warning"]
			end

			node.text = node.name
			node[1] = {
				properties = {
					shape         = "stadium",
					width         = config.wareNodeWidth,
					value         = barValue,
					max           = barMax,
					step          = 0,       -- shading overlays, not draggable handles
					slider1       = s1,
					slider2       = s2,
					slider1MouseOverText = (s1 >= 0) and T(3056) or "",
					slider2MouseOverText = (s2 >= 0) and T(3056) or "",
					mouseOverText = table.concat(lines, "\n"),
				},
				statusText  = formatPartial(node.totalStock, node.supplyStockKnown and node.demandStockKnown),
				statuscolor = trend,
				color       = outline,
			}
		end
	end
end

-- ---------------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------------

-- How tall a table may grow before it must scroll instead.
--
-- maxVisibleHeight defaults to 0, which the widget system reads as "no maximum" - and a
-- table with no maximum that does not fit is NOT clipped or scrolled, it is REFUSED:
--   "Vertical space left (N) doesn't suffice to display the requested table ...
--    Table will not be displayed."
-- Nothing renders and nothing complains, so the screen just appears not to react.
local function availableHeight(y)
	return math.max(Helper.scaleY(120), Helper.viewHeight - y - Helper.frameBorder)
end

function menu.display()
	Helper.clearDataForRefresh(menu)
	-- A redraw destroys any open detail panel along with everything else; holding on to the
	-- node would make the next close try to collapse a node that no longer exists.
	menu.expandedNode = nil
	menu.expandedMenuFrame = nil

	menu.frame = Helper.createFrameHandle(menu, {
		layer = config.mainFrameLayer, width = Helper.viewWidth, height = Helper.viewHeight,
		x = 0, y = 0 })
	menu.frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

	menu.createTopLevel(menu.frame)

	local topY = (menu.topLevelOffsetY or 0) + Helper.borderSize
	local sideWidth = Helper.scaleX(config.sideWidth)
	local rightBarX = Helper.viewWidth - Helper.scaleX(Helper.sidebarWidth) - Helper.frameBorder
	local contentWidth = rightBarX - Helper.frameBorder - Helper.borderSize

	if menu.mode == "name" then
		menu.displayNameEntry(menu.frame, Helper.frameBorder, topY, contentWidth)
	else
		menu.displayChainList(menu.frame, Helper.frameBorder, topY, sideWidth)
		menu.displayChain(menu.frame,
			Helper.frameBorder + sideWidth + Helper.borderSize, topY,
			contentWidth - sideWidth - Helper.borderSize)
	end

	menu.frame:display()
end

-- Naming a brand new chain. This is the only place the mod takes text input.
function menu.displayNameEntry(frame, x, y, width)
	local ftable = frame:addTable(2, { tabOrder = 1, width = math.min(width, Helper.scaleX(700)),
		x = x, y = y, maxVisibleHeight = availableHeight(y) })
	ftable:setColWidth(2, Helper.scaleX(140), false)

	local row = ftable:addRow(false, { fixed = true })
	row[1]:setColSpan(2):createText(T(2000), Helper.headerRowCenteredProperties)

	row = ftable:addRow(false, { fixed = true })
	row[1]:setColSpan(2):createText(T(2010, tostring(#(menu.pendingStations or {}))),
		{ wordwrap = true })

	row = ftable:addRow(true, { fixed = true })
	row[1]:createEditBox({ width = Helper.scaleX(config.nameFieldWidth) })
		:setText(menu.nameText or "", { halign = "left" })
	-- Capture on deactivation, which is vanilla's own rename pattern (menu_map.lua:13756
	-- does exactly this for renaming an object). Clicking the Create button moves focus and
	-- therefore deactivates the box first, so the text is captured before onClick runs.
	row[1].handlers.onEditBoxDeactivated = function (_, text, textchanged)
		if textchanged and text and (text ~= "") then
			menu.nameText = text
		end
	end
	row[2]:createButton():setText(T(1010), { halign = "center" })
	row[2].handlers.onClick = menu.confirmName

	row = ftable:addRow(true, { fixed = true })
	row[1]:setColSpan(2):createButton():setText(T(1011), { halign = "center" })
	row[1].handlers.onClick = function ()
		menu.mode = "chain"
		menu.pendingStations = nil
		menu.refresh = getElapsedTime() + 0.05
	end

	-- Which stations are about to become the chain, so the name is chosen with the
	-- membership visible rather than from memory.
	if menu.pendingStations and (#menu.pendingStations > 0) then
		row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(2):createText(T(2005), Helper.headerRow1Properties)
		for _, entry in ipairs(menu.pendingStations) do
			local id = (type(entry) == "table") and entry.id or entry
			local d = SCV_Data.describe(id)
			row = ftable:addRow(false, { fixed = false })
			row[1]:createText(d and d.name or tostring(id))
			row[2]:createText(d and d.sectorname or "", { color = Color["text_inactive"], halign = "right" })
		end
	end
end

function menu.confirmName()
	local name = menu.nameText
	if (not name) or (name == "") then
		name = T(1014, tostring(SCV_Store.count() + 1))
	end
	SCV_Store.create(name, menu.pendingStations or {})
	menu.pendingStations = nil
	menu.nameText = nil
	menu.mode = "chain"
	menu.markDirty()
end

-- Left column: the chains, and the members of the selected one.
function menu.displayChainList(frame, x, y, width)
	-- Three columns: name | Logical Station Overview | remove. The overview link lives here
	-- (and in each station's detail panel) because a flowchart node has no click event for
	-- an icon on its label - only expand/collapse and slider events are dispatched.
	local ftable = frame:addTable(3, { tabOrder = 1, width = width, x = x, y = y,
		maxVisibleHeight = availableHeight(y) })
	ftable:setColWidth(2, Helper.scaleX(30), false)
	ftable:setColWidth(3, Helper.scaleX(30), false)

	local row = ftable:addRow(false, { fixed = true })
	row[1]:setColSpan(3):createText(T(1002), Helper.headerRowCenteredProperties)

	-- Chains are created from the map context menu now, so say so rather than leaving an
	-- empty panel that looks broken.
	row = ftable:addRow(false, { fixed = true })
	row[1]:setColSpan(3):createText(T(1005), { wordwrap = true, color = Color["text_inactive"] })

	if menu.notice then
		row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(3):createText(menu.notice, { wordwrap = true, color = Color["text_positive"] })
	end

	-- Chains may now contain other factions' stations, whose stock levels are scan-gated.
	-- The LINKS are still correct - ware roles are public - but the numbers read zero, and
	-- an unexplained zero looks like an empty warehouse rather than missing information.
	local locked = 0
	for _, st in ipairs(menu.currentMembers()) do
		local cached = SCV_Data.cache[st.id]
		if cached and cached.locked then
			locked = locked + 1
		end
	end
	if locked > 0 then
		row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(3):createText(T(3023, tostring(locked)),
			{ wordwrap = true, color = Color["text_inactive"] })
	end

	-- Say when a stored station no longer resolves. Dropping it silently would show a
	-- shorter chain than the one that was built, which reads as the mod losing stations.
	if (menu.missingMembers or 0) > 0 then
		row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(3):createText(T(3022, tostring(menu.missingMembers)),
			{ wordwrap = true, color = Color["text_warning"] })
	end

	local chains = SCV_Store.chains()
	local _, selectedIdx = SCV_Store.selected()

	for i, chain in ipairs(chains) do
		row = ftable:addRow(true, { fixed = false, bgColor = (i == selectedIdx)
			and Color["row_background_selected"] or nil })
		-- Interactive cells need real widgets; clicks do not fire on createText.
		row[1]:setColSpan(2):createButton({ bgColor = Color["button_background_hidden"] })
			:setText(chain.name .. "  (" .. #chain.members .. ")", { halign = "left" })
		row[1].handlers.onClick = function ()
			SCV_Store.select(i)
			menu.notice = nil
			menu.markDirty()
		end
		row[3]:createButton({ mouseOverText = T(1008) }):setText("x", { halign = "center" })
		row[3].handlers.onClick = function ()
			SCV_Store.delete(i)
			menu.notice = nil
			menu.markDirty()
		end
	end

	local members = menu.currentMembers()
	if #members > 0 then
		-- fixed = FALSE deliberately. The row schema states fixed "requires all previous
		-- rows to be fixed as well", and the scrollable chain rows above already broke that.
		row = ftable:addRow(false, { fixed = false })
		row[1]:setColSpan(3):createText(T(1015, tostring(#members)), Helper.headerRow1Properties)

		for _, st in ipairs(members) do
			local severity = "ok"
			local reason
			if menu.graph and menu.graph.stationNodes[st.id] then
				local sn = menu.graph.stationNodes[st.id]
				severity = sn.severity
				local w = sn.worstWare and sn.wares[sn.worstWare]
				reason = w and warningReason(w.name or sn.worstWare, w.health)
			end

			row = ftable:addRow(true, { fixed = false })
			row[1]:createButton({ bgColor = Color["button_background_hidden"],
				mouseOverText = reason and (reason .. "\n" .. T(1013)) or T(1013) })
				:setText(st.name, { halign = "left", color = severityColor(severity) })
			row[1].handlers.onClick = function ()
				-- Same shape vanilla uses for the map: {0, 0, showuniverse, target}.
				Helper.closeMenuAndOpenNewMenu(menu, "MapMenu", { 0, 0, true, st.id64 })
				menu.cleanup()
			end
			-- "mapob_factory" is verified in libraries/icons.xml (it is also our top-level
			-- tab icon); there is no dedicated overview icon - vanilla's own links to the
			-- overview are text buttons.
			row[2]:createButton({ mouseOverText = T(3030) }):setIcon("mapob_factory")
			row[2].handlers.onClick = function ()
				Helper.closeMenuAndOpenNewMenu(menu, "StationOverviewMenu", { 0, 0, st.id64 })
				menu.cleanup()
			end
			row[3]:createButton({ mouseOverText = T(1016) }):setText("-", { halign = "center" })
			row[3].handlers.onClick = function ()
				SCV_Store.removeStation(selectedIdx, st.id)
				menu.markDirty()
			end
		end
	end
end

-- Right pane: the diagram.
function menu.displayChain(frame, x, y, width)
	local chain = SCV_Store.selected()
	if not chain then
		local ftable = frame:addTable(1, { tabOrder = 2, width = width, x = x, y = y })
		local row = ftable:addRow(false, { fixed = true })
		row[1]:createText(T(1004), Helper.headerRowCenteredProperties)
		row = ftable:addRow(false, { fixed = true })
		row[1]:createText(T(1005), { wordwrap = true })
		return
	end

	local members = menu.currentMembers()
	if #members == 0 then
		local ftable = frame:addTable(1, { tabOrder = 2, width = width, x = x, y = y })
		local row = ftable:addRow(false, { fixed = true })
		row[1]:createText(T(1005), { wordwrap = true })
		return
	end

	local stations = SCV_Data.scanGroup(members, false)
	local graph = SCV_Graph.build(stations, {})
	menu.graph = graph
	if not graph then
		return
	end

	menu.decorateNodes(graph)

	local numrows, numcols, junctions = Helper.setupDAGLayout(graph.nodes)

	-- Re-check the budget AFTER layout. SCV_Graph.applyBudget can only count the graph it
	-- was given, but setupDAGLayout inserts JUNCTION nodes to route edges across tiers, and
	-- each junction brings its own cells and edges. A graph that fit before layout can
	-- overflow after it, which the widget system reports as "No more flowchart edges
	-- available. Skipping following edges." while drawing a diagram missing links with no
	-- indication of which ones. Better to refuse.
	local postNodes = #graph.nodes + #junctions
	local postEdges = 0
	for _, n in ipairs(graph.nodes) do
		for _ in pairs(n.predecessors or {}) do postEdges = postEdges + 1 end
	end
	for _, j in ipairs(junctions) do
		for _ in pairs(j.predecessors or {}) do postEdges = postEdges + 1 end
	end

	if (numcols > SCV_Graph.LIMITS.maxCols)
			or (postNodes > SCV_Graph.LIMITS.maxNodes)
			or (postEdges > SCV_Graph.LIMITS.maxEdges) then
		log(string.format("chain over budget after layout: %d nodes (+%d junctions), %d edges, %d cols",
			#graph.nodes, #junctions, postEdges, numcols))
		local ftable = frame:addTable(1, { tabOrder = 2, width = width, x = x, y = y })
		local row = ftable:addRow(false, { fixed = true })
		row[1]:createText(T(4000), Helper.headerRowCenteredProperties)
		row = ftable:addRow(false, { fixed = true })
		row[1]:createText(T(4003), { wordwrap = true })
		return
	end

	-- No ware nodes at all means every station's offers are disjoint. That is a real and
	-- common answer ("these do not actually trade with each other"), and it must not look
	-- like a rendering failure.
	if next(graph.wareNodes) == nil then
		local ftable = frame:addTable(1, { tabOrder = 2, width = width, x = x, y = y })
		local row = ftable:addRow(false, { fixed = true })
		row[1]:createText(T(4004), Helper.headerRowCenteredProperties)
		row = ftable:addRow(false, { fixed = true })
		row[1]:createText(T(4005), { wordwrap = true })
		return
	end

	-- Anything given up to fit the budget is said out loud, above the diagram.
	local notes = {}
	if #graph.collapsedWares > 0 then
		notes[#notes + 1] = T(4002, table.concat(graph.collapsedWares, ", "))
	end
	if #graph.droppedStations > 0 then
		local names = {}
		for _, s in ipairs(graph.droppedStations) do
			names[#names + 1] = s.name
		end
		notes[#notes + 1] = T(4001, tostring(graph.counts.nodes), tostring(graph.counts.edges),
			tostring(SCV_Graph.LIMITS.maxNodes), tostring(SCV_Graph.LIMITS.maxEdges),
			table.concat(names, ", "))
	end
	if #graph.droppedEdges > 0 then
		-- Mutual trade between two stations is ORDINARY under the offer-based rule (A sells
		-- X to B while B sells Y to A), so this note is information, not a warning. Name the
		-- wares and the count: "one edge not drawn" was both vague and often wrong.
		local seen, wares = {}, {}
		for _, e in ipairs(graph.droppedEdges) do
			local w = e.ware and graph.wareNodes[e.ware]
			local label = (w and w.name) or e.ware
			if label and (not seen[label]) then
				seen[label] = true
				wares[#wares + 1] = label
			end
		end
		notes[#notes + 1] = T(3012, tostring(#graph.droppedEdges), table.concat(wares, ", "))
	end

	local chartY = y
	if #notes > 0 then
		local ntable = frame:addTable(1, { tabOrder = 3, width = width, x = x, y = y })
		local row = ntable:addRow(false, { fixed = true })
		row[1]:createText(table.concat(notes, "  |  "),
			{ wordwrap = true, color = Color["text_warning"] })
		chartY = y + ntable:getFullHeight()
	end

	menu.flowchart = frame:addFlowchart(numrows, numcols, {
		borderHeight = 3,
		borderColor  = Color["row_background_blue"],
		minRowHeight = 45,
		minColWidth  = 80,
		x = x, y = chartY, width = width,
	})
	menu.flowchart:setDefaultNodeProperties({
		expandedFrameLayer      = config.expandedMenuFrameLayer,
		expandedTableNumColumns = 2,
		x     = config.nodeOffsetX,
		-- per-node width overrides this; it is only the fallback
		width = config.wareNodeWidth,
	})

	menu.renderFlowchart(graph, junctions)
end

-- The node/junction/edge loop, modelled on menu_station_overview.lua:1774-1915 and
-- simplified because each of our nodes carries exactly one sub-cell.
function menu.renderFlowchart(graph, junctions)
	local containerSlot = Color["lso_slot_container"]
	local liquidSlot    = Color["lso_slot_liquid"]
	local solidSlot     = Color["lso_slot_solid"]
	local slotProps = {
		[1] = { sourceSlotColor = containerSlot, sourceSlotRank = 1, destSlotColor = containerSlot, destSlotRank = 1 },
		[2] = { sourceSlotColor = liquidSlot,    sourceSlotRank = 2, destSlotColor = liquidSlot,    destSlotRank = 2 },
		[3] = { sourceSlotColor = solidSlot,     sourceSlotRank = 3, destSlotColor = solidSlot,     destSlotRank = 3 },
	}

	for _, nodedata in ipairs(graph.nodes) do
		local moduledata = nodedata[1]
		if moduledata then
			local node = menu.flowchart:addNode(nodedata.row, nodedata.col,
				{ nodedata = nodedata, moduledata = moduledata }, moduledata.properties)
				:setText(nodedata.text)

			if moduledata.color then
				node.properties.outlineColor = moduledata.color
				node.properties.text.color   = moduledata.color
				node.properties.statusColor  = moduledata.color
			end
			if moduledata.statuscolor then
				node.properties.statusColor = moduledata.statuscolor
			end
			if moduledata.statusText then
				node:setStatusText(moduledata.statusText)
			elseif moduledata.statusIcon then
				node:setStatusIcon(moduledata.statusIcon)
			end

			node.handlers.onExpanded  = menu.onFlowchartNodeExpanded
			node.handlers.onCollapsed = menu.onFlowchartNodeCollapsed
			moduledata.node = node
		end
	end

	for _, junctiondata in ipairs(junctions) do
		junctiondata.junction = menu.flowchart:addJunction(junctiondata.row, junctiondata.col)
	end

	-- A predecessor may itself be a layout-inserted junction rather than a node.
	local function cellOf(n)
		if n.junction then
			return n.junction
		end
		return n[#n] and n[#n].node or nil
	end

	local function linkAll(list)
		for _, nodedata in ipairs(list) do
			if nodedata.predecessors then
				for predecessor, slot in pairs(nodedata.predecessors) do
					local from = cellOf(predecessor)
					local to   = nodedata.junction or (nodedata[1] and nodedata[1].node)
					if from and to then
						from:addEdgeTo(to, slotProps[slot] or slotProps[1])
					end
				end
			end
		end
	end

	linkAll(graph.nodes)
	linkAll(junctions)
end

-- ---------------------------------------------------------------------------------
-- Detail panels (node expansion)
-- ---------------------------------------------------------------------------------
--
-- HOW EXPANSION WORKS (helper.lua, widgetPrototypes.flowchartnode:expand):
-- the engine creates a frame and one table, then calls
--     node.handlers.onExpanded(node, frame, ftable, ftable2)
-- and SHOWS THE FRAME ONLY IF THE HANDLER ADDED ROWS to ftable. The previous handler
-- recorded the node and added nothing, so every expansion silently collapsed again - that
-- is why the chevrons did nothing.

-- Open the vanilla Logical Station Overview for a station. Same call vanilla uses from the
-- map info panel (menu_map.lua:13272).
local function openStationOverview(id64)
	if not id64 then
		return
	end
	Helper.closeMenuAndOpenNewMenu(menu, "StationOverviewMenu", { 0, 0, id64 })
	menu.cleanup()
end

-- WHY THE PANEL IS NODE-WIDTH, AND STAYS THAT WAY.
--
-- The popup's border is not drawn from the frame. C.SetFlowchartNodeExpanded(nodeid,
-- frameid, expandedabove) stretches the NODE'S OWN outline graphics (the lso_line_vertical_*
-- side and corner elements) down to wrap the content: it grows vertically to fit, but its
-- width is always the node's. An earlier version widened the frame to 560px for a
-- two-column layout; the content then sat inside a ~300px border and spilled out of it on
-- both sides. So the content is laid out for the node's width, in one stacked column, the
-- same way the vanilla Logical Station Overview does it at 250px.

-- Every cell of a row must hold a widget: a cell left empty is escalated by the widget
-- system into "Content element is missing" and ABORTS THE WHOLE FRAME. The stacked layout
-- below therefore always either spans a row across both columns or fills both.

-- Let a long panel scroll instead of running off the screen. The engine creates the frame
-- at the full height available above or below the node, then shrinks it to what was used;
-- capping the table at that initial height is what turns an overflow into a scrollbar.
-- (A table with maxVisibleHeight 0 that does not fit is REFUSED outright, not clipped.)
local function capToFrame(frame, ftable)
	local h = frame.properties.height
	if h and (h > 0) then
		ftable.properties.maxVisibleHeight = h
	end
end

-- One stock bar, vanilla trade-menu style (menu_map.lua:31054): start = stock now,
-- current = stock once every reserved exchange completes; a gain draws green, a loss in the
-- dark orange vanilla uses for the same thing. `extra` is an optional line of context for
-- the mouse-over, used for the full wording of the rate shown compactly beside the name.
local function barCell(cell, w, subject, extra)
	local b = SCV_Graph.reservationBar(w)
	local lines = {}
	lines[#lines + 1] = subject
	lines[#lines + 1] = T(3041, b.stockKnown and formatAmount(b.start) or "?", b.unknown and "?" or formatAmount(b.max))
	if b.incoming > 0 then
		lines[#lines + 1] = T(3042, formatAmount(b.incoming))
	end
	if b.outgoing > 0 then
		lines[#lines + 1] = T(3043, formatAmount(b.outgoing))
	end
	if (b.incoming > 0) or (b.outgoing > 0) then
		lines[#lines + 1] = T(3044, b.stockKnown and b.reservationsKnown and formatAmount(b.current) or "?")
	end
	if not b.reservationsKnown then lines[#lines + 1] = T(3064) end
	if extra then
		lines[#lines + 1] = extra
	end
	if b.unknown then
		lines[#lines + 1] = T(3046)
	elseif b.estimated then
		lines[#lines + 1] = T(3045)
	end
	cell:createStatusBar({
		start          = b.drawStart,
		current        = b.drawCurrent,
		max            = b.max,
		valueColor     = Color["slider_value"],
		posChangeColor = Color["flowchart_slider_diff2"],
		negChangeColor = Color["flowchart_slider_diff1"],
		markerColor    = Color["statusbar_marker_hidden"],
		-- REQUIRED. A statusbar has no intrinsic height: cell:getHeight() falls back to the
		-- text height only for text/boxtext cells and returns 0 for everything else
		-- (helper.lua, widgetPrototypes.cell:getHeight). Alone in its row, a bar without an
		-- explicit height is drawn 0px tall and the row collapses with it - the bars simply
		-- vanished. Vanilla passes the text height for the same reason (menu_map.lua:20262).
		height         = Helper.standardTextHeight,
		mouseOverText  = table.concat(lines, "\n"),
	})
end

local function sortedWares(wares, predicate)
	local out = {}
	for ware, w in pairs(wares or {}) do
		if predicate(w) then
			out[#out + 1] = { ware = ware, w = w }
		end
	end
	table.sort(out, function (a, b) return (a.w.name or a.ware) < (b.w.name or b.ware) end)
	return out
end

-- Two columns: a name on the left, a short figure on the right. Vanilla's own storage panel
-- splits its table the same way (Helper.onExpandLSOStorageNode: setColWidthPercent(2, 30)).
local function setupColumns(ftable)
	ftable:setColWidthPercent(2, 32)
	-- Keep selectable entry rows for native scrolling, but hide the focus rectangle.
	ftable.properties.highlightMode = "off"
end

local function sectionHeader(ftable, text)
	local row = ftable:addRow(false, {})
	row[1]:setColSpan(2):createText(text, Helper.headerRow1Properties)
end

local function noneRow(ftable)
	local row = ftable:addRow(false, {})
	row[1]:setColSpan(2):createText(T(3049), { color = Color["text_inactive"] })
end

-- Shared renderer: only the label and role differ between station/ware popups.
local function detailEntry(ftable, key, name, w, isInput)
	local m = SCV_Graph.detailMetrics(w, isInput)
	local b = m.bar
	local rate = m.rateKnown and (m.sign .. formatRate(m.rate)) or "? /h"
	local stock = b.stockKnown and formatAmount(b.start) or "?"
	local capacity = ((w.limit or 0) > 0 or (w.capacityUnits or 0) > 0)
		and ((b.estimated and "~" or "") .. formatAmount(b.max)) or "?"
	local long = T(isInput and 3035 or 3036, rate)
	if not m.rateKnown then long = T(3037) end
	local reason = warningReason(name, w.health)
	local labelTip = reason and (reason .. "\n" .. long) or long
	-- Explicit row backgrounds need no group wrapper. Avoid its automatic padding;
	-- the transparent 2px spacer below is the only gap between metric blocks.
	local function metricRow(rowkey)
		return ftable:addRow(rowkey, { bgColor = Color["row_background_unselectable"], borderBelow = false })
	end
	local r = metricRow(key)
	r[1]:setColSpan(2):createText(name, { wordwrap = true, color = severityColor(m.severity), mouseOverText = labelTip })
	r = metricRow(false)
	barCell(r[1]:setColSpan(2), w, name, long)
	r = metricRow(false)
	r[1]:setBackgroundColSpan(2):createText(T(3060, stock, capacity), { wordwrap = true,
		mouseOverText = b.estimated and T(3045) or (b.unknown and T(3046) or "") })
	r[2]:createText(rate, { halign = "right", wordwrap = true, mouseOverText = long,
		color = m.rateKnown and (m.rate or 0) > 0 and (isInput and config.consumptionColor or Color["text_positive"]) or Color["text_inactive"] })
	r = metricRow(false)
	local fullTime = m.capacityHours and ((b.estimated and "~" or "") .. formatHours(m.capacityHours)) or "?"
	local coverageTip = T(isInput and 3070 or 3071)
	if b.estimated then coverageTip = coverageTip .. "\n" .. T(3045) end
	r[1]:setColSpan(2):createText(T(3069, m.stockHours and formatHours(m.stockHours) or "?", fullTime),
		{ wordwrap = true, mouseOverText = coverageTip, color = Color["text_inactive"] })
	-- A small full-width spacer, following vanilla's explicit-height text rows.
	r = ftable:addRow(false, { borderBelow = false })
	r[1]:setColSpan(2):createText(" ", { fontsize = 1, height = 2 })
end

function menu.expandStation(node, frame, ftable, nodedata)
	capToFrame(frame, ftable)
	setupColumns(ftable)

	local inputs  = sortedWares(nodedata.wares, function (w) return w.input end)
	local outputs = sortedWares(nodedata.wares, function (w) return w.output end)

	-- The Logical Station Overview link. It lives here rather than on the node itself
	-- because the widget system dispatches only expand/collapse and slider events for a
	-- flowchart node - there is no click event for an icon on its label.
	local row = ftable:addRow(true, {})
	row[1]:setColSpan(2):createButton({ mouseOverText = T(3030) })
		:setText(T(3030), { halign = "center" })
	local id64 = ConvertStringTo64Bit(nodedata.scvid)
	row[1].handlers.onClick = function () openStationOverview(id64) end

	if (#inputs == 0) and (#outputs == 0) then
		row = ftable:addRow(false, {})
		row[1]:setColSpan(2):createText(T(3040), { wordwrap = true, color = Color["text_inactive"] })
		return
	end

	local function section(title, list, isInput)
		sectionHeader(ftable, title)
		if #list == 0 then
			noneRow(ftable)
			return
		end
		for _, entry in ipairs(list) do
			detailEntry(ftable, "ware:" .. entry.ware, entry.w.name or entry.ware, entry.w, isInput)
		end
	end

	section(T(3031), inputs, true)
	section(T(3032), outputs, false)
end

-- Same entry layout as the station popup, with station names.
function menu.expandWare(node, frame, ftable, nodedata)
	-- Stadium nodes reserve half-round side space; rectangle nodes use the common
	-- expansion padding (also returned as vertical padding). Match rectangle insets
	-- inside the same node outline, before table widths and wrapped heights resolve.
	if node and node.id and not frame.scvMatchedInsets then
		local _, _, sidePadding, commonPadding = GetFlowchartNodeExpandedFrameData(node.id)
		if sidePadding and commonPadding and sidePadding > commonPadding then
			local extra = sidePadding - commonPadding
			frame.properties.x = frame.properties.x - extra
			frame.properties.width = frame.properties.width + 2 * extra
			frame.scvMatchedInsets = true
		end
	end
	capToFrame(frame, ftable)
	setupColumns(ftable)

	local graph = menu.graph
	local function stationsFor(ids)
		local out = {}
		for _, sid in ipairs(ids or {}) do
			local sn = graph and graph.stationNodes[sid]
			local w = sn and sn.wares[nodedata.scvware]
			if w then
				out[#out + 1] = { node = sn, w = w }
			end
		end
		table.sort(out, function (a, b) return (a.node.name or "") < (b.node.name or "") end)
		return out
	end

	local function section(title, list, isInput)
		sectionHeader(ftable, title)
		if #list == 0 then
			noneRow(ftable)
			return
		end
		for _, entry in ipairs(list) do
			detailEntry(ftable, "station:" .. tostring(entry.node.scvid), entry.node.name or "?", entry.w, isInput)
		end
	end

	section(T(3033), stationsFor(nodedata.producers), false)
	section(T(3034), stationsFor(nodedata.consumers), true)
end

function menu.onFlowchartNodeExpanded(node, frame, ftable, ftable2)
	-- One panel at a time, as vanilla does (menu_station_overview.lua onFlowchartNodeExpanded).
	if node.flowchart and node.flowchart.collapseAllNodes then
		node.flowchart:collapseAllNodes()
	end
	menu.expandedNode = node
	-- Remember the frame too: the collapse handler must only clear the panel that belongs to
	-- the node being collapsed. collapseAllNodes() above fires a collapse for the PREVIOUS
	-- node while this one is opening, and without the pairing that would wipe the new panel.
	menu.expandedMenuFrame = frame

	local nodedata = node.customdata and node.customdata.nodedata
	if not nodedata then
		return
	end

	local ok, err = pcall(function ()
		if nodedata.scvkind == "station" then
			menu.expandStation(node, frame, ftable, nodedata)
		elseif nodedata.scvkind == "ware" then
			menu.expandWare(node, frame, ftable, nodedata)
		end
	end)
	if not ok then
		-- A failure here would otherwise surface only as a node that will not open.
		log("detail panel failed: " .. tostring(err))
	end
end

-- Mirrors vanilla exactly (menu_station_overview.lua and menu_research.lua both do this).
--
-- The panel is its own frame on expandedMenuFrameLayer, and collapsing the node does NOT
-- remove it - the menu has to. The previous version only forgot the node, so the panel's
-- contents stayed drawn on screen after the popup closed.
function menu.onFlowchartNodeCollapsed(node, frame)
	if (menu.expandedNode == node) and (menu.expandedMenuFrame == frame) then
		Helper.clearFrame(menu, config.expandedMenuFrameLayer)
		menu.expandedNode = nil
		menu.expandedMenuFrame = nil
	end
end

init()

return menu
