-- Depends: scv_data.lua, scv_store.lua, scv_graph.lua, scv_presentation.lua, scv_details.lua, scv_management.lua, scv_chart.lua, scv_logistics_view.lua
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

local menu = {
	name = "SCVSupplyChainMenu",
}

local config = {
	-- Lower layers draw in front: dialogs, status, node details, graph.
	mainFrameLayer         = 5,
	-- Match vanilla LSO's 5 -> 4 node expansion. The native central fill and
	-- background are coplanar; layer 2 produces hover-dependent fill occlusion.
	expandedMenuFrameLayer = 4,
	managementFrameLayer   = 1,
	statusFrameLayer       = 3,
	topLevelId             = "scv_supplychain",
	textPage               = 90210,
	-- Station names run long ("2 - Factory - Asteroid Belt - Computronic Substrate") and the
	-- node must also fit a status figure on the right; at 250px they were cut off mid-word.
	-- Leave room for long ware names beside partial supply/demand labels.
	stationNodeWidth       = 310,
	logisticsFontSize      = 8, -- quieter than station names; icons scale with text
	wareNodeWidth          = 300,
	nodeOffsetX            = 20,
	consumptionColor       = { r = 255, g = 150, b = 150, a = 100, glow = 0 },
}

local function log(msg)
	DebugError("SCV: " .. tostring(msg))
end

local presentation = SCV_Presentation.new(config, menu)
local details = SCV_Details.new(menu, config, presentation)
local management = SCV_Management.new(menu, config, presentation)
local chart = SCV_Chart.new(menu, config, presentation)
local logisticsView = SCV_LogisticsView.new(menu, config, presentation)
local T = presentation.T


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
	menu.closed = true
	menu.nameEntry = nil
	menu.clearLogisticsStrip()
	if SCV_Data.stopLogistics then SCV_Data.stopLogistics() end
	if menu.statusFrame then Helper.clearFrame(menu, config.statusFrameLayer) end
	menu.statusFrame, menu.statusKey, menu.statusHeight, menu.noticeUntil = nil, nil, nil, nil
	menu.graphLayout = nil
	menu.chainPlaceholder = nil
	menu.missingMembers = 0
	menu.closeManagement()
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

-- Helper.clearFrame unregisters a GLOBAL Helper<layer> view. Do all of our
-- cleanup before another menu can reuse those layers (vanilla LSO uses 4/5).
function menu.openMenu(name, params)
	menu.cleanup()
	Helper.closeMenuAndOpenNewMenu(menu, name, params)
end

function menu.onShowMenu()
	menu.closed = false
	menu.nativeLogisticsFailed = nil
	if menu.nativeLogistics then
		pcall(function () menu.nativeLogistics:reset() end)
		menu.nativeLogistics = nil -- reconnect to the current native scene on reopen/load
	end
	menu.nextSlowUpdate = nil
	if SCV_Data.startLogistics then SCV_Data.startLogistics(menu.onDockMetrics) end
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

menu.updateInterval = 0 -- Native logistics follows scrolling and hover every frame.

function menu.onUpdate()
	if menu.closed then return end
	menu.updateLogisticsStrip()
	local now = GetCurRealTime()
	if menu.nextSlowUpdate and now < menu.nextSlowUpdate then return end
	menu.nextSlowUpdate = now + 0.2
	local entry = menu.nameEntry
	if entry and entry.focusPending and entry.widget.id then
		entry.focusPending = nil
		ActivateEditBox(entry.widget.id)
	end
	-- Creation owns the main frame; defer queued scans/redraws until it closes.
	if menu.mode == "name" then return end
	if SCV_Data.expireDockRequests then SCV_Data.expireDockRequests(getElapsedTime()) end
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
	menu.cleanup()
	Helper.closeMenu(menu, dueToClose)
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
	if menu.nativeLogistics then menu.nativeLogistics:reset() end
	menu.nativeLayoutGraph, menu.nativeLayoutRevision = nil, nil
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

function menu.idleText(...) return presentation.idleText(...) end
function menu.logisticsEntries(...) return presentation.logisticsEntries(...) end
function menu.logisticsRows(...) return presentation.logisticsRows(...) end

function menu.prepareLogisticsColumns(...) return logisticsView.prepareLogisticsColumns(...) end

function menu.onDockMetrics()
	if not menu.closed and menu.graph then menu.updateMetricDisplay() end
end

function menu.updateLogisticsStrip(...) return logisticsView.updateLogisticsStrip(...) end
function menu.clearLogisticsStrip(...) return logisticsView.clearLogisticsStrip(...) end


function menu.decorateNodes(...) return chart.decorateNodes(...) end

function menu.publishMetrics(snapshot)
	SCV_Graph.refreshMetrics(menu.graph, snapshot)
	for _, st in ipairs(snapshot) do SCV_Data.cache[st.id] = st end
	menu.updateMetricDisplay()
end

function menu.updateMetricDisplay()
	menu.metricRevision = (menu.metricRevision or 0) + 1
	menu.decorateNodes(menu.graph)
	for _, data in ipairs(menu.graph.nodes) do
		local display = data[1]
		local widget = display and display.node
		if widget then
			widget.customdata.moduledata = display
			-- Passing explicit defaults clears a warning when a station recovers.
			widget:updateOutlineColor(display.outlinecolor or widget.scvDefaultOutline)
			widget:updateText(data.text, widget.scvDefaultText)
			widget:updateStatus(display.statusText, display.statusIcon, nil,
				display.statuscolor or widget.scvDefaultStatus)
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
end

function menu.setWareWarnings(stationCode, ware, enabled)
	if not SCV_Store.setWarningIgnored(stationCode, ware, not enabled) then return end
	if not menu.graph then return end
	for _, node in pairs(menu.graph.metricStations) do
		SCV_Graph.updateStationMetrics(node)
	end
	menu.updateMetricDisplay()
end

-- ---------------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------------

function menu.display(presentationOnly)
	menu.clearLogisticsStrip()
	menu.flowchart = nil
	local managementMode = menu.managementMode
	if not presentationOnly then
		menu.closeManagement()
	end
	if menu.expandedNode then menu.expandedNode:collapse() end
	Helper.clearDataForRefresh(menu, config.mainFrameLayer)
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
		menu.displayToolbar(menu.frame)
		menu.displayChain(menu.frame, Helper.frameBorder,
			topY + Helper.scaleY(Helper.standardButtonHeight) + Helper.borderSize + (menu.statusHeight or 0), contentWidth, presentationOnly)
	end

	menu.frame:display()
	if menu.mode == "chain" then
		if not presentationOnly then
			if managementMode == "stations" or managementMode == "settings" then menu.openManagement(managementMode) end
			menu.updateStatusStrip()
		end
	end
end

-- Creation and renaming share the same cell-sized name field.
function menu.displayNameEntry(...) return management.displayNameEntry(...) end
function menu.confirmName(...) return management.confirmName(...) end

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

function menu.closeManagement(...) return management.closeManagement(...) end
function menu.selectChain(...) return management.selectChain(...) end
function menu.displayToolbar(...) return management.displayToolbar(...) end
function menu.toggleManagement(...) return management.toggleManagement(...) end
function menu.setShowLogistics(...) return management.setShowLogistics(...) end
function menu.confirmDelete(...) return management.confirmDelete(...) end
function menu.displayManagementHeader(...) return management.displayManagementHeader(...) end
function menu.openManagement(...) return management.openManagement(...) end
function menu.displayStations(...) return management.displayStations(...) end

function menu.drawChainPlaceholder(...) return chart.drawChainPlaceholder(...) end
function menu.displayChain(...) return chart.displayChain(...) end
function menu.drawChainLegend(...) return chart.drawChainLegend(...) end
function menu.renderFlowchart(...) return chart.renderFlowchart(...) end

function menu.expandStation(...) return details.expandStation(...) end
function menu.expandWare(...) return details.expandWare(...) end

function menu.onFlowchartNodeExpanded(node, frame, ftable, ftable2)
	if menu.nativeLogistics then menu.nativeLogistics:hide() end
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
	if menu.nativeLogistics then menu.nativeLogistics:hide() end
	if (menu.expandedNode == node) and (menu.expandedMenuFrame == frame) then
		Helper.clearFrame(menu, config.expandedMenuFrameLayer)
		menu.expandedNode = nil
		menu.expandedMenuFrame = nil
	end
end

init()

return menu
