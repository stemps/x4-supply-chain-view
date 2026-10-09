-- Player-chosen consumer role: the real store, graph, station popup and radio handlers.
local function T(id) return ReadText(77001, id) end
local oldDisplay, oldGraph = menu.display, menu.graph
local oldScaleY = Helper.scaleY
Helper.scaleY = Helper.scaleY or function(x) return x end
local function world()
    return {
        {id='p', code='PRD-001', name='Producer', wares={energycells={name='Energy', output=true,
            stock=100, limit=1000, prodMax=50, prodKnown=true}}},
        {id='w', code='WAR-001', name='Warehouse', wares={
            energycells={name='Energy', output=true, dualTrade=true, stock=500, limit=5000, incoming=0, outgoing=0},
            ore={name='Ore', output=true, dualTrade=true, stock=10, limit=100, incoming=0, outgoing=0},
            silicon={name='Silicon', output=true, stock=10, limit=100, incoming=0, outgoing=0}}},
        {id='n', code='', name='No code', wares={energycells={name='Energy', output=true,
            dualTrade=true, stock=0, limit=0}}},
    }
end
-- Roles belong to the selected chain; a second chain holds the same station untouched.
local other = SCV_Store.create('Roles other', {{id='w', code='WAR-001'}})
local chainIdx = SCV_Store.create('Roles', {{id='w', code='WAR-001'}})
local oldSelected = select(2, SCV_Store.selected())
SCV_Store.select(chainIdx)
local function isConsumer(ware) return SCV_Store.isConsumerRole(chainIdx, 'WAR-001', ware) end
local policy = {isConsumerRole=SCV_Store.consumerRolePolicy(chainIdx)}
local frame = barFrame(600, 400)
local size = Helper.scaleY(Helper.standardTextHeight)
local function find(t, key)
    for _, row in ipairs(t.rows) do if row.key == key then return row end end
    error('missing row '..key)
end
local function radios(t)
    local out = {}
    for _, row in ipairs(t.rows) do
        if row[5].buttonIcon == 'menu_export' and row[6].buttonIcon == 'menu_import' then out[#out+1] = row end
    end
    return out
end
local function popup(graph, id)
    local panel = tableMock()
    menu.graph = graph
    frame.bar = nil
    menu.expandStation(nil, frame, panel, graph.stationNodes[id])
    return panel
end
-- The station-wide radio sits in the toolbar, right before Remove.
local function stationRadio(graph, id)
    popup(graph, id)
    local row = frame.bar.rows[1]
    local n = frame.bar.columns
    if row[n - 2].buttonIcon == 'menu_export' and row[n - 1].buttonIcon == 'menu_import' then
        return { row[n - 2], row[n - 1], columns = n }
    end
end
-- Selected: vanilla's mode-selector background and normal icon colour, no click handler.
local function selected(cell)
    return cell.button.bgColor == Color.row_background_selected
        and cell.buttonIconProps.color == Color.text_normal and cell.handlers.onClick == nil
end
local function unselected(cell)
    return cell.button.bgColor == Color.button_background_default
        and cell.buttonIconProps.color == Color.text_inactive and cell.handlers.onClick ~= nil
end
local displays = 0
menu.display = function() displays = displays + 1 end

-- Default: a producer row shows the radio in the last two columns, producer selected.
local graph = SCV_Graph.build(world(), policy)
local panel = popup(graph, 'w')
local entry = find(panel, 'ware:energycells')
assert(entry[1].span == 4, 'an output row has no bell; the name runs up to the radio')
assert(selected(entry[5]) and unselected(entry[6]))
assert(entry[5].button.mouseOverText == T(3197) .. '\n\n' .. T(3203)
    and entry[6].button.mouseOverText == T(3198) .. '\n\n' .. T(3204))
assert(entry[5].button.scaling == false and entry[5].button.width == size and entry[5].button.height == size)
assert(entry[6].button.x == 160 - size, 'right-aligned in its column')
assert(find(panel, 'ware:silicon')[1].span == 6 and not find(panel, 'ware:silicon')[5].button,
    'a ware that is not bought and sold has no radio')

-- The station radio is in the toolbar, all producers; the panel keeps only ware radios.
assert(#radios(panel) == 2, 'two ware radios in the panel, got '..#radios(panel))
local station = stationRadio(graph, 'w')
assert(station and station.columns == 8, 'five actions, the radio pair and Remove')
assert(selected(station[1]) and unselected(station[2]))
assert(station[1].button.mouseOverText == T(3197) .. '\n\n' .. T(3200)
    and station[2].button.mouseOverText == T(3198) .. '\n\n' .. T(3201))
assert(station[1].button.width == station[1].button.height and station[1].button.width <= 38)
assert(not stationRadio(graph, 'p') and not stationRadio(graph, 'n'),
    'no radio without a bought-and-sold ware or without a station code')
assert(frame.bar.columns == 6)

-- Choosing consumer on one ware stores one choice and rebuilds.
entry[6].handlers.onClick()
assert(displays == 1 and isConsumer('energycells') and not isConsumer('ore'))
assert(not SCV_Store.isConsumerRole(other, 'WAR-001', 'energycells'), 'other chain keeps its own role')
graph = SCV_Graph.build(world(), policy)
assert(graph.wareNodes.energycells.consumers[1] == 'w')

-- As an input: name, warning bell + checkbox, then the radio with consumer selected.
panel = popup(graph, 'w')
entry = find(panel, 'ware:energycells')
assert(entry[1].span == 2, 'the name yields to the bell and the radio')
assert(entry[3].icon == 'terraforming_xen_alert' and entry[4].checkbox, 'alert toggle first')
assert(unselected(entry[5]) and selected(entry[6]), 'radio after the alert toggle')

-- Mixed: the station radio selects neither and says so; consumer makes them all consumers.
station = stationRadio(graph, 'w')
assert(unselected(station[1]) and unselected(station[2]))
assert(station[1].button.mouseOverText == T(3197) .. '\n\n' .. T(3200) .. '\n' .. T(3202)
    and station[2].button.mouseOverText == T(3198) .. '\n\n' .. T(3201) .. '\n' .. T(3202))
station[2].handlers.onClick()
assert(displays == 2 and isConsumer('energycells') and isConsumer('ore') and not isConsumer('silicon'))
assert(not SCV_Store.isConsumerRole(other, 'WAR-001', 'ore'), 'station radio stays in its chain')
graph = SCV_Graph.build(world(), policy)
station = stationRadio(graph, 'w')
assert(unselected(station[1]) and selected(station[2]))
station[1].handlers.onClick()
assert(displays == 3 and not isConsumer('energycells') and not isConsumer('ore'))

-- Workforce use lists a producer in both sections; its radio appears only once.
local staffed = world()
staffed[2].wares.energycells.metricInput = true
panel = popup(SCV_Graph.build(staffed, policy), 'w')
assert(#radios(panel) == 2, 'ware radio duplicated across sections')

menu.display, menu.graph = oldDisplay, oldGraph
SCV_Store.delete(chainIdx)
SCV_Store.delete(other)
SCV_Store.select(oldSelected)
Helper.scaleY = oldScaleY
print('Consumer role radios, station radio, persistence and rebuild contracts passed.')
