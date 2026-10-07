-- Loaded by test_metrics.py. Optional Civilian Economy demand: a CE hub buys through
-- virtual offers into an MD reserve, published through the CEHubStatus global.
local oldModules, oldWorkforce, oldCargo = state.modules, state.workforce, state.cargo
local oldGraph, oldRevision = menu.graph, menu.metricRevision
local function read()
	return SCV_Data.readStation({ id = "hub", id64 = "hub", name = "Hub" })
end
local function hub(available, wares)
	return { available = available, active = true, level = 3, wares = wares }
end
local snapshot
local function install()
	CEHubStatus = { get = function (id)
		assert(id == "hub")
		return snapshot
	end }
end

-- CE absent: the record is exactly what the reader produced before.
CEHubStatus = nil
local plain = read()
assert(plain.wares.water == nil and plain.wares.food.consMax == 100)
assert(plain.wares.food.civilianDemand == nil and plain.wares.food.consumptionParts == nil)

-- A hub without modules: every unlocked CE ware is an input with the CE rate.
install()
state.modules, state.workforce, state.cargo = false, 0, {}
snapshot = hub(true, {
	{ key = "water", name = "Water", rate = 400, reserve = 300, capacity = 800, incoming = 50 },
	{ key = "medicalsupplies", name = "Medical Supplies", rate = 0, reserve = 0, capacity = 0, incoming = 0 },
	{ key = "energycells", name = "Energy Cells", rate = 1000, reserve = 0, capacity = 2000, incoming = 0 },
})
local st = read()
local water = st.wares.water
assert(water and water.input and not water.output and water.metricInput)
assert(water.consKnown and water.consMax == 400 and water.civilianDemand == 400)
assert(water.consumptionParts.civilian == 400 and water.consumptionParts.total == 400)
assert(water.stockKnown and water.stock == 300 and water.limitKnown and water.limit == 800)
assert(water.inputProvenance == "other")
assert(st.wares.medicalsupplies == nil, "locked CE wares are not demand")
-- Output-wins must not keep a demanded ware as an output.
local cells = st.wares.energycells
assert(cells.input and not cells.output and cells.consMax == 1000 and cells.stock == 0)
assert(SCV_Graph.wareHealth(cells).severity == "critical")
-- Engine reservations take precedence; CE's own count fills in when they show nothing.
assert(cells.incoming == state.incoming and water.incoming == 50)

-- Workforce and CE demand on one ware: each counted once.
state.modules, state.workforce = true, 100
snapshot = hub(true, { { key = "food", name = "Food", rate = 250, reserve = 10, capacity = 500, incoming = 0 } })
local food = read().wares.food
assert(food.consKnown and food.consMax == 100 + 250)
assert(food.consumptionParts.workforce == 100 and food.consumptionParts.civilian == 250)

-- An unavailable snapshot keeps the role but not the numbers.
state.modules, state.workforce = false, 0
snapshot = hub(false, { { key = "water", name = "Water", rate = 400, reserve = 300, capacity = 800, incoming = 0 } })
water = read().wares.water
assert(water.input and not water.consKnown and not water.stockKnown and not water.limitKnown)

-- A CE failure never breaks the station read.
CEHubStatus = { get = function () error("snapshot decode failed") end }
st = read()
assert(st.wares.water == nil and st.wares.food)

-- A producer of the demanded ware links to the hub, and the hub counts toward demand.
install()
snapshot = hub(true, { { key = "water", name = "Water", rate = 400, reserve = 300, capacity = 800, incoming = 0 } })
st = read()
local source = { id = "source", name = "Source", wares = { water = {
	name = "Water", output = true, metricOutput = true, stock = 0, prodMax = 1000, prodKnown = true } } }
local graph = SCV_Graph.build({ st, source })
local node = graph.wareNodes.water
assert(node and node.demandCap == 400 and node.supplyCap == 1000)

-- The rate tooltip names the civilian share.
menu.graph, menu.metricRevision = graph, 2000
local t = tableMock()
menu.expandStation(nil, { properties = { height = 600 } }, t, graph.stationNodes.hub)
local found
for i, r in ipairs(t.rows) do
	if r.key == "ware:water" then found = t.rows[i + 2][2].props.mouseOverText end
end
assert(found and string.find(found, "Civilian demand: 400/h", 1, true), tostring(found))

-- Scan gating: an unscanned hub whose wares all come from CE has nothing to hide.
local componentData, oldStock = GetComponentData, state.stockKnown
state.stockKnown = false
assert(read().locked, "a hub still showing engine-read wares stays locked")
GetComponentData = function (id, key)
	if key == "availableproducts" or key == "pureresources" or key == "tradewares" then return {} end
	return componentData(id, key)
end
st = read()
assert(st.wares.water and not st.locked, "CE-only hub must not raise the storage warning")
assert(st.wares.water.stockKnown and st.wares.water.stock == 300)
CEHubStatus = nil
assert(read().locked, "non-hub stations keep the scan warning")
GetComponentData, state.stockKnown = componentData, oldStock

CEHubStatus = nil
state.modules, state.workforce, state.cargo = oldModules, oldWorkforce, oldCargo
menu.graph, menu.metricRevision = oldGraph, oldRevision
