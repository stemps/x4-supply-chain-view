-- Isolated fake engine for classification versus operational metric contracts.
local plans, modules, logs, recipeReads = {}, {}, {}, {}
local recipes = {
	smelter = { products = {{ware="metals", amount=1, cycle=60, resources={{ware="ore", amount=1}}}} },
	consumer = { products = {{ware="widgets", amount=1, cycle=60,
		resources={{ware="metals", amount=1}, {ware="gas", amount=1}}}} },
	gasworks = { products = {{ware="gas", resources={{ware="ice"}}}} },
	processor = { products = {{ware="scrapmetal", resources={{ware="rawscrap"}, {ware="energycells"}}}} },
	yard = { buildresources = {{ware="metals"}, {ware="shipbits"}} },
}
local classes = { smelter="production", consumer="production", gasworks="production",
	processor="processingmodule", yard="buildmodule", storage="storage", dock="dockarea", broken="production" }
local failPlan = false
local products = {"metals"}
local inputs = {"ore"}
local function module(id)
	for _, m in ipairs(modules) do if m.id == id then return m end end
end
function DebugError(s) logs[#logs+1] = s end
function ConvertStringTo64Bit(id) return id end
function IsValidComponent() return true end
function IsComponentConstruction(id) return module(id).construction or false end
function IsMacroClass(macro, class) return classes[macro] == class end
function GetMacroData() return "module" end
function GetFactionData() return nil end
function GetLibraryEntry(_, macro)
	recipeReads[macro] = (recipeReads[macro] or 0) + 1
	return recipes[macro]
end
function GetComponentData(id, key)
	local m = module(id)
	if m then
		if key == "macro" then return m.macro end
		if key == "isfunctional" then return not m.construction end
		return false
	end
	if key == "availableproducts" then return products end
	if key == "pureresources" then return inputs end
	if key == "intermediatewares" or key == "tradewares" then return {} end
	if key == "cargo" then return {metals=40, ore=15, gas=7} end
	return key
end
function GetWareData(ware, key)
	if key == "volume" then return 1 end
	return key == "transport" and "container" or ware
end
function GetWareProductionLimit() return 100 end
Helper = {getWorkforceConsumption=function() return 0 end}
C = {}
function GetWorkForceRaceResources() return {} end
function C.GetWorkForceInfo() return {optimal=0,current=0,capacity=0} end
function C.GetNumStoredUnits() return 0 end
package.preload.ffi = function() return {C=C, new=function() return {} end, string=tostring} end
function C.IsComponentClass() return true end
function C.IsRealComponentClass(id, class) return classes[module(id).macro] == class end
function C.IsComponentOperational(id) return not module(id).construction end
function C.IsInfoUnlockedForPlayer() return true end
function C.GetNumStationModules() return #modules end
function C.GetStationModules(buf)
	for i,m in ipairs(modules) do buf[i-1] = m.id end
	return #modules
end
function C.GetNumPlannedStationModules(_, includeall)
	assert(includeall == false)
	if failPlan then error("plan unavailable") end
	return nativeCount and nativeCount(#plans) or #plans
end
function C.GetPlannedStationModules(buf, _, _, includeall)
	assert(includeall == false)
	for i,p in ipairs(plans) do buf[i-1] = p end
	return nativeCount and nativeCount(#plans) or #plans
end
function C.GetNumContainerBuildResources() return 0 end
function C.GetNumContainerWareReservations2() return 0 end
function C.GetNumCargoTransportTypes() return 1 end
function C.GetCargoTransportTypes(buf) buf[0]={transport="container",capacity=250}; return 1 end
function C.GetContainerWareProduction(_, ware) return ware == "metals" and 60 or 0 end
function C.GetContainerWareConsumption(_, ware) return ware == "ore" and 60 or 0 end
function GetStorageData() return 100 end

return function()
	local function read() return SCV_Data.readStation({id="A",id64="A",name="A"}) end
	local function plan(macro, id) return {componentid=id or 0, macroid=macro} end
	-- Reported station: infrastructure exists, but all production is still queued.
	modules = {{id="dock",macro="dock"}, {id="storage",macro="storage"},
		{id="expansion",macro="storage",construction=true}}
	products, inputs = {}, {}
	plans = {plan("storage", "expansion"), plan("smelter"), plan("consumer")}
	local queued = read()
	assert(#logs == 0, "queued plan read failed: " .. table.concat(logs, "; "))
	assert(queued.wares.ore and queued.wares.ore.input and queued.wares.gas.input)
	assert(not queued.wares.metals and queued.wares.widgets.output)
	assert(not queued.wares.widgets.prodKnown and queued.wares.widgets.prodMax == 0)
	assert(queued.wares.gas.consKnown and queued.wares.gas.consMax == 0)
	local readConsumption = C.GetContainerWareConsumption
	C.GetContainerWareConsumption = function() return nil end
	assert(not read().wares.gas.consKnown, "failed rate read must not become known zero")
	C.GetContainerWareConsumption = readConsumption
	local readModules = C.GetStationModules
	C.GetStationModules = function() return 0 end
	assert(not read().wares.gas.consKnown, "incomplete module inventory must remain unknown")
	C.GetStationModules = readModules
	assert(queued.wares.gas.stock == 7 and queued.wares.gas.capacityUnits == 250)
	local supplied = SCV_Graph.build({queued,
		{id="supplier",name="supplier",wares={gas={output=true,prodMax=100,prodKnown=true,stock=20}}}})
	assert(#supplied.wareNodes.gas.consumers == 1 and supplied.wareNodes.gas.demandCap == 0)
	assert(supplied.wareNodes.gas.demandKnown and supplied.wareNodes.gas.netKnown)
	assert(#supplied.wareNodes.widgets.producers == 1 and #supplied.wareNodes.widgets.consumers == 0,
		"future products create terminal output nodes")
	assert(supplied.wareNodes.widgets.supplyCap == 0 and not supplied.wareNodes.widgets.supplyKnown)
	local downstream = SCV_Graph.build({queued,
		{id="buyer",name="buyer",wares={widgets={input=true,consMax=20,consKnown=true,stock=0}}}})
	assert(#downstream.wareNodes.widgets.producers == 1 and #downstream.wareNodes.widgets.consumers == 1)
	assert(downstream.wareNodes.widgets.supplyCap == 0, "future supplier adds no projected production")
	products, inputs, plans = {"metals"}, {"ore"}, {}
	modules = {{id="built",macro="smelter"}}
	local baseline = read()
	assert(baseline.wares.metals.output and baseline.wares.metals.prodMax == 60)
	assert(baseline.wares.metals.capacityUnitsKnown and baseline.wares.metals.capacityUnits == 250)
	plans = {plan("consumer")}
	local st = read()
	assert(st.wares.metals == nil, "planned consumers suppress terminal intermediates")
	assert(st.wares.widgets.output, "planned producers create terminal outputs")
	assert(st.wares.gas.input and st.wares.gas.consKnown and st.wares.gas.consMax == 0)
	assert(st.wares.gas.stock == 7, "future inputs use actual cargo")
	for _, key in ipairs({"stock", "limit", "capacityUnits", "consMax", "consKnown"}) do
		assert(st.wares.ore[key] == baseline.wares.ore[key], "existing metric changed: " .. key)
	end
	local supplier = {id="B",name="B",wares={gas={output=true,prodMax=100,prodKnown=true,stock=20}}}
	local graph = SCV_Graph.build({st, supplier})
	assert(not graph.wareNodes.metals and graph.wareNodes.gas)
	assert(#graph.wareNodes.gas.consumers == 1 and graph.wareNodes.gas.demandCap == 0)

	plans = {plan("consumer"), plan("gasworks")}
	st = read()
	assert(not st.wares.gas and st.wares.ice.input, "whole plan determines internal supply")
	plans = {plan("consumer", "unfinished"), plan("consumer")}
	modules[2] = {id="unfinished",macro="consumer",construction=true}
	recipeReads = {}
	st = read()
	assert(not st.wares.metals and st.wares.gas.input and st.wares.widgets.output)
	assert(st.wares.widgets.prodMax == 0 and not st.wares.widgets.prodKnown)
	assert(recipeReads.consumer == 1, "duplicate components/macros read once per classification")
	plans = {}
	st = read()
	assert(not st.wares.metals and st.wares.widgets.output, "under-construction component works without plan entry")
	modules[2] = nil
	st = read()
	assert(st.wares.metals.output and not st.wares.gas, "cancelled plan restores output on next read")
	assert(st.wares.metals.prodMax == baseline.wares.metals.prodMax)
	assert(not st.wares.widgets, "cancelled future producer removes its output")

	-- Future copies of a built producer change neither rates nor actual inventory.
	plans = {plan("smelter"), plan("smelter", "expansion")}
	modules[2] = {id="expansion",macro="smelter",construction=true}
	st = read()
	for _, key in ipairs({"stock", "limit", "capacityUnits", "prodMax", "prodKnown"}) do
		assert(st.wares.metals[key] == baseline.wares.metals[key], "planned expansion changed metric: " .. key)
	end
	modules[2] = nil
	-- Newly visible output stock is real station cargo, independent of future capacity.
	plans = {plan("gasworks")}
	st = read()
	assert(st.wares.gas.output and st.wares.gas.stock == 7 and st.wares.gas.capacityUnits == 250)
	assert(st.wares.gas.prodMax == 0 and not st.wares.gas.prodKnown)

	plans = {plan("processor"), plan("storage")}
	st = read()
	assert(st.wares.rawscrap.input and st.wares.energycells.input and st.wares.scrapmetal.output)
	assert(st.wares.scrapmetal.prodMax == 0 and not st.wares.scrapmetal.prodKnown)
	assert(st.wares.rawscrap.consKnown and st.wares.rawscrap.consMax == 0)
	assert(st.wares.metals.stock == 40 and st.wares.metals.prodMax == 60)
	assert(st.wares.metals.capacityUnits == 250 and st.wares.metals.capacityUnitsKnown)
	plans = {plan("yard")}
	st = read()
	assert(not st.wares.metals and st.wares.shipbits.input and st.wares.shipbits.consKnown)
	assert(not st.wares.energycells, "station construction materials are not operating inputs")

	-- A future producer supplying an existing input makes that input internal too.
	inputs = {"ore", "gas"}
	plans = {plan("gasworks")}
	assert(not read().wares.gas and read().wares.ice.input)
	inputs = {"ore"}

	-- Completion uses engine roles and native rates, with no duplicate future inventory.
	modules[2] = {id="completed",macro="consumer"}
	products, inputs = {"widgets"}, {"ore", "gas"}
	plans = {plan("consumer", "completed")}
	st = read()
	assert(st.wares.widgets.output and st.wares.gas.input)
	assert(st.wares.gas.consKnown, "completed consumers retain native rate accounting")
	modules[2] = nil
	products, inputs = {"metals"}, {"ore"}

	plans = {plan("broken"), plan("consumer")}
	local before = #logs
	assert(read().wares.gas.input and not read().wares.metals)
	assert(#logs == before + 1, "recipe failures must be reported")
	read()
	assert(#logs == before + 1, "recipe diagnostics are deduplicated")
	failPlan = true
	modules[2] = {id="unfinished",macro="consumer",construction=true}
	assert(read().wares.gas.input, "plan failure preserves unfinished component evidence")
	assert(#logs == before + 2)
	print("PASS planned/unfinished ware roles, graph connections, cancellation and metric isolation")
end
