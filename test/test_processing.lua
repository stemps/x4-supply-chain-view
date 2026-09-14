-- Loaded by test_metrics.py. Fake the measured X4 contract: station aggregates
-- exclude processing; per-processor rates persist while waiting for resources.
local savedC = {}
for key, value in pairs(C) do savedC[key] = value end
local componentData, macroData, libraryEntry, wareData = GetComponentData, GetMacroData, GetLibraryEntry, GetWareData
local validComponent, construction, processingData = IsValidComponent, IsComponentConstruction, GetProcessingModuleData
local productionLimit = GetWareProductionLimit
local macroClass = IsMacroClass
local workforce = Helper.getWorkforceConsumption
local oldGraph, oldRevision = menu.graph, menu.metricRevision
local modules = {}
local function processor(id, feedstock)
	return { id = id, class = "processingmodule", feedstock = feedstock or "rawscrap",
		functional = true, state = "processing" }
end
local function reset()
	modules = { processor("p1"), processor("p2"), processor("k1", "rawkhaakscrap"),
		{ id = "recycler", class = "production", functional = true } }
end
reset()
local function find(id)
	for _, module in ipairs(modules) do if module.id == id then return module end end
end
function C.GetNumStationModules() return #modules end
function C.GetStationModules(buf)
	for i, module in ipairs(modules) do buf[i - 1] = module.id end
	return #modules
end
function C.IsRealComponentClass(id, class) return find(id).class == class end
function C.IsComponentOperational(id)
	local m = find(id)
	return m.functional and not m.construction and not m.paused and not m.hacked
end
function C.IsInfoUnlockedForPlayer(id, key)
	local m = find(id)
	return not (m and m.locked) and not (key == "storage_amounts" and modules.stockLocked)
end
function IsValidComponent(id)
	if id == "yard" then return true end
	local module = find(id)
	return module ~= nil and not module.invalid
end
function IsComponentConstruction(id) return find(id).construction or false end
function GetComponentData(id, ...)
	local m = find(id)
	if m then
		local result = {}
		for _, key in ipairs({...}) do
			local v
			if key == "macro" then v = id
			elseif key == "isfunctional" then v = m.functional
			elseif key == "ishacked" then v = m.hacked or false
			elseif key == "ispausedmanually" then v = m.paused or false end
			result[#result + 1] = v
		end
		return table.unpack(result)
	end
	local key = ...
	if key == "availableproducts" then return modules.productWares or { "scrapmetal" } end
	if key == "pureresources" then return { "energycells", "rawscrap", "rawkhaakscrap" } end
	if key == "tradewares" or key == "intermediatewares" then return {} end
	if key == "cargo" then return { energycells = 150, rawscrap = 0, rawkhaakscrap = 20, scrapmetal = 100 } end
	if key == "resourcebuffer" then
		if modules.bufferMissing then return nil end
		return { rawscrap = modules.bufferStock or 50, rawkhaakscrap = 25 }
	end
	return componentData(id, key)
end
function GetWareProductionLimit(_, ware)
	if ware == "rawscrap" then return 1000 end
	if ware == "rawkhaakscrap" then return 200 end
	return 200000
end
function C.GetNumContainerWareReservations2()
	if modules.reservationsMissing then error("reservations unavailable") end
	return 2
end
function C.GetContainerWareReservations2(buf)
	buf[0] = {ware = "rawscrap", amount = 75, isbuyreservation = false, tradedealid = 10}
	buf[1] = {ware = "rawscrap", amount = 999, isbuyreservation = true, tradedealid = 11}
	return 2
end
function GetMacroData(id) return "module" end
function IsMacroClass(id, class) return find(id).class == class end
function GetLibraryEntry(_, id)
	local m = find(id)
	if m.class == "production" then
		-- Classification reads unfinished recipes; effective rate queries still exclude them.
		if modules.productWares then
			local products = {}
			for _, ware in ipairs(modules.productWares) do
				products[#products + 1] = { ware = ware, amount = 10, cycle = 60,
					resources = { { ware = "energycells", amount = 10 } } }
			end
			return { products = products }
		end
		return { products = { { ware = "hullparts", amount = 10, cycle = 60,
			resources = { { ware = "energycells", amount = 10 } } } } }
	end
	-- Deliberately no cycle: ordinary moduleRates must NOT classify this module.
	return { products = { { ware = m.feedstock == "rawscrap" and "scrapmetal" or "khaakscrapmetal",
		amount = 100, resources = { { ware = m.feedstock, amount = 100 }, { ware = "energycells", amount = 1000 } } } } }
end
function GetProcessingModuleData(id)
	local m = find(id)
	assert(not m.construction and not m.invalid and m.functional, "must not query unfinished/unavailable modules")
	if m.fail then error("processing read failed") end
	return { state = m.state, products = { { ware = m.feedstock == "rawscrap" and "scrapmetal" or "khaakscrapmetal", amountperhour = 100 } },
		resources = { { ware = m.feedstock, amountperhour = m.zeroRate and 0 or 100 },
			{ ware = "energycells", amountperhour = m.invalidRate and 0/0 or 1000 } } }
end
function GetWareData(ware, key)
	if key == "isprocessed" then return ware == "rawscrap" or ware == "rawkhaakscrap" end
	return wareData(ware, key)
end
function Helper.getWorkforceConsumption(_, ware) return ware == "energycells" and 10 or 0 end
function C.GetNumContainerBuildResources() return modules.build and 1 or 0 end
function C.GetContainerWareConsumption(_, ware, maximum)
	assert(maximum == true)
	if modules.invalidRate then return 0/0 end
	local sum = 0
	for _, m in ipairs(modules) do
		if m.functional and not m.construction and m.class == "production" then
			if ware == "energycells" then sum = sum + 600 end
		end
	end
	return sum
end
function C.GetContainerWareProduction(_, ware, maximum)
	assert(maximum == true)
	for _, product in ipairs(modules.productWares or {}) do
		if ware == product then return 600 end -- completed recycler's effective maximum
	end
	return 0 -- measured native API does not include processor output either
end
local function read()
	return SCV_Data.readStation({ id = "yard", id64 = "yard", name = "Yard" })
end
local st = read()
local raw = st.wares.rawscrap
assert(raw.stock == 50 and raw.consKnown and raw.consMax == 200)
assert(raw.processor == nil and raw.displayKind == nil and raw.incomingBatches == nil)
local supply = SCV_Graph.reservationBar(raw)
assert(supply.start == 50 and supply.max == 1000)
assert(SCV_Graph.detailMetrics(raw, true).stockHours == 0.25)
assert(SCV_Graph.detailMetrics(raw, true).capacityHours == 5)
assert(st.wares.rawkhaakscrap.stock == 25 and st.wares.rawkhaakscrap.consMax == 100)
assert(st.wares.energycells.consKnown and st.wares.energycells.consMax == 3610)
assert(st.wares.energycells.consumptionParts.processing == 3000)
assert(st.wares.energycells.consumptionParts.production == 600)
assert(st.wares.energycells.consumptionParts.workforce == 10)
assert(SCV_Graph.detailMetrics(st.wares.energycells, true).stockHours == 150 / 3610)
assert(st.wares.scrapmetal.prodMax == 200 and st.wares.scrapmetal.prodKnown)
assert(SCV_Graph.detailMetrics(st.wares.scrapmetal, false).capacityHours ~= nil)
for _, status in ipairs({ "waitingforresources", "waitingforstorage", "waiting", "processing" }) do
    modules[1].state = status
    st = read()
    assert(st.wares.energycells.consMax == 3610 and st.wares.energycells.consKnown)
    assert(st.wares.rawscrap.consMax == 200 and st.wares.rawscrap.consKnown)
end
modules[1].paused, modules[2].hacked = true, true
assert(read().wares.energycells.consMax == 3610)
reset()
modules[1].functional, modules[2].construction = false, true
st = read()
assert(st.wares.energycells.consKnown and st.wares.energycells.consMax == 1610)
assert(st.wares.rawscrap.consKnown and st.wares.rawscrap.consMax == 0)
modules[2].locked = true
assert(read().wares.energycells.consKnown, "unfinished modules must not hide completed capacity")
reset()
modules[1].invalid = true
assert(read().wares.energycells.consMax == 2610)
reset()
-- An unfinished ordinary recycler cannot hide the completed recycler/processor sum.
modules[#modules + 1] = { id = "unfinished-recycler", class = "production", functional = false,
	construction = true, locked = true }
st = read()
assert(st.wares.energycells.consKnown and st.wares.energycells.consMax == 3610)
assert(st.wares.rawscrap.consKnown and st.wares.rawscrap.consMax == 200)
assert(st.wares.scrapmetal.prodKnown and st.wares.scrapmetal.prodMax == 200)
for _, products in ipairs({ { "hullparts", "claytronics" }, { "computronicsubstrate", "siliconcarbide" } }) do
	modules.productWares = products
	st = read()
	assert(st.wares.energycells.consKnown and st.wares.energycells.consMax == 3610)
	for _, ware in ipairs(products) do
		assert(st.wares[ware].prodKnown and st.wares[ware].prodMax == 600,
			"unfinished recycler must preserve completed output: " .. ware)
	end
end
reset()
modules[1].locked = true
assert(not read().wares.rawscrap.consKnown and not read().wares.energycells.consKnown)
reset()
modules[1].fail = true
assert(not read().wares.rawscrap.consKnown and not read().wares.energycells.consKnown)
reset()
modules[1].invalidRate = true
assert(not read().wares.energycells.consKnown and read().wares.rawscrap.consKnown)
reset()
modules[1].zeroRate = true
assert(not read().wares.rawscrap.consKnown)
reset()
modules.bufferMissing = true
assert(not read().wares.rawscrap.stockKnown)
assert(SCV_Graph.detailMetrics(read().wares.rawscrap, true).stockHours == nil)
reset()
modules.stockLocked = true
assert(not SCV_Graph.wareHealth(read().wares.rawscrap).known)
reset()
modules.bufferStock = 0
assert(SCV_Graph.wareHealth(read().wares.rawscrap).severity == "critical")
reset()
modules.build = true
assert(not read().wares.energycells.consKnown, "shipbuilding demand must stay unknown")
reset()
modules = { processor("only") }
assert(read().wares.energycells.consMax == 1010, "processor-only demand must be inventoried")
reset()

-- Standard storage presentation in both popups, with live buffer/rate refresh.
st = read()
local source = { id = "source", name = "Source", wares = { rawscrap = {
    name = "rawscrap", output = true, stock = 0, prodKnown = false } } }
local graph = SCV_Graph.build({ st, source })
menu.graph, menu.metricRevision = graph, 1000
local a, b = tableMock(), tableMock()
local frame = { properties = { height = 600 } }
menu.expandStation(nil, frame, a, graph.stationNodes.yard)
menu.expandWare(nil, frame, b, graph.wareNodes.rawscrap)
local function row(t, key)
    for i, r in ipairs(t.rows) do if r.key == key then return i end end
    error("missing row " .. key)
end
local i, j = row(a, "ware:rawscrap"), row(b, "station:yard")
assert(a.rows[i+1][1].bar.start == 50 and a.rows[i+1][1].bar.max == 1000)
assert(a.rows[i+2][2].text == "-200/h")
assert(a.rows[i+3][1].text == b.rows[j+3][1].text)
assert(string.find(a.rows[i+3][1].text, "15m", 1, true))
assert(a.rows[i+4][1].props.height == 2)
local energyRow = row(a, "ware:energycells")
assert(string.find(a.rows[energyRow+3][1].props.mouseOverText, "Continuous scrap supply", 1, true))
assert(not string.find(a.rows[energyRow+3][1].props.mouseOverText, "Scrap processing:", 1, true))
assert(string.find(a.rows[energyRow+2][2].props.mouseOverText, "Scrap processing: 3.0k/h", 1, true))
assert(string.find(a.rows[energyRow+2][2].props.mouseOverText, "Other production: 600/h", 1, true))
local record, nodes, edges, rowCount = graph.stationNodes.yard.wares.rawscrap, graph.nodes, graph.edges, #a.rows
local function refresh(station)
    SCV_Graph.refreshMetrics(graph, { station, source })
    menu.metricRevision = menu.metricRevision + 1
    for _, t in ipairs({a,b}) do for _, r in ipairs(t.rows) do for col=1,2 do r[col]:update() end end end
    assert(graph.nodes == nodes and graph.edges == edges and #a.rows == rowCount)
    assert(graph.stationNodes.yard.wares.rawscrap == record)
end
modules[1].state = "waitingforresources"
modules.bufferStock = 90
refresh(read())
assert(a.rows[i+1][1].bar.start == 90)
assert(a.rows[i+2][2].text == "-200/h")
assert(string.find(a.rows[i+3][1].text, "27m", 1, true))
refresh({ id = "yard", failed = true })
assert(a.rows[i+1][1].bar.start == 0)
assert(not record.stockKnown and not record.consKnown)
assert(string.find(a.rows[i+3][1].text, "?", 1, true))
refresh(read())
assert(a.rows[i+1][1].bar.start == 90 and not graph.refreshFailed)

for key in pairs(C) do C[key] = nil end
for key, value in pairs(savedC) do C[key] = value end
GetComponentData, GetMacroData, GetLibraryEntry, GetWareData = componentData, macroData, libraryEntry, wareData
GetWareProductionLimit = productionLimit
IsMacroClass = macroClass
IsValidComponent, IsComponentConstruction, GetProcessingModuleData = validComponent, construction, processingData
Helper.getWorkforceConsumption = workforce
menu.graph, menu.metricRevision = oldGraph, oldRevision
