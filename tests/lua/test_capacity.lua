-- Known-zero storage contracts, using the existing fake engine and popup widgets.
local oldCount, oldRead = C.GetNumCargoTransportTypes, C.GetCargoTransportTypes
local oldInfo, oldWare, oldLimit = C.IsInfoUnlockedForPlayer, GetWareData, GetWareProductionLimit
local entries, failCount, failRead, shortRead, locked, metadata = {}, false, false, false, false, false
function C.GetNumCargoTransportTypes()
    if failCount then error('storage count failed') end
    return #entries
end
function C.GetCargoTransportTypes(buf, count)
    if failRead then error('storage read failed') end
    for i, item in ipairs(entries) do buf[i-1] = item end
    return shortRead and 0 or count
end
function C.IsInfoUnlockedForPlayer(id, key)
    if key == 'storage_capacity' then return not locked end
    return oldInfo(id, key)
end
function GetWareProductionLimit() return 0 end
function GetWareData(ware, key)
    if key == metadata then return nil end
    if key == 'transport' then return 'liquid' end
    if key == 'volume' then return 2 end
    return oldWare(ware, key)
end
local function readWare()
    return SCV_Data.readStation({id='capacity', id64='capacity', name='Capacity'}).wares.energycells
end
local function unknown()
    local w = readWare()
    assert(not w.capacityUnitsKnown)
    assert(not SCV_Graph.reservationBar(w).capacityKnown)
end
local w = readWare()
assert(w.capacityUnitsKnown and w.capacityUnits == 0 and w.limitKnown)
entries = {{transport='container', capacity=100}}
assert(readWare().capacityUnitsKnown and readWare().capacityUnits == 0)
entries = {{transport='liquid', capacity=0}}
assert(readWare().capacityUnitsKnown and readWare().capacityUnits == 0)
entries = {{transport='container solid liquid liquid', capacity=400}, {transport='liquid', capacity=200}}
w = readWare()
assert(w.capacityUnitsKnown and w.capacityUnits == 300, 'universal and dedicated capacity counted once')
local assigned = SCV_Graph.reservationBar(w)
assert(assigned.capacityKnown and assigned.capacity == 0 and not assigned.estimated)
-- Leftover stock remains counted without inventing assigned storage for it.
w.stock, w.stockKnown = 75, true
local totals = SCV_Graph.storageTotals({hub={wares={energycells=w}}}, 'energycells', {'hub'}, {})
assert(totals.stock == 75 and totals.capacity == 0 and totals.capacityKnown and not totals.estimated)
-- An unfinished station with no stock also contributes zero assigned storage.
w.stock = 0
assert(SCV_Graph.reservationBar(w).capacity == 0)
GetWareProductionLimit = function() return 50 end
assert(SCV_Graph.reservationBar(readWare()).capacity == 50, 'allocation takes precedence')
GetWareProductionLimit = function() return nil end
failCount = true; unknown(); failCount = false
failRead = true; unknown(); failRead = false
shortRead = true; unknown(); shortRead = false
locked = true; unknown(); locked = false
metadata = 'transport'; unknown()
metadata = 'volume'; unknown(); metadata = false
entries = {{transport='liquid', capacity=-1}}; unknown()
entries = {{transport='', capacity=200}}; unknown()
entries = {{transport='liquid', capacity=0/0}}; unknown()
C.GetNumCargoTransportTypes, C.GetCargoTransportTypes = oldCount, oldRead
C.IsInfoUnlockedForPlayer, GetWareData, GetWareProductionLimit = oldInfo, oldWare, oldLimit

local zero = {name='Helium', output=true, stock=0, limit=0, capacityUnits=0,
    capacityUnitsKnown=true, prodMax=100, prodKnown=true, incoming=50}
local b = SCV_Graph.reservationBar(zero)
assert(b.capacityKnown and b.capacity == 0 and not b.unknown and not b.estimated)
assert(b.max == 1 and b.drawStart == 0 and b.drawCurrent == 0)
assert(b.percent == nil and b.futurePercent == nil)
local m = SCV_Graph.detailMetrics(zero, false)
assert(m.fillHours == nil and m.capacityHours == nil)
zero.capacityUnitsKnown = nil
assert(SCV_Graph.reservationBar(zero).unknown, 'legacy zero must remain unknown')
zero.capacityUnits = 300
assert(SCV_Graph.reservationBar(zero).capacityKnown, 'legacy positive remains supported')
zero.capacityUnitsKnown = false
assert(SCV_Graph.reservationBar(zero).unknown, 'explicit failure overrides stale fallback')
zero.capacityUnitsKnown, zero.capacityUnits = true, 0

local hub = {id='hub', name='Unfinished Hub', wares={helium=zero}}
local factory = {id='factory', name='Factory', wares={helium={name='Helium', input=true,
    stock=514200, limit=666700, consMax=100, consKnown=true}}}
local graph = SCV_Graph.build({hub, factory})
local node = graph.wareNodes.helium
menu.graph = graph
menu.decorateNodes(graph)
assert(node.storage.capacityKnown and node.storage.capacity == 666700)
assert(node[1].properties.value == 514200 and node[1].properties.max == 666700)
local dedup = SCV_Graph.storageTotals(graph.stationNodes, 'helium', {'hub','factory'}, {'factory','hub'})
assert(dedup.capacity == 666700 and dedup.stock == 514200 and dedup.capacityKnown)
local popup = tableMock()
menu.expandWare(nil, {properties={height=600}}, popup, node)
assert(popup.rows[2][1].text == 'Amount 514.2k / 666.7k')
for i, row in ipairs(popup.rows) do
    if row.key == 'station:hub' then
        assert(popup.rows[i+2][1].text == 'Amount 0 / 0')
        local tip = popup.rows[i+2][1].props.mouseOverText
        assert(string.find(tip, 'Stock: 0 / 0', 1, true))
        assert(not string.find(tip, 'unknown', 1, true))
        assert(not string.find(tip, 'Estimated', 1, true))
        assert(not string.find(popup.rows[i+3][1].props.mouseOverText, 'Storage capacity unknown', 1, true))
    end
end
factory.wares.helium.stock, factory.wares.helium.limit = 0, 0
factory.wares.helium.capacityUnits, factory.wares.helium.capacityUnitsKnown = 0, true
graph = SCV_Graph.build({hub, factory})
menu.graph = graph
menu.decorateNodes(graph)
node = graph.wareNodes.helium
assert(node.storage.capacityKnown and node.storage.stockKnown and node.storage.capacity == 0)
assert(node[1].properties.value == 0 and node[1].properties.max == 1)
assert(string.find(node[1].properties.mouseOverText, 'Stock: 0 / 0', 1, true))
assert(not string.find(node[1].properties.mouseOverText, 'Incomplete', 1, true))
factory.wares.helium.stockKnown = false
graph = SCV_Graph.build({hub, factory})
assert(not graph.wareNodes.helium.storage.stockKnown, 'zero capacity must not imply known stock')
print('PASS known-zero reader, aggregation, transport and popup contracts')
