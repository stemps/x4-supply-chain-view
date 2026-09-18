-- Supply Chain View — native logistics placement and screen-session failure handling.
-- Depends: scv_presentation.lua, scv_store.lua, scv_overlay_view.lua
SCV_LogisticsView = {}

-- Frame and cache state stays on the controller for its existing lifecycle hooks.
function SCV_LogisticsView.new(menu, config, presentation)
	local component = {}
	local T = presentation.T
	local function log(msg) DebugError("SCV: " .. tostring(msg)) end

function component.prepareLogisticsColumns(graph)
	local layouts = {}
	menu.logisticsColumnLayouts = layouts
	for _, node in ipairs(graph.nodes) do
		if node.scvkind == "station" and node.col then
			local layout = layouts[node.col] or { widths = {}, height = 0, count = 0 }
			layouts[node.col] = layout
			local line = node.logisticsRows[1]
			line.baseEntries = line.baseEntries or line.entries
			layout.count = math.max(layout.count, #line.baseEntries)
		end
	end
	for _, node in ipairs(graph.nodes) do
		if node.scvkind == "station" and node.col then
			local layout, line = layouts[node.col], node.logisticsRows[1]
			local entries, base = {}, line.baseEntries
			for i = 1, 5 do entries[i] = base[i] end
			local padding = layout.count - #base
			for i = 1, padding do entries[5+i] = {text="", tip="", width=1} end
			for i = 6, #base do entries[i+padding] = base[i] end
			line.entries = entries
			for i, entry in ipairs(entries) do
				if i ~= 5 then layout.widths[i] = math.max(layout.widths[i] or 0, entry.width) end
			end
			layout.widths[5] = 10 * (Helper.uiScale or Helper.scaleY(1000)/1000)
			layout.height = math.max(layout.height, line.height)
		end
	end
	for _, layout in pairs(layouts) do
		layout.width = math.max(0, #layout.widths - 1) * (Helper.borderSize or 1)
		for _, w in ipairs(layout.widths) do layout.width = layout.width + w end
		local targetWidth = math.max(layout.width, Helper.scaleY(config.stationNodeWidth))
		layout.widths[5] = layout.widths[5] + targetWidth - layout.width
		layout.width = targetWidth
	end
end

function component.updateLogisticsStrip()
	local chart = menu.flowchart
	local function hide()
		if menu.nativeLogistics then pcall(function () menu.nativeLogistics:hide() end) end
	end
	if not SCV_Store.getShowLogistics() then hide(); return end
	if menu.nativeLogisticsFailed then return end
	if menu.closed or menu.mode ~= "chain" or menu.refresh or not chart or not chart.id or not menu.graph then hide(); return end
	local ok, err = pcall(function ()
		if not menu.nativeLogistics then menu.nativeLogistics = SCV_Overlay.newView() end
		local obstacles = {}
		for _, field in ipairs({ "expandedMenuFrame", "managementFrame", "statusFrame" }) do
			local panel = menu[field]
			if panel then
				if not panel.id then hide(); return end
				local p = panel.properties
				obstacles[#obstacles+1] = { x=p.x-4, y=p.y-4, width=p.width+8, height=p.height+8 }
			end
		end
		if menu.nativeLayoutGraph ~= menu.graph or menu.nativeLayoutRevision ~= menu.metricRevision then
			menu.prepareLogisticsColumns(menu.graph)
			menu.nativeLayoutGraph, menu.nativeLayoutRevision = menu.graph, menu.metricRevision
			menu.nativeLogistics.widths = {}
		end
		local width, height = GetSize(chart.id)
		local stations = {}
		for _, data in ipairs(menu.graph.nodes) do
			local widget = data.scvkind == "station" and data[1] and data[1].node
			local layout = menu.logisticsColumnLayouts[data.col]
			if widget and widget.id and layout then
				local x,y = GetFlowchartNodeExpandedFrameData(widget.id)
				if x then
					local _, nh = GetSize(widget.id)
					stations[#stations+1] = { key=data, line=data.logisticsRows[1], layout=layout,
						x=math.floor(x-layout.width/2), y=math.floor(y+nh/2+Helper.scaleY(3)) }
				end
			end
		end
		menu.nativeLogistics:update(stations,{x=chart.properties.x,y=chart.properties.y,width=width,height=height},
			obstacles,chart.id,Helper.standardFont,Helper.scaleFont(Helper.standardFont,config.logisticsFontSize),Helper.uiScale)
	end)
	if not ok then
		hide(); menu.nativeLogisticsFailed=true
		menu.nativeLogistics=nil
		log("grouped logistics disabled: " .. tostring(err))
		menu.notice=T(3184); menu.noticeUntil=nil
	end
end

function component.clearLogisticsStrip()
	if menu.nativeLogistics then
		local ok = pcall(function () menu.nativeLogistics:reset() end)
		if not ok then menu.nativeLogistics=nil end
	end
	menu.nativeLayoutRevision, menu.nativeLayoutGraph = nil, nil
end


return component
end

return SCV_LogisticsView
