-- Use the real store, graph, popup renderers and toggle handler with fake widgets.
local oldScaleY = Helper.scaleY
Helper.scaleY = Helper.scaleY or function(x) return x end
local function input(stock)
    return {name='Ore', input=true, stock=stock, limit=1000, consMax=100,
        consKnown=true, incoming=0, outgoing=0}
end
local function world()
    return {
        {id='supplier', code='SUP-001', name='Supplier', wares={ore={name='Ore', output=true,
            stock=500, limit=1000, prodMax=100, prodKnown=true}}},
        {id='consumer', code='CON-001', name='Consumer', wares={ore=input(0), food=input(1)}},
        {id='other', code='OTH-001', name='Other', wares={ore=input(0)}},
    }
end
local policy = {isWarningIgnored=SCV_Store.isWarningIgnored}
local graph = SCV_Graph.build(world(), policy)
local consumer = graph.stationNodes.consumer
assert(consumer.severity == 'critical')
local originalDemand, originalStock = graph.wareNodes.ore.demandCap, graph.wareNodes.ore.storage.stock
menu.graph = graph
local panel, frame = tableMock(), {properties={height=600}}
menu.expandStation(nil, frame, panel, consumer)
local function find(t, key)
    for _, row in ipairs(t.rows) do if row.key == key then return row end end
    error('missing row '..key)
end
local toggle = find(panel, 'ware:ore')[4]
assert(toggle.checkbox and toggle.checked())
assert(find(panel, 'ware:ore')[1].bgspan == 4, 'name row must have no vertical dividers')
assert(find(panel, 'ware:ore')[1].span == 2)
local bell = find(panel, 'ware:ore')[3]
assert(bell.icon == 'terraforming_xen_alert' and bell.iconProps.color() == Color.text_normal)
assert(toggle.checkbox.scaling == false and toggle.checkbox.width == Helper.scaleY(Helper.standardTextHeight))
assert(toggle.checkbox.mouseOverText():find('enabled'))
local oldFrame, oldExpanded = menu.frame, menu.expandedMenuFrame
local updates = 0
menu.frame = {update=function() updates=updates+1 end}
menu.expandedMenuFrame = {update=function()
    for _, row in ipairs(panel.rows) do for i=1,4 do row[i]:update() end end
    updates=updates+1
end}
local revision = menu.metricRevision or 0
toggle.handlers.onClick(nil, false)
assert(menu.graph == graph and menu.metricRevision == revision+1 and updates == 2)
assert(not toggle.checked() and toggle.checkbox.mouseOverText():find('ignored'))
assert(bell.iconProps.color() == Color.text_inactive)
assert(consumer.wares.ore.health.severity == 'ok' and consumer.wares.ore.health.cover == 0)
assert(consumer.severity == 'critical' and consumer.worstWare == 'food')
assert(graph.stationNodes.other.severity == 'critical')
assert(graph.wareNodes.ore.demandCap == originalDemand and graph.wareNodes.ore.storage.stock == originalStock)
find(panel, 'ware:food')[4].handlers.onClick(nil, false)
assert(consumer.severity == 'ok' and consumer.worstWare == nil)
local warePanel = tableMock()
menu.expandWare(nil, frame, warePanel, graph.wareNodes.ore)
local consumerToggle = find(warePanel, 'station:consumer')[4]
assert(consumerToggle.checkbox and not consumerToggle.checked())
assert(not find(warePanel, 'station:supplier')[4].checkbox)
SCV_Graph.refreshMetrics(graph, world())
assert(consumer.wares.ore.warningIgnored and consumer.severity == 'ok')
assert(graph.wareNodes.ore.demandCap == originalDemand and graph.wareNodes.ore.storage.stock == originalStock)
SCV_Graph.refreshMetrics(graph, {{id='consumer', failed=true}})
assert(consumer.wares.ore.warningIgnored and not consumer.wares.ore.health.known)
SCV_Graph.refreshMetrics(graph, world())
assert(consumer.wares.ore.warningIgnored and consumer.wares.ore.health.cover == 0)
-- A second chain receives exactly the same station policy.
assert(SCV_Graph.build(world(), policy).stationNodes.consumer.severity == 'ok')
consumerToggle.handlers.onClick(nil, true)
assert(consumer.severity == 'critical' and consumer.worstWare == 'ore')
assert(toggle.checked() and not SCV_Store.isWarningIgnored('CON-001', 'ore'))
menu.frame, menu.expandedMenuFrame = oldFrame, oldExpanded
Helper.scaleY = oldScaleY
print('Warning policy, popup controls, live updates and refresh contracts passed.')
