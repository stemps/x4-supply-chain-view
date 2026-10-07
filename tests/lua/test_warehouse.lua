-- Loaded by test_metrics.py. Plain trade goods on a station without modules for them
-- have a known zero rate; mined, salvaged and unreadable goods stay unknown.
local componentData, wareData = GetComponentData, GetWareData
local oldModules, oldWorkforce = state.modules, state.workforce
local minable = { claytronics = false, ore = true, rawscrap = false, hullparts = false }
local processed = { claytronics = false, ore = false, rawscrap = true, hullparts = false }
GetComponentData = function (id, key)
	if key == "availableproducts" or key == "pureresources" or key == "intermediatewares" then return {} end
	if key == "tradewares" then return { "claytronics", "ore", "rawscrap", "hullparts" } end
	return componentData(id, key)
end
GetWareData = function (ware, key)
	if key == "isminable" then
		if ware == "hullparts" then error("ware data unavailable") end
		return minable[ware]
	end
	if key == "isprocessed" then return processed[ware] end
	return wareData(ware, key)
end
local function read()
	return SCV_Data.readStation({ id = "wh", id64 = "wh", name = "Warehouse" })
end

state.modules, state.workforce = false, 0
local st = read()
local clay = st.wares.claytronics
-- Bought and sold: output wins by default, and both directions are known zero.
assert(clay.output and clay.prodKnown and clay.prodMax == 0)
assert(clay.consKnown and clay.consMax == 0)
assert(SCV_Graph.rateKnown(clay, false) and SCV_Graph.rateKnown(clay, true))
assert(not st.wares.ore.prodKnown and not st.wares.ore.consKnown, "mining hub ore stays unknown")
assert(not st.wares.rawscrap.prodKnown, "salvaged scrap stays unknown")
assert(not st.wares.hullparts.prodKnown, "a failed ware read cannot establish zero")

-- A known-zero warehouse completes a chain's balance instead of starring it.
local factory = { id = "f", name = "Factory", wares = { claytronics = {
	name = "Claytronics", output = true, metricOutput = true, prodMax = 500, prodKnown = true, stock = 0 } } }
local graph = SCV_Graph.build({ st, factory })
local node = graph.wareNodes.claytronics
assert(node.supplyKnown and node.supplyCap == 500 and node.demandKnown)

-- Consumer override: the warehouse still reads as a known zero consumer.
clay.output, clay.input = false, true
graph = SCV_Graph.build({ st, factory })
node = graph.wareNodes.claytronics
assert(node.demandKnown and node.demandCap == 0 and node.netKnown and node.netRate == 500)

-- A module making the traded ware owns its rate as before.
state.modules = true
GetComponentData = function (id, key)
	if key == "availableproducts" or key == "pureresources" or key == "intermediatewares" then return {} end
	if key == "tradewares" then return { "energycells" } end
	return componentData(id, key)
end
minable.energycells, processed.energycells = false, false
st = read()
assert(st.wares.energycells.prodMax == state.prod, "recipe output is not a plain trade good")

GetComponentData, GetWareData = componentData, wareData
state.modules, state.workforce = oldModules, oldWorkforce
