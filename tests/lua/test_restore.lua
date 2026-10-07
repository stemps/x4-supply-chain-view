-- An open detail panel survives redraws: real menu.display, renderFlowchart and onUpdate,
-- with native frame and engine calls stubbed around them.
local saved = {}
local function stub(t, key, value) saved[#saved+1] = {t, key, t[key]}; t[key] = value end
local logs = {}
stub(_G, 'DebugError', function(msg) logs[#logs+1] = msg end)
stub(_G, 'GetCurRealTime', function() return 0 end)
stub(_G, 'getElapsedTime', function() return 100 end)
local chainA, chainB = {name='A'}, {name='B'}
local selected = chainA
stub(SCV_Store, 'selected', function() return selected, 1 end)
for key, value in pairs({ borderSize=2, viewWidth=1920, viewHeight=1080, sidebarWidth=40, frameBorder=4,
		standardButtonHeight=24 }) do
	stub(Helper, key, value)
end
stub(Helper, 'scaleX', function(x) return x end)
stub(Helper, 'scaleY', function(x) return x end)
stub(Helper, 'clearDataForRefresh', function() end)
stub(Helper, 'createFrameHandle', function()
	return { setBackground=function() end, display=function() end }
end)
for _, name in ipairs({'clearLogisticsStrip', 'createTopLevel', 'displayToolbar', 'updateStatusStrip',
		'updateLogisticsStrip', 'openManagement'}) do
	stub(menu, name, function() end)
end
stub(menu, 'onFlowchartNodeCollapsed', function() end)

local function graphOf()
	local g = SCV_Graph.build({
		{id='supplier', code='SUP-001', name='Supplier', wares={ore={name='Ore', output=true,
			stock=100, limit=1000, prodMax=100, prodKnown=true}}},
		{id='consumer', code='CON-001', name='Consumer', wares={ore={name='Ore', input=true,
			stock=10, limit=1000, consMax=10, consKnown=true}}},
	})
	g.stationNodes.supplier.row, g.stationNodes.supplier.col = 1, 1
	g.wareNodes.ore.row, g.wareNodes.ore.col = 1, 2
	g.stationNodes.consumer.row, g.stationNodes.consumer.col = 1, 3
	return g
end
local graph, expands, renders = graphOf(), 0, 0
local function fakeFlowchart()
	return { addNode = function(_, row, col, customdata, properties)
		properties.text, properties.statustext = { color = 'text' }, { color = 'status' }
		local widget = { customdata = customdata, properties = properties, handlers = {} }
		function widget:setText() return self end
		function widget:setStatusText() return self end
		function widget:setStatusIcon() return self end
		function widget:addEdgeTo() end
		function widget:collapse() end
		function widget:expand() expands = expands + 1; menu.expandedNode = self; menu.expandedChain = selected end
		return widget
	end, addJunction = function() return {} end }
end
local drawGraph = true
stub(menu, 'displayChain', function()
	if not drawGraph then return end -- a scan placeholder renders no chart
	renders = renders + 1
	menu.decorateNodes(graph)
	menu.flowchart = fakeFlowchart()
	menu.renderFlowchart(graph, {})
end)
menu.closed, menu.mode, menu.scanDone, menu.refreshState = false, 'chain', true, nil
menu.managementMode, menu.refresh, menu.nameEntry, menu.statusKey = nil, nil, nil, nil
local function tick()
	menu.nextSlowUpdate = nil
	menu.onUpdate()
end
local function openNode(kind, id)
	local data = kind == 'station' and graph.stationNodes[id] or graph.wareNodes[id]
	menu.expandedNode = data[1].node
	menu.expandedMenuFrame = {}
	menu.expandedChain = selected
end

-- Status strip redraw: the same station popup reopens once its widget exists.
menu.display(false, 'open')
openNode('station', 'consumer')
menu.statusKey = 'text_error:Chain structure changed.'
menu.display(true, 'status strip changed')
assert(menu.expandedNode == nil and menu.restoreNode and menu.restoreNodeKey == 'station:consumer')
tick()
assert(expands == 0, 'no expansion before the native widget has an id')
menu.restoreNode.id = 42
tick()
assert(expands == 1 and menu.expandedNode.customdata.nodedata.scvid == 'consumer')
assert(menu.restoreNode == nil and menu.restoreNodeKey == nil)
assert(logs[#logs]:find('redraw: status strip changed; reopening station:consumer; status: text_error:Chain structure changed.', 1, true),
	logs[#logs])

-- A rebuilt graph (role change) restores by identity, not by table: ware nodes too.
openNode('ware', 'ore')
graph = graphOf()
menu.display(false, 'role change')
assert(menu.restoreNode and menu.restoreNode.customdata.nodedata == graph.wareNodes.ore)
menu.restoreNode.id = 7
tick()
assert(expands == 2 and menu.expandedNode.customdata.nodedata.scvware == 'ore')

-- A scan placeholder keeps the request pending for the real chart.
openNode('station', 'supplier')
drawGraph = false
menu.flowchart = nil
menu.display(false, 'queued refresh')
assert(menu.restoreNodeKey == 'station:supplier' and menu.restoreNode == nil)
drawGraph = true
menu.display(false, 'scan complete')
assert(menu.restoreNode and menu.restoreNode.customdata.nodedata.scvid == 'supplier')
menu.restoreNode.id = 9
tick()
assert(expands == 3)

-- Another chain, or a node that no longer exists, ends the restore without expanding.
openNode('station', 'supplier')
selected = chainB
menu.display(false, 'chain switch')
assert(menu.restoreNode == nil and menu.restoreNodeKey == nil)
selected = chainA
openNode('station', 'consumer')
graph = graphOf()
graph.stationNodes.consumer.scvid = 'gone'
menu.display(false, 'role change')
assert(menu.restoreNode == nil and menu.restoreNodeKey == nil)
tick()
assert(expands == 3)

-- An open management panel wins: restoring would close it.
graph = graphOf()
menu.display(false, 'open')
openNode('station', 'consumer')
menu.display(true, 'settings')
menu.managementMode = 'settings'
menu.restoreNode.id = 3
tick()
assert(expands == 3 and menu.restoreNode == nil)
menu.managementMode = nil

-- Closing the menu forgets any pending restore.
menu.restoreNode, menu.restoreNodeKey, menu.restoreChain = {}, 'station:x', chainA
local cleanupStubs = {}
for _, name in ipairs({'stopLogistics'}) do cleanupStubs[name] = SCV_Data[name] end
menu.cleanup()
assert(menu.restoreNode == nil and menu.restoreNodeKey == nil and menu.restoreChain == nil)

for i = #saved, 1, -1 do saved[i][1][saved[i][2]] = saved[i][3] end
menu.expandedNode, menu.expandedMenuFrame, menu.flowchart, menu.graph = nil, nil, nil, nil
print('Detail panel restore across redraws passed.')
