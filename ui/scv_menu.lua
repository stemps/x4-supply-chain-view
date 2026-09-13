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
	-- Lower layers draw in front: dialogs, node details, status, navigation, graph.
	mainFrameLayer         = 5,
	expandedMenuFrameLayer = 2,
	toolbarFrameLayer      = 4,
	managementFrameLayer   = 1,
	statusFrameLayer       = 3,
	topLevelId             = "scv_supplychain",
	textPage               = 90210,
	-- Station names run long ("2 - Factory - Asteroid Belt - Computronic Substrate") and the
	-- node must also fit a status figure on the right; at 250px they were cut off mid-word.
	-- Ware names are short, and widening them too would only fit fewer tiers on screen.
	stationNodeWidth       = 310,
	wareNodeWidth          = 260,
	nodeOffsetX            = 20,
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
		icon            = "stationbuildst_lsov",
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
	if menu.statusFrame then Helper.clearFrame(menu, config.statusFrameLayer) end
	menu.statusFrame, menu.statusKey, menu.statusHeight, menu.noticeUntil = nil, nil, nil, nil
	menu.graphLayout = nil
	menu.chainPlaceholder = nil
	menu.missingMembers = 0
	menu.closeManagement()
	if menu.toolbarFrame then Helper.clearFrame(menu, config.toolbarFrameLayer) end
	menu.toolbarFrame = nil
	menu.toolbarGeometry = nil
	menu.mode            = "chain"
	menu.graph           = nil
	menu.scanDone        = nil
	menu.pendingStations = nil
	menu.nameText        = nil
	menu.renameIndex     = nil
	menu.notice          = nil
	menu.expandedNode    = nil
	menu.expandedMenuFrame = nil
	menu.refresh         = nil
	menu.topLevelOffsetY = nil
	menu.flowchart       = nil
	menu.refreshState    = nil
	menu.metricRevision  = 0
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
	menu.noticeUntil = nil

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
				menu.notice = T(3021, tostring(pending.added), string.lower(ReadText(1001, pending.added == 1 and 3 or 4)))
			end
		end
	end

	-- No galaxy-wide station scan here any more: chains resolve their own ids, and the
	-- name-entry preview describes the ids the context menu handed over.
	SCV_Data.invalidate()
	menu.refreshState = nil
	menu.metricRevision = 0
	menu.scanDone = false

	menu.display()
end

menu.updateInterval = 0.2

function menu.onUpdate()
	-- Chunked scanning: pull stations in a few at a time until the chain is fully read,
	-- then redraw once. A full rescan inside one callback is the crash risk this avoids.
	-- Do not destroy an active editbox when an initial scan/queued redraw completes.
	-- Existing live metrics still refresh below; resume initial rendering after naming.
	if not menu.scanDone and menu.managementMode ~= "rename" then
		local members = menu.currentMembers()
		if #members == 0 then
			menu.scanDone = true
		else
			local _, done = SCV_Data.scanGroup(members, false)
			if done then
				menu.scanDone = true
				menu.refresh = nil -- this display also satisfies any pending refresh
				menu.display()
			end
		end
	end

	if menu.refresh and (menu.refresh <= getElapsedTime()) and menu.managementMode ~= "rename" then
		menu.refresh = nil
		menu.display()
	end
	if menu.scanDone and menu.refreshState and menu.graph and menu.mode == "chain" then
		local snapshot = SCV_Data.refreshStep(menu.refreshState, getElapsedTime())
		if snapshot then menu.publishMetrics(snapshot) end
	end
	if menu.toolbarFrame then menu.toolbarFrame:update() end
	menu.updateStatusStrip()
	if menu.managementFrame then menu.managementFrame:update() end
end

function menu.onCloseElement(dueToClose, layer)
	if menu.managementMode then
		menu.closeManagement()
		return
	end
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
	menu.graphLayout = nil
	SCV_Data.invalidate()
	menu.refreshState = nil
	menu.metricRevision = 0
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
	return T(5003, formatAmount(n))
end

local function formatSigned(n)
	if n == nil then return T(5003, "? ") end
	return (n > 0 and "+" or "") .. formatRate(n)
end

local function formatPartial(n, known, rate)
	local value = rate and formatRate(n) or formatAmount(n)
	if known then return value end
	return (n or 0) > 0 and (value .. " + ?") or (rate and T(5003, "? ") or "?")
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

local function warningReason(name, health, context)
	if not health or health.severity == "ok" then return nil end
	local threshold = health.severity == "critical" and SCV_Graph.THRESHOLDS.criticalHours
		or SCV_Graph.THRESHOLDS.warningHours
	local lines = { name, T(3090), "",
		T(3092, formatHours(health.hours)),
		T(3094, T(health.severity == "critical" and 3067 or 3068), formatHours(threshold)) }
	if context and #context > 0 then
		lines[#lines + 1] = ""
		for _, line in ipairs(context) do lines[#lines + 1] = line end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = T(3095)
	lines[#lines + 1] = T(3097)
	return table.concat(lines, "\n")
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
		local widget = node[1] and node[1].node
		if node.scvkind == "station" then
			local parts = {}
			local warningName, warningHealth
			if node.worstWare then
				local w = node.wares[node.worstWare]
				local h = w and w.health
				if h and (h.severity ~= "ok") then
					warningName, warningHealth = w.name or node.worstWare, h
				end
			end
			if #node.unmet > 0 then
				parts[#parts + 1] = T(3099, tostring(#node.unmet))
			end
			if #node.unsold > 0 then
				parts[#parts + 1] = T(3100, tostring(#node.unsold))
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
					mouseOverText = warningReason(warningName, warningHealth, parts)
						or ((#parts > 0) and table.concat(parts, "\n") or T(3014)),
				},
				statuscolor = severityColor(node.severity),
				color       = (node.severity == "critical") and Color["lso_node_error"] or nil,
			}
			if node.severity ~= "ok" then
				local h = node.wares[node.worstWare].health
				node[1].statusText = T(3028, formatHours(h.hours))
			end
		else
			-- Inventory fill and full-operation hourly balance are separate metrics.
			local storage = node.storage
			local known = storage.stockKnown and storage.capacityKnown and storage.capacity > 0
			local amount = T(3060, formatPartial(storage.stock, storage.stockKnown),
				(storage.estimated and "~" or "") .. formatPartial(storage.capacity, storage.capacityKnown))
			local lines = { amount, T(3081,
				formatPartial(node.supplyCap, node.supplyKnown, true),
				formatPartial(node.demandCap, node.demandKnown, true), formatSigned(node.netRate)) }
			if storage.estimated then lines[#lines + 1] = T(3045) end
			if not known then lines[#lines + 1] = T(3082) end
			local rateColor = Color["text_inactive"]
			if node.netKnown and node.netRate > 0 then rateColor = Color["text_positive"]
			elseif node.netKnown and node.netRate < 0 then rateColor = config.consumptionColor end
			local rateText = formatSigned(node.netRate)
			if node.netKnown and node.demandCap > 0 then
				rateText = rateText .. string.format(" (%+.0f%%)", node.netRate / node.demandCap * 100)
			end
			node.text = node.name
			node[1] = {
				properties = {
					shape = "stadium", width = config.wareNodeWidth,
					value = known and math.min(storage.stock, storage.capacity) or 0,
					max = known and storage.capacity or 1,
					step = 0, slider1 = -1, slider2 = -1,
					mouseOverText = table.concat(lines, "\n"),
				},
				statusText = rateText, statuscolor = rateColor,
			}

		end
		node[1].node = widget
	end
end

function menu.publishMetrics(snapshot)
	local started = SCV_Data.PROFILE_REFRESH and GetCurRealTime()
	SCV_Graph.refreshMetrics(menu.graph, snapshot)
	for _, st in ipairs(snapshot) do SCV_Data.cache[st.id] = st end
	menu.metricRevision = (menu.metricRevision or 0) + 1
	menu.decorateNodes(menu.graph)
	for _, data in ipairs(menu.graph.nodes) do
		local display = data[1]
		local widget = display and display.node
		if widget then
			widget.customdata.moduledata = display
			-- Passing explicit defaults clears a warning when a station recovers.
			widget:updateOutlineColor(display.color or widget.scvDefaultOutline)
			widget:updateText(data.text, display.color or widget.scvDefaultText)
			widget:updateStatus(display.statusText, display.statusIcon, nil,
				display.statuscolor or display.color or widget.scvDefaultStatus)
			if data.scvkind == "ware" then
				widget:updateMaxValue(display.properties.max)
				widget:updateValue(display.properties.value)
			end
		end
	end
	-- Only a publication updates widgets. These callbacks format cached data; no
	-- station reads or graph reconstruction happen in frame:update().
	if menu.frame then menu.frame:update() end
	if menu.expandedMenuFrame then menu.expandedMenuFrame:update() end
	if started then
		log(string.format("refresh: %d stations, reads %.2fms total / %.2fms max, publish %.2fms",
			#snapshot, menu.refreshState.readSeconds * 1000,
			menu.refreshState.maxReadSeconds * 1000, (GetCurRealTime() - started) * 1000))
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

function menu.display(presentationOnly)
	local managementMode = menu.managementMode
	if not presentationOnly then
		menu.closeManagement()
		if menu.toolbarFrame then Helper.clearFrame(menu, config.toolbarFrameLayer) end
		menu.toolbarFrame = nil
	end
	Helper.clearDataForRefresh(menu, config.mainFrameLayer)
	if menu.expandedNode then menu.expandedNode:collapse() end
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
	local rightBarX = Helper.viewWidth - Helper.scaleX(Helper.sidebarWidth) - Helper.frameBorder
	local contentWidth = rightBarX - Helper.frameBorder - Helper.borderSize

	if menu.mode == "name" then
		if menu.statusFrame then Helper.clearFrame(menu, config.statusFrameLayer) end
		menu.statusFrame, menu.statusKey, menu.statusHeight = nil, nil, nil
		menu.displayNameEntry(menu.frame, Helper.frameBorder, topY, contentWidth)
	else
		if not presentationOnly then menu.toolbarGeometry = { x = Helper.frameBorder, y = topY, width = contentWidth } end
		menu.displayChain(menu.frame, Helper.frameBorder,
			topY + Helper.scaleY(Helper.standardButtonHeight) + Helper.borderSize + (menu.statusHeight or 0), contentWidth, presentationOnly)
	end

	menu.frame:display()
	if menu.mode == "chain" then
		if not presentationOnly then
			menu.displayToolbar()
			if managementMode == "stations" then menu.openManagement("stations") end
			menu.updateStatusStrip()
		end
	end
end

-- Creation and renaming share the same cell-sized name field.
function menu.displayNameEntry(frame, x, y, width)
	local ftable = frame:addTable(2, { tabOrder = 1, width = math.min(width, Helper.scaleX(700)),
		x = x, y = y, maxVisibleHeight = availableHeight(y) })
	ftable:setColWidth(2, Helper.scaleX(140), false)

	local row = ftable:addRow(false, { fixed = true })
	row[1]:setColSpan(2):createText(menu.renameIndex and ReadText(1001, 1114) or T(2000), Helper.headerRowCenteredProperties)

	if not menu.renameIndex then
		local count = #(menu.pendingStations or {})
		row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(2):createText(T(2010, tostring(count), string.lower(ReadText(1001, count == 1 and 3 or 4))),
			{ wordwrap = true })
	end

	row = ftable:addRow(true, { fixed = true })
	-- Let the cell supply its width; an explicit scaled width is scaled again by Helper.
	row[1]:createEditBox({ description = menu.renameIndex and ReadText(1001, 1114) or T(2000) })
		:setText(menu.nameText or "", { halign = "left", x = Helper.standardTextOffsetx })
	-- Capture on deactivation, which is vanilla's own rename pattern (menu_map.lua:13756
	-- does exactly this for renaming an object). Clicking the Create button moves focus and
	-- therefore deactivates the box first, so the text is captured before onClick runs.
	row[1].handlers.onEditBoxDeactivated = function (_, text, textchanged)
		if textchanged and text then
			menu.nameText = text
		end
	end
	row[2]:createButton():setText(menu.renameIndex and ReadText(1001, 1114) or T(1010), { halign = "center" })
	row[2].handlers.onClick = menu.confirmName

	row = ftable:addRow(true, { fixed = true })
	row[1]:setColSpan(2):createButton():setText(T(1011), { halign = "center" })
	row[1].handlers.onClick = function ()
		if menu.managementMode == "rename" then menu.closeManagement(); return end
		menu.mode = "chain"
		menu.pendingStations = nil
		menu.renameIndex = nil
		menu.nameText = nil
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
	local name = menu.nameText and menu.nameText:match("^%s*(.-)%s*$")
	if menu.renameIndex then
		if not SCV_Store.rename(menu.renameIndex, name) then return end
		if menu.managementMode == "rename" then
			menu.closeManagement()
			menu.displayToolbar()
			return
		end
		menu.renameIndex = nil
		menu.nameText = nil
		menu.mode = "chain"
		menu.refresh = getElapsedTime() + 0.05
		return
	end
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
local function setCenteredButtonIcon(button, icon)
	-- Widget dimensions are already scaled pixels. Helper adds the button border
	-- inset itself; fit a square to the whole button and center before that inset.
	local width, height = button:getWidth(), button:getHeight(true)
	local size = math.min(width, height)
	button:setIcon(icon, { scaling = false, width = size, height = size,
		x = (width - size) / 2, y = (height - size) / 2 })
end

-- All toolbar/overlay updates are isolated from the native graph frame.
function menu.statusText()
	local lines = {}
	for _, message in ipairs(menu.collectStatusMessages()) do lines[#lines + 1] = message.text end
	return table.concat(lines, "\n")
end

function menu.collectStatusMessages()
	local messages = {}
	local function warning(text) messages[#messages + 1] = { text = text, color = "text_warning" } end
	if (menu.missingMembers or 0) > 0 then
		warning(T(menu.missingMembers == 1 and 3025 or 3022, tostring(menu.missingMembers)))
	end
	local graph = menu.graph
	if graph then
		if graph.structureChanged then warning(T(3101)) end
		if graph.refreshFailed then warning(T(3102)) end
		if (graph.lockedCount or 0) > 0 then warning(T(3023, tostring(graph.lockedCount))) end
	end
	if menu.noticeUntil and getElapsedTime() >= menu.noticeUntil then
		menu.notice, menu.noticeUntil = nil, nil
	end
	if menu.notice then messages[#messages + 1] = { text = menu.notice, color = "text_positive" } end
	return messages
end

function menu.updateStatusStrip()
	if menu.mode ~= "chain" or not menu.toolbarGeometry then return end
	local messages, parts = menu.collectStatusMessages(), {}
	for _, message in ipairs(messages) do parts[#parts + 1] = message.color .. ":" .. message.text end
	local key = table.concat(parts, "\n")
	if key == menu.statusKey then return end
	local geo = menu.toolbarGeometry
	local y = geo.y + Helper.scaleY(Helper.standardButtonHeight) + Helper.borderSize
	local cap = math.max(1, (Helper.viewHeight - y - Helper.frameBorder) * 0.2)
	local height, frame = 0, nil
	if #messages > 0 then
		frame = Helper.createFrameHandle(menu, { layer = config.statusFrameLayer, standardButtons = {},
			x = geo.x, y = y, width = geo.width, height = cap })
		local ftable = frame:addTable(1, { tabOrder = 1, x = 0, y = 0, width = geo.width, maxVisibleHeight = cap })
		for _, message in ipairs(messages) do
			local row = ftable:addRow(false, { fixed = false })
			row[1]:createText(message.text, { wordwrap = true, color = Color[message.color] })
		end
		height = ftable:getVisibleHeight()
		frame.properties.height = height
	end
	if menu.statusFrame then Helper.clearFrame(menu, config.statusFrameLayer) end
	menu.statusFrame, menu.statusKey = frame, key
	if frame then
		frame:display()
		if menu.notice and not menu.noticeUntil then menu.noticeUntil = getElapsedTime() + 6 end
	end
	local occupied = height > 0 and height + Helper.borderSize or 0
	if occupied ~= (menu.statusHeight or 0) then
		menu.statusHeight = occupied
		-- Only recreate native presentation; keep graph, layout and refresh cursor.
		menu.display(true)
		if menu.managementMode and menu.managementMode ~= "rename" then menu.openManagement(menu.managementMode) end
	end
end

function menu.hasWarning()
	local g = menu.graph
	return (menu.missingMembers or 0) > 0 or (g and
		(g.structureChanged or g.refreshFailed or (g.lockedCount or 0) > 0)) or false
end

function menu.closeManagement()
	if menu.managementFrame then Helper.clearFrame(menu, config.managementFrameLayer) end
	if menu.managementMode == "rename" then
		menu.renameIndex = nil
		menu.nameText = nil
	end
	menu.managementFrame = nil
	menu.managementMode = nil
	menu.managementChain = nil
	menu.managementStatus = nil
end

function menu.selectChain(index)
	local _, current = SCV_Store.selected()
	if not index or not SCV_Store.get(index) then return end
	menu.closeManagement()
	if index == current then return end
	SCV_Store.select(index)
	menu.notice = nil
	menu.noticeUntil = nil
	menu.markDirty()
end

function menu.displayToolbar()
	local geo = menu.toolbarGeometry
	if not geo then return end
	if menu.toolbarFrame then Helper.clearFrame(menu, config.toolbarFrameLayer) end
	-- UIX's Logical Overview selector leaves 25% margins on both sides.
	-- Keep this local to the toolbar: the graph still uses the entire content width.
	local toolbarWidth = geo.width * 0.5
	local toolbarX = geo.x + (geo.width - toolbarWidth) / 2
	local frame = Helper.createFrameHandle(menu, { layer = config.toolbarFrameLayer,
		standardButtons = {}, -- Embedded toolbar: no automatic Back/Close over its controls.
		x = toolbarX, y = geo.y, width = toolbarWidth, height = Helper.scaleY(Helper.standardButtonHeight) })
	menu.toolbarFrame = frame
	local ftable = frame:addTable(5, { tabOrder = 1, width = toolbarWidth, x = 0, y = 0 })
	local buttonWidth = Helper.scaleX(Helper.standardButtonHeight)
	local stationsWidth = math.min(Helper.scaleX(180), toolbarWidth * 0.28)
	for _, col in ipairs({ 1, 3, 5 }) do ftable:setColWidth(col, buttonWidth, false) end
	ftable:setColWidth(4, stationsWidth, false)
	local chain, index = SCV_Store.selected()
	local chains, options = SCV_Store.chains(), {}
	for i, entry in ipairs(chains) do
		options[#options + 1] = { id = tostring(i), text = entry.name, icon = "", displayremoveoption = false }
	end
	if #options == 0 then options[1] = { id = "0", text = T(1004), icon = "" } end
	local row = ftable:addRow(true, { fixed = true })
	row[1]:createButton({ active = chain ~= nil and #chains > 1 }):setText("<", { halign = "center" })
	row[1].handlers.onClick = function ()
		if chain and #chains > 1 then menu.selectChain(index > 1 and index - 1 or #chains) end
	end
	row[2]:createDropDown(options, { active = chain ~= nil, startOption = chain and tostring(index) or "0",
		mouseOverText = chain and chain.name or T(1004) }):setTextProperties({ halign = "left" })
	row[2].handlers.onDropDownConfirmed = function (_, id) menu.selectChain(tonumber(id)) end
	row[3]:createButton({ active = chain ~= nil and #chains > 1 }):setText(">", { halign = "center" })
	row[3].handlers.onClick = function ()
		if chain and #chains > 1 then menu.selectChain(index < #chains and index + 1 or 1) end
	end
	row[4]:createButton({ active = chain ~= nil, mouseOverText = T(2005) })
		:setText(T(2005) .. " (" .. tostring(chain and #chain.members or 0) .. ")", { halign = "center" })
	row[4].handlers.onClick = function () menu.toggleManagement("stations") end
	row[5]:createButton({ active = chain ~= nil, mouseOverText = ReadText(1001, 7865) }):setText("...", { halign = "center" })
	row[5].handlers.onClick = function () menu.toggleManagement("actions") end
	-- Store the station button's left edge in screen pixels, including table borders.
	geo.anchorX = toolbarX + toolbarWidth - stationsWidth - buttonWidth - Helper.borderSize
	geo.overlayY = geo.y + Helper.scaleY(Helper.standardButtonHeight) + Helper.borderSize
	frame:display()
end

function menu.toggleManagement(mode)
	if menu.managementMode == mode then menu.closeManagement() else menu.openManagement(mode) end
end

function menu.confirmDelete()
	local chain, index = SCV_Store.selected()
	if menu.managementMode ~= "delete" or chain ~= menu.managementChain then return end
	menu.closeManagement()
	SCV_Store.delete(index)
	menu.notice = nil
	menu.noticeUntil = nil
	menu.markDirty()
end

function menu.openManagement(mode)
	local chain, index = SCV_Store.selected()
	if not chain or not menu.toolbarGeometry then return end
	menu.closeManagement()
	if menu.expandedNode then menu.expandedNode:collapse() end
	menu.expandedNode = nil
	menu.expandedMenuFrame = nil
	menu.managementMode = mode
	menu.managementChain = chain
	local geo, border = menu.toolbarGeometry, Helper.frameBorder
	local width = math.min(Helper.scaleX(mode == "actions" and 240 or 600), Helper.viewWidth - 2 * border)
	local x = math.max(border, math.min(geo.anchorX, Helper.viewWidth - width - border))
	local y = math.min(geo.overlayY + (menu.statusHeight or 0), Helper.viewHeight - Helper.scaleY(160) - border)
	y = math.max(border, y)
	local height = Helper.viewHeight - y - border
	local frame = Helper.createFrameHandle(menu, { layer = config.managementFrameLayer,
		standardButtons = {}, -- Management supplies its own Close/Cancel controls.
		x = x, y = y, width = width, height = height, closeOnUnhandledClick = false })
	menu.managementFrame = frame
	frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })
	if mode == "rename" then
		menu.renameIndex, menu.nameText = index, chain.name
		menu.displayNameEntry(frame, border, border, width - 2 * border)
		frame.properties.height = math.min(height, frame:getUsedHeight() + 2 * border)
	else
		local ftable = frame:addTable(3, { tabOrder = 1, x = border, y = border,
			width = width - 2 * border, maxVisibleHeight = height - 2 * border })
		ftable:setColWidth(2, Helper.scaleX(30), false)
		ftable:setColWidth(3, Helper.scaleX(30), false)
		local row = ftable:addRow(true, { fixed = true })
		row[1]:setColSpan(2):createText(chain.name, { wordwrap = true })
		row[3]:createButton({ mouseOverText = ReadText(1001, 2670) }):setText("x", { halign = "center" })
		row[3].handlers.onClick = menu.closeManagement
		if mode == "stations" then
			menu.displayStations(ftable, chain, index)
		elseif mode == "actions" then
			for _, action in ipairs({ { "rename", 1114 }, { "delete", 8931 } }) do
				local target = action[1]
				row = ftable:addRow(true, { fixed = false })
				row[1]:setColSpan(3):createButton():setText(ReadText(1001, action[2]))
				row[1].handlers.onClick = function () menu.openManagement(target) end
			end
		elseif mode == "delete" then
			row = ftable:addRow(false, { fixed = false })
			row[1]:setColSpan(3):createText(T(2020, chain.name), { wordwrap = true })
			row = ftable:addRow(true, { fixed = false })
			row[1]:setColSpan(3):createButton():setText(ReadText(1001, 8931))
			row[1].handlers.onClick = menu.confirmDelete
			row = ftable:addRow(true, { fixed = false })
			row[1]:setColSpan(3):createButton():setText(T(1011))
			row[1].handlers.onClick = menu.closeManagement
		end
		-- Match vanilla: grow the frame only as far as its bounded table content.
		frame.properties.height = math.min(height, ftable:getVisibleHeight() + 2 * border)
	end
	frame:display()
end

function menu.displayStations(ftable, chain, index)
	local members = menu.currentMembers()
	-- Match the map's ascending name order, with station code breaking name ties.
	-- Reconciliation returns a fresh display list, separate from saved membership.
	for _, st in ipairs(members) do st.objectid = st.code or "" end
	table.sort(members, Helper.sortNameAndObjectID)
	local row = ftable:addRow(false, { fixed = false })
	row[1]:setColSpan(3):createText(T(2005) .. " (" .. #chain.members .. ")", Helper.headerRow1Properties)
	if #members == 0 then
		row = ftable:addRow(false, { fixed = false })
		row[1]:setColSpan(3):createText(T(1005), { wordwrap = true })
	end
	for _, st in ipairs(members) do
		local function stationStyle()
			local sn = menu.graph and menu.graph.stationNodes[st.id]
			local w = sn and sn.worstWare and sn.wares[sn.worstWare]
			return severityColor(sn and sn.severity or "ok") or Color["text_normal"],
				w and warningReason(w.name or sn.worstWare, w.health)
		end
		row = ftable:addRow(true, { fixed = false })
		row[1]:createButton({ bgColor = Color["button_background_hidden"], mouseOverText = function ()
			local _, reason = stationStyle()
			return st.name .. "\n" .. (reason and (reason .. "\n") or "") .. T(1013)
		end }):setText(st.name, { halign = "left", color = function () local color = stationStyle(); return color end })
		row[1].handlers.onClick = function ()
			Helper.closeMenuAndOpenNewMenu(menu, "MapMenu", { 0, 0, true, st.id64 }); menu.cleanup()
		end
		row[2]:createButton({ mouseOverText = T(3030) })
		setCenteredButtonIcon(row[2], "stationbuildst_lsov")
		row[2].handlers.onClick = function ()
			Helper.closeMenuAndOpenNewMenu(menu, "StationOverviewMenu", { 0, 0, st.id64 }); menu.cleanup()
		end
		row[3]:createButton({ mouseOverText = T(1016) }):setText("-", { halign = "center" })
		row[3].handlers.onClick = function ()
			local selected = SCV_Store.selected()
			if selected ~= chain then return end
			SCV_Store.removeStation(index, st.id)
			menu.markDirty()
		end
	end
end


function menu.drawChainPlaceholder(frame, x, y, width, header, text)
	menu.chainPlaceholder = { header = header, text = text }
	local ftable = frame:addTable(1, { tabOrder = 2, width = width, x = x, y = y })
	if header then ftable:addRow(false, { fixed = true })[1]:createText(header, Helper.headerRowCenteredProperties) end
	if text then ftable:addRow(false, { fixed = true })[1]:createText(text, { wordwrap = true }) end
end

-- Full-width diagram beneath the toolbar and status strip.
function menu.displayChain(frame, x, y, width, reuseGraph)
	-- A status-only redraw must not scan while the initial graph is still loading.
	if reuseGraph and not menu.graph then
		local placeholder = menu.chainPlaceholder
		if placeholder then menu.drawChainPlaceholder(frame, x, y, width, placeholder.header, placeholder.text) end
		return
	end
	if not reuseGraph then
		menu.graph, menu.graphLayout, menu.refreshState, menu.flowchart, menu.chainPlaceholder = nil, nil, nil, nil, nil
	end
	local chain = SCV_Store.selected()
	if not chain then
		menu.missingMembers = 0
		menu.drawChainPlaceholder(frame, x, y, width, T(1004), T(1005))
		return
	end

	local graph = menu.graph
	if not reuseGraph or not graph then
		local members = menu.currentMembers()
		if #members == 0 then
			menu.drawChainPlaceholder(frame, x, y, width, nil, T(1005))
			return
		end

		local stations, done = SCV_Data.scanGroup(members, false)
		menu.scanDone = done
		-- scanGroup returns a partial snapshot while its remaining batches are pending.
		-- Do not lay out or publish that subset: it would jump to a different graph when
		-- onUpdate finishes the scan. Keep the bounded reads and reveal only the final graph.
		if not done then
			menu.drawChainPlaceholder(frame, x, y, width, ReadText(1001, 7201))
			return
		end

		graph = SCV_Graph.build(stations, {})
		menu.graph = graph
		if not graph then
			return
		end
		menu.refreshState = SCV_Data.newRefresh(members, getElapsedTime())

	end
	menu.decorateNodes(graph)

	if not reuseGraph or not menu.graphLayout then
		local rows, cols, junctions = Helper.setupDAGLayout(graph.nodes)
		menu.graphLayout = { rows = rows, cols = cols, junctions = junctions }
	end
	local numrows, numcols, junctions = menu.graphLayout.rows, menu.graphLayout.cols, menu.graphLayout.junctions

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
			-- Function-valued mouseovers register with frame:update at creation.
			local properties = {}
			for key, value in pairs(moduledata.properties) do properties[key] = value end
			properties.mouseOverText = function () return nodedata[1].properties.mouseOverText end
			local node = menu.flowchart:addNode(nodedata.row, nodedata.col,
				{ nodedata = nodedata, moduledata = moduledata }, properties)
				:setText(nodedata.text)
			node.scvDefaultOutline = node.properties.outlineColor
			node.scvDefaultText = node.properties.text.color
			node.scvDefaultStatus = node.properties.statusColor or node.properties.statustext.color

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
-- Native function-valued properties, formatted once per published snapshot.
-- Open panels retain their widgets and scrolling; no callback reads the engine.
local function liveFields(make)
	local revision, values
	return function (key)
		return function ()
			local current = menu.metricRevision or 0
			if not values or revision ~= current then
				values, revision = make(), current
			end
			return values[key]
		end
	end
end

local function barCell(cell, w, subject, extra)
	local fields = liveFields(function ()
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
			lines[#lines + 1] = type(extra) == "function" and extra() or extra
		end
		if b.unknown then
			lines[#lines + 1] = T(3046)
		elseif b.estimated then
			lines[#lines + 1] = T(3045)
		end
		return { start = b.drawStart, current = b.drawCurrent, max = b.max,
			tooltip = table.concat(lines, "\n") }
	end)
	cell:createStatusBar({
		start          = fields("start"),
		current        = fields("current"),
		max            = fields("max"),
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
		mouseOverText  = fields("tooltip"),
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
	local row = ftable:addRow(false, { paddingTop = 8 })
	row[1]:setColSpan(2):createText(text, Helper.headerRow1Properties)
end

local function noneRow(ftable)
	local row = ftable:addRow(false, {})
	row[1]:setColSpan(2):createText(T(3049), { color = Color["text_inactive"] })
end

-- Shared renderer: only the label and role differ between station/ware popups.
local function detailEntry(ftable, key, name, w, isInput)
	local fields = liveFields(function ()
		local m = SCV_Graph.detailMetrics(w, isInput)
		local b = m.bar
		local rate = m.rateKnown and (m.sign .. formatRate(m.rate)) or T(5003, "? ")
		local stock = b.stockKnown and formatAmount(b.start) or "?"
		local capacity = ((w.limit or 0) > 0 or (w.capacityUnits or 0) > 0)
			and ((b.estimated and "~" or "") .. formatAmount(b.max)) or "?"
		local long = m.rateKnown and T(isInput and 3035 or 3036, rate) or T(3037)
		local fullTime = m.capacityHours and ((b.estimated and "~" or "") .. formatHours(m.capacityHours)) or "?"
		local fillTime = m.fillHours and ((b.estimated and "~" or "")
			.. (m.fillHours == 0 and T(5001, "0") or formatHours(m.fillHours))) or "?"
		local coverageTip = T(isInput and 3070 or 3071)
		if b.estimated then coverageTip = coverageTip .. "\n" .. T(3045) end
		return { rate = rate, amount = T(3060, stock, capacity), long = long,
			labelTip = warningReason(name, w.health) or long,
			labelColor = severityColor(m.severity) or Color["text_normal"],
			amountTip = b.estimated and T(3045) or (b.unknown and T(3046) or ""),
			rateColor = m.rateKnown and (m.rate or 0) > 0
				and (isInput and config.consumptionColor or Color["text_positive"]) or Color["text_inactive"],
			coverage = isInput and T(3069, m.stockHours and formatHours(m.stockHours) or "?", fullTime)
				or T(3074, fillTime, fullTime),
			coverageTip = coverageTip }
	end)
	local function metricRow(rowkey)
		return ftable:addRow(rowkey, { bgColor = Color["row_background_unselectable"], borderBelow = false })
	end
	local r = metricRow(key)
	r[1]:setColSpan(2):createText(name, { wordwrap = true, color = fields("labelColor"), mouseOverText = fields("labelTip") })
	r = metricRow(false)
	barCell(r[1]:setColSpan(2), w, name, fields("long"))
	r = metricRow(false)
	r[1]:setBackgroundColSpan(2):createText(fields("amount"), { wordwrap = true, mouseOverText = fields("amountTip") })
	r[2]:createText(fields("rate"), { halign = "right", wordwrap = true, mouseOverText = fields("long"), color = fields("rateColor") })
	r = metricRow(false)
	r[1]:setColSpan(2):createText(fields("coverage"),
		{ wordwrap = true, mouseOverText = fields("coverageTip"), color = Color["text_inactive"] })
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

	-- Match the vanilla map's player-owned station configurator action.
	row = ftable:addRow(true, {})
	row[1]:setColSpan(2):createButton({ mouseOverText = T(3103), active = GetComponentData(id64, "isplayerowned") })
		:setText(T(3103), { halign = "center" })
	row[1].handlers.onClick = function ()
		if not GetComponentData(id64, "isplayerowned") then return end
		Helper.closeMenuAndOpenNewMenu(menu, "StationConfigurationMenu", { 0, 0, id64 })
		menu.cleanup()
	end

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

	sectionHeader(ftable, T(3080))
	local fields = liveFields(function ()
		local storage = nodedata.storage
		return { amount = T(3060, formatPartial(storage.stock, storage.stockKnown),
			(storage.estimated and "~" or "") .. formatPartial(storage.capacity, storage.capacityKnown)),
			tip = storage.estimated and T(3045) or T(3083) }
	end)
	local totals = ftable:addRow("totals", { bgColor = Color["row_background_unselectable"], borderBelow = false })
	totals[1]:setColSpan(2):createText(fields("amount"), { wordwrap = true, mouseOverText = fields("tip") })
	local function totalRate(label, amountKey, knownKey, sign, color, tooltip)
		local values = liveFields(function ()
			local amount, known = nodedata[amountKey], nodedata[knownKey]
			local value = formatPartial(amount, known, true)
			if known or amount > 0 then value = sign .. value end
			local tip = T(tooltip)
			if not known then tip = tip .. "\n" .. T(3088) end
			return { value = value, tip = tip }
		end)
		local row = ftable:addRow(false, { bgColor = Color["row_background_unselectable"], borderBelow = false })
		row[1]:setBackgroundColSpan(2):createText(T(label), { mouseOverText = values("tip") })
		row[2]:createText(values("value"), { halign = "right", wordwrap = true, color = color, mouseOverText = values("tip") })
	end
	totalRate(3084, "supplyCap", "supplyKnown", "+", Color["text_positive"], 3086)
	totalRate(3085, "demandCap", "demandKnown", "-", config.consumptionColor, 3087)

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
	menu.closeManagement()
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
