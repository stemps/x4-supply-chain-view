-- Depends: scv_graph.lua, scv_presentation.lua
-- Supply Chain View: detail renderers with per-screen ownership.
SCV_Details = {}

function SCV_Details.new(menu, config, presentation)
	local details = {}
	local T = presentation.T
	local stockTooltip = presentation.stockTooltip
	local formatRate = presentation.formatRate
	local formatAmount = presentation.formatAmount
	local rateTooltip = presentation.rateTooltip
	local formatHours = presentation.formatHours
	local coverageTooltip = presentation.coverageTooltip
	local warningReason = presentation.warningReason
	local severityColor = presentation.severityColor
	local logisticsTint = presentation.logisticsTint
	local dockLabel = presentation.dockLabel
	local logisticsCount = presentation.logisticsCount
	local formatPartial = presentation.formatPartial
	local aggregateStockTooltip = presentation.aggregateStockTooltip
	local hasContinuousDemand = presentation.hasContinuousDemand
	local aggregateRateLine = presentation.aggregateRateLine
	local rateAssumptions = presentation.rateAssumptions

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
		menu.openMenu("StationOverviewMenu", { 0, 0, id64 })
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
	-- A table placed below a toolbar (properties.y) gets only the height left under it.
	local function capToFrame(frame, ftable)
		local h = frame.properties.height
		if h and (h > 0) then
			ftable.properties.maxVisibleHeight = math.max(1, h - (ftable.properties.y or 0))
		end
	end

	-- Station actions as square icon buttons in the frame's second table, above the
	-- scrolling content. The content table's fixed columns cannot hold equal squares,
	-- so this copies vanilla's two-table expansion (menu_station_overview.lua
	-- onExpandTradeWares), with the button table on top so it never scrolls away.
	-- Icons and calls are vanilla's own for the same actions: the station configuration
	-- left bar's logical/construction modes (helper.lua), the player info Transaction Log
	-- (menu_playerinfo.lua), the top-level Map tab and the interact menu's Information
	-- (menu_interactmenu.lua). Remove sits apart at the right edge.
	local function stationToolbar(ftable, ftable2, id64, scvid)
		if not ftable2 then
			return
		end
		-- 1.5x the default button height (Helper.standardButtonHeight).
		local size = Helper.scaleY(math.floor(1.5 * Helper.standardButtonHeight + 0.5))
		-- Column 5 takes the remaining width, so column 6 (Remove) ends on the table's edge.
		for _, col in ipairs({ 1, 2, 3, 4, 6 }) do ftable2:setColWidth(col, size, false) end
		ftable2.properties.highlightMode = "off"
		local row = ftable2:addRow(true, {})
		local function iconButton(cell, icon, tip, active, onClick)
			cell:createButton({ scaling = false, width = size, height = size,
				mouseOverText = tip, active = active })
				:setIcon(icon, { scaling = false, width = size, height = size })
			cell.handlers.onClick = onClick
		end
		local function owned() return GetComponentData(id64, "isplayerowned") end
		iconButton(row[1], "stationbuildst_lsov", T(3030), true,
			function () openStationOverview(id64) end)
		-- Match the vanilla map's player-owned station configurator action.
		iconButton(row[2], "mapst_plotmanagement", T(3103), owned(), function ()
			if not owned() then return end
			menu.openMenu("StationConfigurationMenu", { 0, 0, id64 })
		end)
		-- The map offers the log for player-owned stations only (menu_map.lua).
		iconButton(row[3], "pi_transactionlog", ReadText(1001, 11287), owned(), function ()
			if not owned() then return end
			menu.openMenu("TransactionLogMenu", { 0, 0, id64 })
		end)
		iconButton(row[4], "tlt_map", T(1013), true,
			function () menu.openMenu("MapMenu", { 0, 0, true, id64 }) end)
		iconButton(row[5], "mapst_information", ReadText(1001, 2427), true, function ()
			menu.openMenu("MapMenu", { 0, 0, true, nil, nil, "infomode", { "info", id64 } })
		end)
		iconButton(row[6], "widget_cross_01", T(1016), true,
			function () menu.removeExpandedStation(scvid) end)
		ftable.properties.y = ftable2:getFullHeight() + Helper.borderSize
	end

	-- One stock bar, vanilla trade-menu style (menu_map.lua:31054): start = stock now,
	-- current = stock once every reserved exchange completes; a gain draws green, a loss in the
	-- dark orange vanilla uses for the same thing. Its hover explains inventory only.
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

	local function barCell(cell, w, subject)
		local fields = liveFields(function ()
			local b = SCV_Graph.reservationBar(w)
			return { start = b.drawStart, current = b.drawCurrent, max = b.max,
				tooltip = stockTooltip(subject, w, b) }
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

	-- Metrics keep the 68/32 split. Two narrow trailing columns hold the bell and
	-- checkbox; names span the first two, and right-hand metrics span the last three.
	local function setupColumns(ftable)
		ftable:setColWidthPercent(1, 68)
		-- Four text-height slots: warning bell + checkbox, then the producer/consumer radio.
		for col = 3, 6 do ftable:setColWidth(col, Helper.standardTextHeight) end
		-- Keep selectable entry rows for native scrolling, but hide the focus rectangle.
		ftable.properties.highlightMode = "off"
	end

	local function sectionHeader(ftable, text)
		local row = ftable:addRow(false, { paddingTop = 8 })
		row[1]:setColSpan(6):createText(text, Helper.headerRow1Properties)
	end

	local function noneRow(ftable)
		local row = ftable:addRow(false, {})
		row[1]:setColSpan(6):createText(T(3049), { color = Color["text_inactive"] })
	end

	-- Producer/consumer radio for wares a station both buys and sells, in columns 5 and 6.
	-- Vanilla's export/import pair (an arrow out of / into a tray); the selected one uses
	-- vanilla's mode-selector background (menu_station_configuration.lua leftbar), the
	-- other is dimmed and switches on click. state: true = consumer, false = producer,
	-- nil = mixed (station switch only), where neither is selected.
	local function roleRadio(row, state, producerTip, consumerTip, onSelect)
		local size = Helper.scaleY(Helper.standardTextHeight)
		for i, consumer in ipairs({ false, true }) do
			local cell = row[4 + i]
			local selected = state == consumer
			cell:createButton({ scaling = false, width = size, height = size,
				x = math.max(0, cell:getColSpanWidth() - size),
				bgColor = selected and Color["row_background_selected"] or Color["button_background_default"],
				mouseOverText = consumer and consumerTip or producerTip })
				:setIcon(consumer and "menu_import" or "menu_export",
					{ color = selected and Color["text_normal"] or Color["text_inactive"] })
			if not selected then
				cell.handlers.onClick = function () onSelect(consumer) end
			end
		end
	end

	-- Shared renderer: only the label and role differ between station/ware popups.
	-- radioColumns: this popup shows a role radio somewhere, so the warning bell moves left
	-- (columns 3-4) to keep columns 5-6 for the radio. Otherwise the bell stays rightmost.
	local function detailEntry(ftable, key, name, w, isInput, stationCode, ware, radioColumns)
		local fields = liveFields(function ()
			local m = SCV_Graph.detailMetrics(w, isInput)
			local b = m.bar
			local rate = m.rateKnown and (m.sign .. formatRate(m.rate)) or T(5003, "? ")
			local stock = b.stockKnown and formatAmount(b.start) or "?"
			local capacity = b.capacityKnown
				and ((b.estimated and "~" or "") .. formatAmount(b.capacity)) or "?"
			local long = rateTooltip(name, w, m, isInput)
			local fullTime = m.capacityHours and ((b.estimated and "~" or "") .. formatHours(m.capacityHours)) or "?"
			local fillTime = m.fillHours and ((b.estimated and "~" or "")
				.. (m.fillHours == 0 and T(5001, "0") or formatHours(m.fillHours))) or "?"
			local coverageTip = coverageTooltip(name, w, m, isInput, fullTime, fillTime)
			return { rate = rate, amount = T(3060, stock, capacity), long = long,
				labelTip = warningReason(name, w.health) or long,
				labelColor = severityColor(m.severity) or Color["text_normal"],
				amountTip = stockTooltip(name, w, b),
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
		local hasCode = stationCode ~= nil and stationCode ~= ""
		local canToggle = isInput and hasCode
		-- Bought AND sold here: the player picks which side of the chain the station is on.
		-- Only in the section of the current role: workforce use can list a producer twice.
		local consumer = w.consumerRole == true
		local canSwitch = radioColumns and w.dualTrade and hasCode and consumer == (isInput == true)
		local bell = radioColumns and 3 or 5
		r[1]:setBackgroundColSpan(6):setColSpan(canToggle and bell - 1 or canSwitch and 4 or 6)
		r[1]:createText(name, { wordwrap = true, color = fields("labelColor"), mouseOverText = fields("labelTip") })
		if canSwitch then
			-- Title, blank line, explanation.
			roleRadio(r, consumer, T(3197) .. "\n\n" .. T(3203), T(3198) .. "\n\n" .. T(3204),
				function (choice) menu.setConsumerRole(stationCode, ware, choice) end)
		end
		if canToggle then
			local size = Helper.scaleY(Helper.standardTextHeight)
			-- Native ringing bell without a surrounding circle.
			r[bell]:createIcon("terraforming_xen_alert", {
				scaling = false, width = size, height = size,
				color = function () return Color[w.warningIgnored and "text_inactive" or "text_normal"] end,
				mouseOverText = function () return T(w.warningIgnored and 3154 or 3153) end,
			})
			r[bell + 1]:createCheckBox(function () return not w.warningIgnored end, {
				scaling = false, width = size, height = size, x = math.max(0, r[bell + 1]:getColSpanWidth() - size),
				mouseOverText = function () return T(w.warningIgnored and 3154 or 3153) end,
			})
			r[bell + 1].handlers.onClick = function (_, checked) menu.setWareWarnings(stationCode, ware, checked) end
		end
		r = metricRow(false)
		barCell(r[1]:setColSpan(6), w, name)
		r = metricRow(false)
		r[1]:setBackgroundColSpan(6):createText(fields("amount"), { wordwrap = true, mouseOverText = fields("amountTip") })
		r[2]:setColSpan(5):createText(fields("rate"), { halign = "right", wordwrap = true, mouseOverText = fields("long"), color = fields("rateColor") })
		r = metricRow(false)
		r[1]:setColSpan(6):createText(fields("coverage"),
			{ wordwrap = true, mouseOverText = fields("coverageTip"), color = Color["text_inactive"] })
		if w.export then
			r = metricRow(false)
			r[1]:setColSpan(6):createText(function ()
				local e = w.export or { state = "unknown" }
				local function rate(value) return value ~= nil and formatRate(value) or "?" end
				local state = ({ export = 3188, self = 3189, import = 3190, unknown = 3191 })[e.state] or 3191
				local text = T(3187, rate(e.production), w.workforceKnown == false and "?" or rate(w.workforce), rate(e.reserve), rate(e.surplus), rate(e.moduleCapacity), T(state))
				local output = e.state == "export" or e.state == "unknown"
				if output ~= not not w.output or (e.state == "import") ~= not not w.input then
					text = text .. " " .. T(3192)
				end
				return text
			end, { wordwrap = true, color = Color["text_inactive"] })
		end
		-- A small full-width spacer, following vanilla's explicit-height text rows.
		r = ftable:addRow(false, { borderBelow = false })
		r[1]:setColSpan(6):createText(" ", { fontsize = 1, height = 2 })
	end

	function details.expandStation(node, frame, ftable, nodedata, ftable2)
		-- The action buttons live here rather than on the node itself because the widget
		-- system dispatches only expand/collapse and slider events for a flowchart node -
		-- there is no click event for an icon on its label.
		stationToolbar(ftable, ftable2, ConvertStringTo64Bit(nodedata.scvid), nodedata.scvid)
		capToFrame(frame, ftable)
		setupColumns(ftable)

		local inputs  = sortedWares(nodedata.wares, function (w) return SCV_Graph.metricInput(w) end)
		local outputs = sortedWares(nodedata.wares, function (w) return SCV_Graph.metricOutput(w) end)

		sectionHeader(ftable, T(3170))
		local row
		local dockTip = T(3171) .. "\n\n" .. T(3172)
		for _, size in ipairs({ "s", "m", "l" }) do
			local dockSize = size
			row = ftable:addRow(false, {})
			row[1]:createText(function ()
				local dock = nodedata.logistics and nodedata.logistics.docks and nodedata.logistics.docks[dockSize]
				return logisticsTint(T(3180) .. " " .. (dockSize == "l" and "L/XL" or string.upper(dockSize)),
					dock and dock.total > 0 and dock.free == 0 and "warning" or "ok")
			end, { mouseOverText = dockTip })
			row[2]:setColSpan(5):createText(function () return dockLabel(nodedata.logistics, dockSize, false) end,
				{ halign = "right", mouseOverText = dockTip })
		end
		row = ftable:addRow(false, {})
		row[1]:createText(T(3178))
		row[2]:setColSpan(5):createText(function ()
			local drones = nodedata.logistics and nodedata.logistics.drones
			return logisticsCount(drones, drones ~= nil)
		end, { halign = "right" })
		local function queueTip() return presentation.dockQueueTip(nodedata.logistics) end
		row = ftable:addRow(false, {})
		row[1]:createText(T(3208), { mouseOverText = queueTip })
		row[2]:setColSpan(5):createText(function ()
			return presentation.dockQueueLabel(nodedata.logistics and nodedata.logistics.queue)
		end, { halign = "right", mouseOverText = queueTip })

		if (#inputs == 0) and (#outputs == 0) then
			row = ftable:addRow(false, {})
			row[1]:setColSpan(6):createText(T(3040), { wordwrap = true, color = Color["text_inactive"] })
			return
		end

		-- One radio for every ware this station both buys and sells. Mixed selects neither.
		local dual, consumers = {}, 0
		for ware, w in pairs(nodedata.wares or {}) do
			if w.dualTrade then
				dual[#dual + 1] = ware
				if w.consumerRole then consumers = consumers + 1 end
			end
		end
		local radioColumns = #dual > 0 and nodedata.code ~= nil and nodedata.code ~= ""

		local function section(title, list, isInput)
			sectionHeader(ftable, title)
			if #list == 0 then
				noneRow(ftable)
				return
			end
			for _, entry in ipairs(list) do
				detailEntry(ftable, "ware:" .. entry.ware, entry.w.name or entry.ware, entry.w, isInput, nodedata.code, entry.ware, radioColumns)
			end
		end
		if radioColumns then
			table.sort(dual)
			local state = nil -- mixed
			if consumers == #dual then state = true elseif consumers == 0 then state = false end
			local mixed = state == nil and ("\n" .. T(3202)) or ""
			row = ftable:addRow(true, { paddingTop = 8 })
			row[1]:setColSpan(4):createText(T(3199), { wordwrap = true })
			roleRadio(row, state, T(3197) .. "\n\n" .. T(3200) .. mixed, T(3198) .. "\n\n" .. T(3201) .. mixed,
				function (choice) menu.setStationConsumerRole(nodedata.code, dual, choice) end)
		end

		section(T(3031), inputs, true)
		section(T(3032), outputs, false)
	end

	-- Same entry layout as the station popup, with station names.
	function details.expandWare(node, frame, ftable, nodedata)
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
				tip = aggregateStockTooltip(nodedata.name, storage) }
		end)
		local totals = ftable:addRow("totals", { bgColor = Color["row_background_unselectable"], borderBelow = false })
		totals[1]:setColSpan(6):createText(fields("amount"), { wordwrap = true, mouseOverText = fields("tip") })
		local function totalRate(label, amountKey, knownKey, sign, color, tooltip)
			local values = liveFields(function ()
				local amount, known = nodedata[amountKey], nodedata[knownKey]
				local value = formatPartial(amount, known, true)
				if known or amount > 0 then value = sign .. value end
				local isInput = amountKey == "demandCap"
				local continuous = isInput and hasContinuousDemand(menu.graph, nodedata)
				local tip = table.concat({ nodedata.name, "", aggregateRateLine(amount, known, isInput),
					T(tooltip), "", rateAssumptions(isInput, continuous), T(isInput and 3145 or 3144) }, "\n")
				return { value = value, tip = tip }
			end)
			local row = ftable:addRow(false, { bgColor = Color["row_background_unselectable"], borderBelow = false })
			row[1]:setBackgroundColSpan(6):createText(T(label), { mouseOverText = values("tip") })
			row[2]:setColSpan(5):createText(values("value"), { halign = "right", wordwrap = true, color = color, mouseOverText = values("tip") })
		end
		totalRate(3084, "supplyCap", "supplyKnown", "+", Color["text_positive"], 3086)
		totalRate(3085, "demandCap", "demandKnown", "-", config.consumptionColor, 3087)

		local graph = menu.graph
		local function stationsFor(ids)
			local out = {}
			for _, sid in ipairs(ids or {}) do
				local sn = graph and (graph.metricStations or graph.stationNodes)[sid]
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
				detailEntry(ftable, "station:" .. tostring(entry.node.scvid), entry.node.name or "?", entry.w, isInput, entry.node.code, nodedata.scvware)
			end
		end

		section(T(3033), stationsFor(nodedata.metricProducers or nodedata.producers), false)
		section(T(3034), stationsFor(nodedata.metricConsumers or nodedata.consumers), true)
	end

	return details
end

return SCV_Details
