-- Supply Chain View — chart construction and in-place node decoration.
-- Depends: scv_presentation.lua, scv_graph.lua, scv_data.lua, scv_store.lua
SCV_Chart = {}

function SCV_Chart.new(menu, config, presentation)
	local component = {}
	local T = presentation.T
	local severityColor = presentation.severityColor
	local formatHours = presentation.formatHours
	local formatSigned = presentation.formatSigned
	local aggregateStatus = presentation.aggregateStatus
	local aggregateStockTooltip = presentation.aggregateStockTooltip
	local aggregateRateLine = presentation.aggregateRateLine
	local rateAssumptions = presentation.rateAssumptions
	local hasContinuousDemand = presentation.hasContinuousDemand
	local warningReason = presentation.warningReason
	local function log(msg) DebugError("SCV: " .. tostring(msg)) end

function component.decorateNodes(graph)
	local visible = {}
	graph.footnoteKeys = { "partial" }
	for _, node in ipairs(graph.nodes) do visible[node] = true; node.footnotes = {} end
	for _, entry in ipairs({ { "cycle", graph.droppedEdges }, { "budget", graph.budgetDroppedEdges } }) do
		local used = false
		for _, edge in ipairs(entry[2] or {}) do
			if visible[edge.from] and visible[edge.to] and edge.to.scvkind == "station" then
				edge.to.footnotes[entry[1]], used = true, true
			end
		end
		if used then graph.footnoteKeys[#graph.footnoteKeys + 1] = entry[1] end
	end
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

			node.text = (node.name or node.scvid or "?") .. presentation.footnoteMarkers(node.footnotes)
			for _, key in ipairs(graph.footnoteKeys) do
				if node.footnotes[key] then parts[#parts + 1] = presentation.footnoteLine(key) end
			end
			node.logisticsRows = SCV_Store.getShowLogistics() and menu.logisticsRows(node.logistics) or nil
			node.type = "container"
			node[1] = {
				properties = {
					shape         = "rectangle",
					width         = config.stationNodeWidth,
					x             = config.nodeOffsetX,
					y             = node.logisticsRows and (node.logisticsRows[1].height / (Helper.scaleY(1000) / 1000) + 3 + Helper.standardFontSize) / 2 or 0,
					mouseOverText = (warningReason(warningName, warningHealth, parts)
						or ((#parts > 0) and table.concat(parts, "\n") or T(3014))),
				},
				statuscolor = severityColor(node.severity),
				outlinecolor = severityColor(node.severity),
			}
			if node.severity ~= "ok" then
				local h = node.wares[node.worstWare].health
				node[1].statusText = T(3028, formatHours(h.hours))
			end
		else
			-- Inventory fill and full-operation hourly balance are separate metrics.
			local storage = node.storage
			local known = storage.stockKnown and storage.capacityKnown and storage.capacity > 0
			local lines = { aggregateStockTooltip(node.name, storage), "",
				aggregateRateLine(node.supplyCap, node.supplyKnown, false, true),
				aggregateRateLine(node.demandCap, node.demandKnown, true, true),
			}
			if node.netKnown then
				lines[#lines + 1] = T(3151, formatSigned(node.netRate))
			else
				lines[#lines + 1] = T(3160)
			end
			lines[#lines + 1] = ""
			lines[#lines + 1] = rateAssumptions(true, hasContinuousDemand(graph, node))
			lines[#lines + 1] = T(3143)
			lines[#lines + 1] = T(3144)
			local rateText, rateColor = aggregateStatus(node)
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

function component.drawChainPlaceholder(frame, x, y, width, header, text)
	menu.chainPlaceholder = { header = header, text = text }
	local ftable = frame:addTable(1, { tabOrder = 2, width = width, x = x, y = y })
	if header then ftable:addRow(false, { fixed = true })[1]:createText(header, Helper.headerRowCenteredProperties) end
	if text then ftable:addRow(false, { fixed = true })[1]:createText(text, { wordwrap = true }) end
end

-- Full-width diagram beneath the toolbar and status strip.
function component.displayChain(frame, x, y, width, reuseGraph)
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

		graph = SCV_Graph.build(stations, { isWarningIgnored = SCV_Store.isWarningIgnored, deferBudget = true })
		menu.graph = graph
		if not graph then
			return
		end
		menu.refreshState = SCV_Data.newRefresh(members, getElapsedTime())

	end
	if not reuseGraph or not menu.graphLayout then
		menu.graphLayout = SCV_Graph.fitLayout(graph, Helper.setupDAGLayout)
	end
	menu.decorateNodes(graph)
	local numrows, numcols, junctions = menu.graphLayout.rows, menu.graphLayout.cols, menu.graphLayout.junctions
	local layout = menu.graphLayout
	if not layout.fits then
		log(string.format("chain over budget after layout fallback: %d nodes, %d edges, %d cols",
			layout.postNodes, layout.postEdges, numcols))
		menu.drawChainPlaceholder(frame, x, y, width, T(4000), T(3194,
			tostring(layout.postNodes), tostring(SCV_Graph.LIMITS.maxNodes),
			tostring(layout.postEdges), tostring(SCV_Graph.LIMITS.maxEdges),
			tostring(numcols), tostring(SCV_Graph.LIMITS.maxCols)))
		return
	end

	-- No ware nodes at all means every station's offers are disjoint. That is a real and
	-- common answer ("these do not actually trade with each other"), and it must not look
	-- like a rendering failure.
	if next(graph.wareNodes) == nil and #graph.collapsedWares == 0 and #graph.droppedStations == 0 then
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
		notes[#notes + 1] = T(4001, tostring(layout.initial.nodes), tostring(layout.initial.edges),
			tostring(SCV_Graph.LIMITS.maxNodes), tostring(SCV_Graph.LIMITS.maxEdges),
			table.concat(names, ", "))
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
	if numrows == 1 then
		-- Native visible-cell counting uses a strict '<' fit. Helper's exact
		-- content height otherwise leaves this one row uncounted (numRows=1).
		local getVisibleHeight = menu.flowchart.getVisibleHeight
		menu.flowchart.getVisibleHeight = function (chart)
			return math.min(getVisibleHeight(chart) + 1, chart:getMaxVisibleHeight())
		end
	end
	menu.flowchart:setDefaultNodeProperties({
		expandedFrameLayer      = config.expandedMenuFrameLayer,
		expandedTableNumColumns = 4,
		x     = config.nodeOffsetX,
		-- per-node width overrides this; it is only the fallback
		width = config.wareNodeWidth,
	})

	menu.renderFlowchart(graph, junctions)
	menu.drawChainLegend(frame, x, chartY, width)
end

-- Reserve wrapped footer space before measuring the chart's visible height, as
-- vanilla station overview does for its tables below the flowchart.
function component.drawChainLegend(frame, x, chartY, width)
	local footer = frame:addTable(1, { tabOrder = 4, width = width, x = x, y = chartY })
	for _, key in ipairs(menu.graph and menu.graph.footnoteKeys or { "partial" }) do
		footer:addRow(false, { fixed = true })[1]:createText(presentation.footnoteLine(key), { wordwrap = true })
	end
	menu.flowchart.properties.maxVisibleHeight = math.max(1,
		frame:getAvailableHeight() - chartY - footer:getFullHeight() - Helper.borderSize - Helper.frameBorder)
	footer.properties.y = chartY + menu.flowchart:getVisibleHeight() + Helper.borderSize
end

-- The node/junction/edge loop, modelled on menu_station_overview.lua:1774-1915 and
-- simplified because each of our nodes carries exactly one sub-cell.
function component.renderFlowchart(graph, junctions)
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
			if nodedata.logisticsRows and menu.graphLayout and nodedata.row == menu.graphLayout.rows then
				-- Keep interior rows compact. Only the final layout row needs its
				-- entire strip inside the cell to clear the lower graph border.
				-- Clipping still protects the border at intermediate scroll positions.
				properties.y = math.max(properties.y or 0,
					(math.ceil(nodedata.logisticsRows[1].height) + math.ceil(Helper.scaleY(3)) + 1)
						/ (Helper.scaleY(1000) / 1000))
			end
			properties.mouseOverText = function () return nodedata[1].properties.mouseOverText end
			local node = menu.flowchart:addNode(nodedata.row, nodedata.col,
				{ nodedata = nodedata, moduledata = moduledata }, properties)
				:setText(nodedata.text)
			node.scvDefaultOutline = node.properties.outlineColor
			node.scvDefaultText = node.properties.text.color
			node.scvDefaultStatus = node.properties.statusColor or node.properties.statustext.color

			if moduledata.outlinecolor then
				node.properties.outlineColor = moduledata.outlinecolor
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
return component
end

return SCV_Chart
