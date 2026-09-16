-- Exercise actual overlay creation with native-shaped frame/table handles.
-- No claim about Anark's rendering: anchors, clipping, grouping and lifecycle
-- are the contracts this fake engine can verify before the in-game test.
local anchors = { a = {300, 100}, b = {300, 350}, c = {900, 100} }
local scale, displays, clears = 1, 0, 0
Helper.standardFont = "Zekton"
Helper.scaleX = function (v) return v * scale end
Helper.scaleY = Helper.scaleX
Helper.scaleFont = function (_, v) return math.ceil(v * scale) end
Helper.clearFrame = function (_, layer) assert(layer == 2); clears = clears + 1 end
function GetFlowchartNodeExpandedFrameData(id)
	local anchor = anchors[id]
	if anchor then return anchor[1] * scale, anchor[2] * scale, 4, 4 end
end
function GetSize(id)
	if id == "chart" then return 1500 * scale, 900 * scale end
	assert(anchors[id]); return 310 * scale, 30 * scale
end
function Helper.createFrameHandle(_, properties)
	local frame = { properties = properties, tables = {} }
	assert(properties.layer == 2 and properties.enableDefaultInteractions == false)
	function frame:addTable(n, props)
		assert(n <= 13 and props.borderEnabled == true and props.tabOrder == 0)
		local t = { properties = props, rows = {}, height = 0, ncols = n, widths = {} }
		function t:setColWidth(i, w, scaling) assert(scaling == false); self.widths[i] = w end
		function t:getFullHeight()
			local h = 0
			for _, row in ipairs(self.rows) do h = h + row.properties.paddingTop + (row.measuredHeight or 0) end
			return h
		end
		function t:addRow(_, rowprops)
			assert(rowprops.bgColor.a == 0, "hit surfaces must remain transparent")
			local row = { properties = rowprops }
			for i = 1, n do
				local cell = {}
				function cell:setColSpan(span) self.span = span; return self end
				function cell:createText(text, textprops)
					self.text, self.properties = text, textprops
					row.measuredHeight = textprops.height
					return self
				end
				row[i] = cell
			end
			self.rows[#self.rows + 1] = row
			self.height = self.height + rowprops.paddingTop + 22 * scale
			return row
		end
		self.tables[#self.tables + 1] = t
		return t
	end
	function frame:update() self.updates = (self.updates or 0) + 1 end
	function frame:display()
		displays = displays + 1
		for _, t in ipairs(self.tables) do
			assert(t.properties.y + t:getFullHeight() <= self.properties.height)
			for _, row in ipairs(t.rows) do
				local col = 1
				while col <= t.ncols do
					assert(row[col].text ~= nil, "every native cell must be filled or spanned")
					col = col + 1
				end
				assert(col == t.ncols + 1)
			end
		end
	end
	return frame
end
-- The reported examples, plus long values and unknowns, must fit both lines.
for _, example in ipairs({
	{ s = { free=20,total=20 }, m={free=6,total=8}, l={free=8,total=9}, drones=60 },
	{ s = { free=30,total=30 }, m={free=12,total=12}, l={free=15,total=20}, drones=143 },
	{ s = { free=1234,total=12345 }, m={free=0,total=100}, l={free=0,total=0}, drones=999 },
	{},
}) do
	for _, uiScale in ipairs({1, 1.25, 1.5, 2}) do
		scale = uiScale
		local data = {docks=example, drones=example.drones, shipsKnown=true, categories={}}
		local rows = menu.logisticsRows(data)
		assert(#rows == 1 and #rows[1].entries == 7, "zero ship categories occupy no metric columns")
		for _, entry in ipairs(rows[1].entries) do
			if entry.text ~= "" then
				local header, count = entry.text:match("^(.-)\n(.*)$")
				assert(header and count)
				for _, line in ipairs({header,count}) do
					assert(C.GetTextWidth(line, Helper.standardFont, Helper.scaleFont(nil, 8)) + 4*scale <= entry.width)
				end
				assert(C.GetTextHeight(entry.text, Helper.standardFont, Helper.scaleFont(nil, 8), 0) <= rows[1].height)
			end
		end
	end
end
scale = 1
local snapshot = SCV_Data.readLogistics("A")
local function node(id, col)
	return { scvkind = "station", col = col, logistics = snapshot,
		logisticsRows = menu.logisticsRows(snapshot), [1] = { properties = {}, node = { id = id } } }
end
menu.graph = { nodes = {node("a", 1), node("b", 1), node("c", 3)} }
menu.flowchart = { id = "chart", properties = { x = 0, y = 0 } }
menu.mode, menu.closed, menu.metricRevision = "chain", false, 1
menu.expandedMenuFrame = nil
menu.updateLogisticsStrip()
assert(#menu.logisticsFrame.tables == 2, "share one table per column, not per station")
local layout = menu.logisticsColumnLayouts[1]
assert(layout.width == 310, "dock and ship groups span exactly the station width")
assert(menu.logisticsFrame.tables[1].properties.x == 145 or menu.logisticsFrame.tables[1].properties.x == 745)
assert(menu.graph.nodes[1].logisticsRows[1].entries[1].header == "\27[stationbuildst_dock]")
assert(menu.graph.nodes[1][1].properties.y == nil, "overlay measurement must not change node geometry")
local count = displays
menu.updateLogisticsStrip()
assert(displays == count, "stable anchors must not recreate the overlay")
local shipTips, dockTips, droneTips, droneCell = 0, 0, 0, nil
local function value(v) return type(v)=="function" and v() or v end
for _, t in ipairs(menu.logisticsFrame.tables) do
	assert(t.properties.y == 118, "strip is outside, below the 30px node")
	for _, row in ipairs(t.rows) do
		for _, cell in ipairs(row) do
			local props = cell.properties
			if props then assert(props.fontsize == math.ceil(8 * scale)) end
			if props and value(props.mouseOverText):find("Cargo drones", 1, true) then
				droneTips, droneCell = droneTips + 1, cell
				assert(value(props.color) == "faction_green")
			elseif props and value(props.color) == "faction_green" then
				shipTips = shipTips + 1
				assert(value(props.mouseOverText):find("Idle:", 1, true))
			elseif props and value(props.mouseOverText):find("Docks ", 1, true) then
				dockTips = dockTips + 1
			end
		end
	end
end
assert(shipTips == 12 and dockTips == 9 and droneTips == 3)
local originalFrame = menu.logisticsFrame
snapshot.drones = 25
for _,data in ipairs(menu.graph.nodes) do data.logisticsRows = menu.logisticsRows(snapshot) end
menu.metricRevision = menu.metricRevision + 1
menu.updateLogisticsStrip()
assert(menu.logisticsFrame == originalFrame and displays == count, "metric publications must preserve tooltip widget identity")
assert(value(droneCell.text):find("25",1,true), "existing widget must read the latest snapshot")
anchors.a[2] = 160
menu.updateLogisticsStrip()
assert(displays == count + 1, "scrolling must move tooltips with the station")
anchors.c = nil -- native node is no longer visible
menu.updateLogisticsStrip()
assert(#menu.logisticsFrame.tables == 1)
menu.expandedMenuFrame = { properties = { x = 0, y = 170, width = 600, height = 500 } }
menu.updateLogisticsStrip()
assert(menu.logisticsFrame == nil, "strip must not draw over an expanded panel")
menu.expandedMenuFrame = nil
scale = 1.5
for _, data in ipairs(menu.graph.nodes) do data.logisticsRows = menu.logisticsRows(snapshot) end
menu.updateLogisticsStrip()
assert(menu.logisticsFrame and menu.logisticsFrame.properties.width == 2250)
anchors.a[1], anchors.b[1] = 100, 100 -- partial column outside the viewport
menu.updateLogisticsStrip()
assert(menu.logisticsFrame, "partially visible strips retain visible metric columns")
for _, t in ipairs(menu.logisticsFrame.tables) do
	assert(t.properties.x >= 0 and t.properties.x + t.properties.width <= menu.logisticsFrame.properties.width)
end
anchors.a[1], anchors.b[1] = 300, 300
menu.updateLogisticsStrip()
-- Overlay widths follow current text without growing or redrawing the graph.
local oldWidth = menu.logisticsColumnLayouts[1].width
snapshot.drones = string.rep("8", 60)
for _, data in ipairs(menu.graph.nodes) do data.logisticsRows = menu.logisticsRows(snapshot) end
local savedDisplay, savedDecorate, savedFrame = menu.display, menu.decorateNodes, menu.frame
local savedPanel = menu.expandedMenuFrame
menu.display = function () error("wide logistics must not redraw the graph") end
menu.decorateNodes = function () end -- rows above already contain the widened text
menu.frame = { update = function () end }
menu.expandedMenuFrame = nil
local chartBefore = menu.flowchart
for _, data in ipairs(menu.graph.nodes) do
	local widget = data[1].node
	widget.customdata = {}
	widget.updateOutlineColor = function () end
	widget.updateText = function () end
	widget.updateStatus = function () end
end
menu.updateMetricDisplay()
assert(menu.flowchart == chartBefore, "wide logistics preserves the native chart")
menu.display, menu.decorateNodes, menu.frame = savedDisplay, savedDecorate, savedFrame
menu.expandedMenuFrame = savedPanel
menu.prepareLogisticsColumns(menu.graph)
assert(menu.logisticsColumnLayouts[1].width > oldWidth)
local grown = menu.logisticsColumnLayouts[1].width
snapshot.drones = 1
for _, data in ipairs(menu.graph.nodes) do data.logisticsRows = menu.logisticsRows(snapshot) end
menu.prepareLogisticsColumns(menu.graph)
assert(menu.logisticsColumnLayouts[1].width < grown)
assert(menu.graph.nodes[1][1].properties.y == nil)
-- More than thirteen columns become adjacent tables on one baseline.
scale = 1
snapshot.categories = {}
for i = 1, 16 do snapshot.categories[i] = { total = i, idle = 0, rank = i, size = "m", purpose = "trade", icon = "ship_m_transporter_01" } end
anchors.a, anchors.b = {750,100}, {750,350}
for _, data in ipairs(menu.graph.nodes) do data.logisticsRows = menu.logisticsRows(snapshot) end
menu.prepareLogisticsColumns(menu.graph)
menu.updateLogisticsStrip()
assert(#menu.logisticsFrame.tables == 2)
local columns = 0
for _, t in ipairs(menu.logisticsFrame.tables) do
	columns = columns + t.ncols
	assert(t.properties.y == 118)
	for _, row in ipairs(t.rows) do
		for _, cell in ipairs(row) do
			local text = value(cell.text)
			if text ~= "" then
				local _, newlines = text:gsub("\n", "")
				assert(newlines == 1, "exactly two lines per metric")
				assert(cell.properties.halign == "center")
			end
		end
	end
end
assert(columns == 23, "all nonzero categories are retained")
-- Stations with fewer categories keep their final ship cell at the right edge.
local short = node("short",1)
short.logisticsRows = menu.logisticsRows({shipsKnown=true,drones=3,categories={}})
local long = node("long",1)
local alignmentGraph = {nodes={short,long}}
menu.prepareLogisticsColumns(alignmentGraph)
local sharedCount = #long.logisticsRows[1].entries
assert(#short.logisticsRows[1].entries == sharedCount)
assert(short.logisticsRows[1].entries[sharedCount].text:find("ships_idling_01",1,true))
assert(short.logisticsRows[1].entries[sharedCount-1].text:find("ship_xs_drone_trade_01",1,true))
assert(short.logisticsRows[1].entries[sharedCount].tip:find("\n\n",1,true))
assert(not short.logisticsRows[1].entries[sharedCount].tip:find("—",1,true))
menu.prepareLogisticsColumns(alignmentGraph)
assert(#short.logisticsRows[1].entries == sharedCount, "alignment padding must not accumulate")
-- The native table limit is respected without changing graph spacing.
local budgetGraph = {nodes={}}
for i=1,20 do
	local data = node("budget"..i, i)
	budgetGraph.nodes[i] = data
end
menu.prepareLogisticsColumns(budgetGraph)
local x = -1000
for i,data in ipairs(budgetGraph.nodes) do
	local layout = menu.logisticsColumnLayouts[i]
	assert(layout.minWidth == nil)
	anchors["budget"..i] = {x + 175,100}
	x = x + 350
end
local savedSize = GetSize
GetSize = function(id) if id=="chart" then return 6000,900 end return savedSize(id) end
menu.graph = budgetGraph
menu.updateLogisticsStrip()
assert(#menu.logisticsFrame.tables <= 12)
GetSize = savedSize
menu.closed = true
menu.updateLogisticsStrip()
assert(menu.logisticsFrame == nil and clears > 0)
print("PASS logistics overlay: anchors, per-metric tooltips, column pooling, scroll, clipping, scale and cleanup")
