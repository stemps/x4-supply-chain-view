-- Loaded by test_metrics.py with its fake engine and native-style widget mocks.
local elapsedTime = getElapsedTime
function getElapsedTime() return 100 end
local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = copy(item) end
	return result
end

local supplier = { id = "supplier", id64 = "supplier", name = "Supplier", wares = {
	ore = { name = "Ore", output = true, stock = 100, limit = 1000,
		prodMax = 100, prodKnown = true, incoming = 50, outgoing = 20 } } }
local consumer = { id = "consumer", id64 = "consumer", name = "Consumer", wares = {
	ore = { name = "Ore", input = true, stock = 10, limit = 1000,
		consMax = 100, consKnown = true } } }
local graph = SCV_Graph.build({ copy(supplier), copy(consumer) })
menu.graph, menu.mode, menu.metricRevision = graph, "chain", 0
local ware = graph.wareNodes.ore
local station = graph.stationNodes.consumer
local record = station.wares.ore
local nodes, edges, predecessors = graph.nodes, graph.edges, station.predecessors
station.row, station.col = 7, 9
menu.decorateNodes(graph)

-- Exercise the actual render/update path, including clearing native warning colours.
local widgets, nodeCreates = {}, 0
menu.flowchart = { addNode = function (_, row, col, customdata, properties)
	nodeCreates = nodeCreates + 1
	local props = copy(properties)
	props.outlineColor, props.statusColor = "default-outline", false
	props.text, props.statustext = { color = "default-text" }, { color = "default-status" }
	local widget = { customdata = customdata, properties = props, handlers = {} }
	function widget:setText(text) self.properties.text.text = text; return self end
	function widget:setStatusText(text) self.status = text; return self end
	function widget:setStatusIcon(icon) self.icon = icon; return self end
	function widget:addEdgeTo() end
	function widget:updateOutlineColor(color) assert(color); self.outline = color end
	function widget:updateText(text, color) self.caption, self.textColor = text, color end
	function widget:updateStatus(text, icon, bg, color) self.status, self.icon, self.statusColor = text, icon, color end
	function widget:updateValue(value) self.value = value end
	function widget:updateMaxValue(value) self.max = value end
	widgets[#widgets + 1] = widget
	return widget
end }
menu.renderFlowchart(graph, {})
local nativeWare, nativeStation = ware[1].node, station[1].node
local popup = tableMock()
local panel = { properties = { height = 400 }, scroll = 73 }
function panel:update()
	for _, row in ipairs(popup.rows) do
		for i = 1, 2 do row[i]:update() end
	end
end
menu.expandWare(nil, panel, popup, ware)
menu.expandedNode, menu.expandedMenuFrame = nativeWare, panel
local rows = #popup.rows
local frameUpdates = 0
menu.frame = { update = function ()
	frameUpdates = frameUpdates + 1
	for _, widget in ipairs(widgets) do widget.tooltip = widget.properties.mouseOverText() end
end }
local function rowIndex(key)
	for i, row in ipairs(popup.rows) do if row.key == key then return i end end
	error("missing popup row " .. key)
end
local supplierRow = rowIndex("station:supplier")
local consumerRow = rowIndex("station:consumer")
assert(popup.rows[consumerRow + 2][1].text == "Amount 10 / 1.0k")
assert(popup.rows[supplierRow + 1][1].bar.current == 130)
assert(popup.rows[supplierRow + 3][1].text == "fills in 9.0h / from empty 10.0h")

-- No structural operation is allowed during a publication.
local build, breakCycles, budget = SCV_Graph.build, SCV_Graph.breakCycles, SCV_Graph.applyBudget
SCV_Graph.build = function () error("refresh rebuilt graph") end
SCV_Graph.breakCycles = function () error("refresh broke cycles") end
SCV_Graph.applyBudget = function () error("refresh changed budget") end
local freshSupplier, freshConsumer = copy(supplier), copy(consumer)
freshSupplier.wares.ore.stock, freshSupplier.wares.ore.prodMax = 400, 200
freshSupplier.wares.ore.incoming, freshSupplier.wares.ore.outgoing = 0, 100
freshConsumer.wares.ore.stock, freshConsumer.wares.ore.limit = 800, 2000
menu.publishMetrics({ freshSupplier, freshConsumer })
assert(ware.storage.stock == 1200 and ware.storage.capacity == 3000)
assert(ware.netRate == 100 and ware.supplyCap == 200 and ware.demandCap == 100)
assert(nativeWare.value == 1200 and nativeWare.max == 3000)
assert(nativeWare.status == "+100/h (+100%)")
assert(station.severity == "ok" and station.worstWare == nil)
assert(nativeStation.outline == "default-outline" and nativeStation.textColor == "default-text")
assert(nativeStation.statusColor == "default-status" and nativeStation.status == nil)
assert(not graph.structureChanged and not graph.refreshFailed)
assert(graph.nodes == nodes and graph.edges == edges and station.predecessors == predecessors)
assert(station.row == 7 and station.col == 9 and station.wares.ore == record)
assert(ware[1].node == nativeWare and nativeWare.customdata.moduledata == ware[1])
assert(nodeCreates == 3 and #popup.rows == rows and panel.scroll == 73)
assert(menu.expandedNode == nativeWare and menu.expandedMenuFrame == panel)
assert(popup.rows[2][1].text == "Amount 1.2k / 3.0k")
assert(popup.rows[3][2].text == "+200/h" and popup.rows[4][2].text == "-100/h")
assert(popup.rows[supplierRow + 1][1].bar.current == 300)
assert(popup.rows[supplierRow + 3][1].text == "fills in 3.0h / from empty 5.0h")
assert(popup.rows[consumerRow][1].props.color == "text_normal")
assert(string.find(nativeWare.tooltip, "1.2k", 1, true))
assert(string.find(popup.rows[supplierRow+1][1].bar.mouseOverText, "Stock: 400 / 1.0k", 1, true))
assert(string.find(popup.rows[supplierRow+1][1].bar.mouseOverText, "Reserved outgoing: 100", 1, true))
assert(not string.find(popup.rows[supplierRow+1][1].bar.mouseOverText, "Reserved incoming:", 1, true))
assert(popup.rows[supplierRow+2][1].props.mouseOverText == popup.rows[supplierRow+1][1].bar.mouseOverText)
assert(string.find(popup.rows[supplierRow+2][2].props.mouseOverText, "Maximum production: 200/h", 1, true))
assert(string.find(popup.rows[supplierRow+3][1].props.mouseOverText, "Full in: 3.0h", 1, true))
assert(string.find(popup.rows[3][2].props.mouseOverText, "Maximum production: 200/h", 1, true))
assert(string.find(popup.rows[2][1].props.mouseOverText, "Stock: 1.2k / 3.0k", 1, true))

-- Decreases, zero rates and cleared reservations must remove all previous derived state.
freshSupplier, freshConsumer = copy(supplier), copy(consumer)
freshSupplier.wares.ore.incoming, freshSupplier.wares.ore.outgoing = 0, 0
freshSupplier.wares.ore.prodMax, freshConsumer.wares.ore.consMax = 0, 0
freshSupplier.wares.ore.stock, freshConsumer.wares.ore.stock = 1, 2
menu.publishMetrics({ freshSupplier, freshConsumer })
assert(ware.netRate == 0 and ware.netKnown and ware.demandCap == 0)
assert(graph.stationNodes.consumer.severity == "ok")
assert(popup.rows[supplierRow + 1][1].bar.start == popup.rows[supplierRow + 1][1].bar.current)
assert(popup.rows[consumerRow + 3][1].text == "lasts ? / when full ?")
assert(popup.rows[supplierRow + 3][1].text == "fills in ? / from empty ?")

-- A failed station contributes unknowns, never stale figures or a fictitious known zero.
menu.publishMetrics({ copy(supplier), { id = "consumer", failed = true, wares = {} } })
assert(graph.refreshFailed and not graph.structureChanged and not ware.demandKnown)
assert(not ware.storage.stockKnown and ware.storage.stock == 100)
assert(popup.rows[consumerRow + 2][1].text == "Amount ? / ?")
assert(popup.rows[consumerRow + 2][2].text == "? /h")
assert(string.find(popup.rows[consumerRow+2][1].props.mouseOverText, "Stock unknown.", 1, true))
assert(string.find(popup.rows[consumerRow+2][2].props.mouseOverText, "Rate unknown:", 1, true))
assert(string.find(popup.rows[4][2].props.mouseOverText, "Incomplete total:", 1, true))
assert(not string.find(popup.rows[consumerRow+2][2].props.mouseOverText, "100/h", 1, true))
menu.publishMetrics({ copy(supplier), copy(consumer) })
assert(not graph.refreshFailed and ware.demandKnown and ware.storage.stock == 110)
assert(nativeStation.outline == "lso_node_error")

-- New modules update existing maximum rates; new wares/roles await a rebuild.
-- Storage construction and failed reads update an already open panel in place.
freshConsumer = copy(consumer)
freshConsumer.wares.ore.stock, freshConsumer.wares.ore.limit = 0, 0
freshConsumer.wares.ore.capacityUnits, freshConsumer.wares.ore.capacityUnitsKnown = 0, true
menu.publishMetrics({ copy(supplier), freshConsumer })
assert(station.wares.ore == record and record.capacityUnitsKnown)
assert(ware.storage.capacityKnown and ware.storage.capacity == 1000)
assert(nativeWare.value == 100 and nativeWare.max == 1000)
assert(popup.rows[consumerRow + 2][1].text == 'Amount 0 / 0')
freshConsumer.wares.ore.capacityUnits = 500
menu.publishMetrics({ copy(supplier), freshConsumer })
assert(ware.storage.capacity == 1500 and nativeWare.max == 1500)
assert(popup.rows[consumerRow + 2][1].text == 'Amount 0 / ~500')
menu.publishMetrics({ copy(supplier), {id='consumer', failed=true, wares={}} })
assert(not record.capacityUnitsKnown and not ware.storage.capacityKnown)
assert(popup.rows[consumerRow + 2][1].text == 'Amount ? / ?')
freshConsumer.wares.ore.capacityUnits = 0
menu.publishMetrics({ copy(supplier), freshConsumer })
assert(record.capacityUnitsKnown and ware.storage.capacityKnown and ware.storage.capacity == 1000)
assert(popup.rows[consumerRow + 2][1].text == 'Amount 0 / 0')
assert(station.wares.ore == record and menu.expandedMenuFrame == panel and panel.scroll == 73)
assert(nodeCreates == 3 and #popup.rows == rows)

freshSupplier = copy(supplier)
freshSupplier.wares.ore.prodMax = 300
freshSupplier.wares.food = { input = true, stock = 50, consMax = 20, consKnown = true }
menu.publishMetrics({ freshSupplier, copy(consumer) })
assert(graph.structureChanged and ware.supplyCap == 300)
assert(not graph.stationNodes.supplier.wares.food and not graph.wareNodes.food)
freshConsumer = copy(consumer)
freshConsumer.wares.ore.input, freshConsumer.wares.ore.output = false, true
menu.publishMetrics({ copy(supplier), freshConsumer })
assert(graph.structureChanged and not ware.demandKnown and record.input and not record.output)
menu.publishMetrics({ copy(supplier), { id = "consumer", missing = true, wares = {} } })
assert(graph.structureChanged and not ware.storage.stockKnown)
freshConsumer = copy(consumer)
freshConsumer.locked, freshConsumer.wares.ore.stockKnown = true, false
menu.publishMetrics({ copy(supplier), freshConsumer })
assert(not graph.structureChanged and graph.lockedCount == 1 and not ware.storage.stockKnown)
menu.publishMetrics({ copy(supplier), copy(consumer) })
assert(graph.lockedCount == 0 and ware.storage.stockKnown)
SCV_Graph.build, SCV_Graph.breakCycles, SCV_Graph.applyBudget = build, breakCycles, budget

-- Budget-hidden endpoints cannot cause a nil dereference on subsequent sweeps.
local sources = { copy(supplier), copy(consumer) }
for i = 1, 5 do
	local extra = copy(supplier)
	extra.id = "extra" .. i
	sources[#sources + 1] = extra
end
local limited = SCV_Graph.build(copy(sources), { limits = { maxNodes = 4, maxEdges = 3 } })
assert(#limited.droppedStations > 0)
local stockBefore = limited.wareNodes.ore and limited.wareNodes.ore.storage.stock
SCV_Graph.refreshMetrics(limited, copy(sources))
assert(not limited.structureChanged and #limited.nodes <= 4)
assert(not limited.wareNodes.ore or limited.wareNodes.ore.storage.stock == stockBefore)

-- The explicit cursor visits every station once, with atomic publication and no catch-up.
local readStation, describe = SCV_Data.readStation, SCV_Data.describe
local reads, failID, missingID, changedCodeID = {}, nil, nil, nil
SCV_Data.describe = function (id)
	if id == missingID then return nil end
	return { id = id, id64 = id, code = id == changedCodeID and "different" or id }
end
SCV_Data.readStation = function (st)
	reads[#reads + 1] = st.id
	if st.id == failID then error("temporary failure") end
	return { id = st.id, name = st.id, wares = {} }
end
for _, count in ipairs({ 1, 10, 25, 50 }) do
	local members = {}
	for i = 1, count do members[i] = { id = tostring(i), id64 = tostring(i), code = tostring(i) } end
	local state = SCV_Data.newRefresh(members, 0)
	reads = {}
	local cache = SCV_Data.cache
	assert(SCV_Data.refreshStep(state, 4.99) == nil and #reads == 0)
	for i = 1, count do
		local result = SCV_Data.refreshStep(state, 5 + (i - 1) * 0.2)
		assert(#reads == i and reads[i] == tostring(i))
		if i < count then assert(result == nil)
		else assert(#result == count and state.pending == nil) end
		assert(SCV_Data.cache == cache)
	end
	if count < 25 then assert(SCV_Data.refreshStep(state, 9.99) == nil) end
	SCV_Data.refreshStep(state, 5 + math.max(5, count * 0.2))
	assert(#reads == count + 1 and reads[#reads] == "1")
end
local state = SCV_Data.newRefresh({ { id = "bad", id64 = "bad", code = "bad" } }, 0)
failID = "bad"
local result = SCV_Data.refreshStep(state, 5)
assert(result[1].failed)
failID = nil
assert(not SCV_Data.refreshStep(state, 10)[1].failed)
missingID = "bad"
assert(SCV_Data.refreshStep(state, 15)[1].missing)
missingID, changedCodeID = nil, "bad"
assert(SCV_Data.refreshStep(state, 20)[1].missing)
changedCodeID = nil
assert(not SCV_Data.refreshStep(state, 25)[1].missing)

-- A delayed callback does just one read; disabling the diagnostic A/B switch does none.
local two = { { id = "1" }, { id = "2" } }
state = SCV_Data.newRefresh(two, 0)
reads = {}
assert(SCV_Data.refreshStep(state, 1000) == nil and #reads == 1)
SCV_Data.REFRESH_ENABLED = false
assert(SCV_Data.refreshStep(state, 2000) == nil and #reads == 1)
SCV_Data.REFRESH_ENABLED = true

-- The menu itself publishes once at sweep completion, without calling display/layout.
local display = menu.display
menu.display = function () error("live refresh redrew the menu") end
menu.mode, menu.scanDone, menu.refresh = "chain", true, nil
menu.refreshState = SCV_Data.newRefresh(two, 95)
local revision, updates = menu.metricRevision, frameUpdates
menu.onUpdate()
assert(menu.metricRevision == revision and frameUpdates == updates)
menu.onUpdate()
assert(menu.metricRevision == revision + 1 and frameUpdates == updates + 1)
assert(menu.expandedNode == nativeWare and panel.scroll == 73 and #popup.rows == rows)
menu.display = display

-- Switching chains and closing discard a partially collected sweep.
local currentMembers = menu.currentMembers
menu.refreshState, menu.scanDone = state, true
menu.markDirty()
assert(menu.refreshState == nil and not menu.scanDone)
menu.refreshState = state
menu.cleanup()
assert(menu.refreshState == nil and menu.graph == nil)
menu.currentMembers = currentMembers
SCV_Data.readStation, SCV_Data.describe = readStation, describe
getElapsedTime = elapsedTime
