local s
local function reset()
	s = { ware="alienfood", production=200, current=100, optimal=100, capacity=200,
		modules=1, races={ {race="a", productamount=1, resources={{ware="alienfood",cycle=1,cycleduration=3600}}} },
		raceInfo={a={current=100,capacity=200,target=100}}, plans={} }
end
function DebugError() end
function ConvertStringTo64Bit(id) return id end
function IsValidComponent() return true end
function IsComponentConstruction() return false end
function IsMacroClass(_, kind) return kind == "production" end
function GetComponentData(id, key)
	if key == "tradewares" and s.badRoles then error("unknown trade roles") end
	if key == "macro" then return s.unequal and (id == "module0" and "small" or "large") or "factory" end
	if key == "availableproducts" then return s.intermediate and {} or {s.ware} end
	if key == "pureresources" then return s.resource and {s.ware} or {} end
	if key == "intermediatewares" then return s.intermediate and {s.ware} or {} end
	if key == "tradewares" then return s.trade and {s.ware} or {} end
	if key == "cargo" then return {[s.ware]=10} end
	return key
end
function GetMacroData() return "moduletypes_production" end
function GetLibraryEntry(_, macro)
	if s.badRecipe then error("unknown recipe") end
	return {products={{ware=macro == "consumer" and "other" or s.ware,amount=macro == "small" and 50 or macro == "large" and 150 or 100,cycle=s.unequal and 3600 or 60,
		resources=(s.resource or macro == "consumer") and {{ware=s.ware,amount=1}} or {}}}}
end
function GetWareData(ware, key) return key == "volume" and 1 or key == "transport" and "container" or ware end
function GetWareProductionLimit() return 100 end
function GetWorkForceRaceResources() if s.badWorkforce then error("unknown workforce") end return s.races end
Helper = { getWorkforceConsumption=function(_, ware)
	if s.badActual then error("unknown actual demand") end
	local demand=0
	for _, race in ipairs(s.races) do
		for _, resource in ipairs(race.resources) do
			if resource.ware == ware then demand=demand+math.floor(resource.cycle*3600/resource.cycleduration
				*s.raceInfo[race.race].current/race.productamount+0.5) end
		end
	end
	return demand
end }
C = {}
package.preload.ffi = function() return {C=C,new=function() return {} end,string=tostring} end
function C.GetWorkForceInfo(_, race)
	if race == "" then return {current=s.current,optimal=s.optimal,capacity=s.capacity} end
	return s.raceInfo[race]
end
function C.GetNumContainerWorkforceInfluence() return {numcapacityinfluences=0,numgrowthinfluences=0} end
function C.GetContainerWorkforceInfluence(buf, _, race) buf.target=s.raceInfo[race].target end
function C.GetNumStationModules() return s.modules end
function C.GetStationModules(buf) for i=0,s.modules-1 do buf[i]="module"..i end return s.shortRead and 0 or s.modules end
function C.IsRealComponentClass(_, kind) return kind == "production" end
function C.IsComponentOperational() return not s.inactive end
function C.IsInfoUnlockedForPlayer() return true end
function C.GetNumPlannedStationModules() return #s.plans end
function C.GetPlannedStationModules(buf) for i,p in ipairs(s.plans) do buf[i-1]={componentid=0,macroid=p} end return #s.plans end
function C.GetNumContainerBuildResources() return s.build and 1 or 0 end
function C.GetContainerBuildResources(buf) buf[0]=s.ware return 1 end
function C.GetNumContainerWareReservations2() return 0 end
function C.GetNumCargoTransportTypes() return 0 end
function C.GetContainerWareProduction() return s.production end
function C.GetContainerWareConsumption() return 0 end
function C.GetContainerWareIsSellable() return true end
function C.GetContainerWareIsBuyable() return true end

return function()
	local function read() return SCV_Reader.readStation({id="A",id64="A",name="A"}, {describe=function() end,readLogistics=function() end}) end
	local function ware() return read().wares[s.ware] end
	local m=SCV_Metrics
	for _, case in ipairs({{200,100,1,"self"},{200,99,1,"export"},{200,150,4,"export"},
		{100,120,1,"import"},{100,100,1,"self"},{0,0,1,"self"},{200,151,4,"self"},
		{200,150,0,"unknown"},{200,150,1.5,"unknown"}}) do
		assert(m.exportDecision(case[1],case[2],case[3],true).state == case[4])
	end
	assert(m.exportDecision(200,0,1,false).state == "unknown")
	reset()
	for _, name in ipairs({"water","bofu","medicalsupplies","alienfood"}) do
		s.ware=name; s.races[1].resources[1].ware=name; s.intermediate=true
		local w=ware()
		assert(w and w.metricOutput and w.metricInput and not w.output and not w.input)
		assert(w.prodMax == 200 and w.consMax == 100 and w.export.state == "self")
	end
	s.intermediate=false; s.optimal=99; s.current=0; s.raceInfo.a.current=0
	assert(ware().output and ware().export.reserve == 99, "empty habitat reserves full staffing")
	s.optimal=150; s.modules=4
	assert(ware().output and ware().export.moduleCapacity == 50, "P/N uses effective total, not base recipes")
	s.modules=1; s.production=100
	assert(ware().input and not ware().output and ware().metricOutput)
	s.optimal=50; s.current=160; s.raceInfo.a.current=160
	assert(ware().export.reserve == 160, "excess current workforce is retained")
	reset(); s.unequal=true; s.modules=2
	assert(ware().output and ware().export.moduleCapacity == 100, "unequal modules use their average")
	s.production=300; s.optimal=200
	assert(not ware().output and ware().export.moduleCapacity == 150, "current modifiers determine the average")
	reset(); s.races[2]={race="b",productamount=1,resources={{ware=s.ware,cycle=2,cycleduration=3600}}}
	s.raceInfo.a={current=25,capacity=100,target=50}; s.raceInfo.b={current=75,capacity=100,target=50}
	assert(ware().export.reserve == 175, "max of total actual and allocated demand, not sum of per-race maxima")
	s.current=0; s.raceInfo.a.current=0; s.raceInfo.b.current=0
	assert(ware().export.reserve == 150, "full requirement is allocated once across races")
	s.raceInfo.b.target=100
	assert(ware().output and ware().export.state == "unknown", "mismatched targets cannot hide outputs")
	s.raceInfo.b.target=50; s.capacity=201
	assert(ware().export.state == "unknown", "incomplete race coverage")
	reset(); s.inactive=true; s.intermediate=true
	assert(ware().output and ware().export.state == "unknown", "inactive product remains classified")
	reset(); s.shortRead=true
	assert(ware().output and ware().export.state == "unknown")
	reset(); s.resource=true; s.intermediate=true
	assert(ware() == nil, "true production intermediate remains excluded")
	reset(); s.plans={"consumer"}
	assert(ware() == nil, "planned consumer exclusion")
	reset(); s.build=true
	assert(not ware().output, "build consumer veto")
	reset(); s.modules=0; s.plans={"factory"}
	assert(ware().output and ware().export.state == "unknown", "planned-only capacity cannot establish surplus")
	reset(); s.modules=0; s.trade=true; s.races={}; s.capacity=0; s.current=0
	assert(ware().output and not ware().input and not ware().export, "trade hubs keep output wins")
	reset(); s.badRoles=true
	assert(ware().output and ware().inputProvenance == "other" and ware().export.state == "unknown")
	reset(); s.badWorkforce=true
	assert(ware().output and ware().metricInput and ware().export.state == "unknown")
	reset(); s.trade=true; s.production=50
	assert(ware().input and ware().inputProvenance == "other", "trade inputs are protected")
	reset(); s.badActual=true
	assert(ware().output and ware().metricInput and not ware().consKnown)

	reset()
	local hidden=read()
	local buyer={id="B",name="B",wares={alienfood={input=true,consMax=20,consKnown=true,stock=5,limit=100}}}
	local graph=SCV_Graph.build({hidden,buyer})
	local node=graph.wareNodes.alienfood
	assert(node and #node.producers == 0 and #node.metricProducers == 1 and #node.metricConsumers == 2)
	assert(node.supplyCap == 200 and node.demandCap == 120 and node.storage.stock == 15)
	assert(#graph.stationNodes.B.unmet == 0, "hidden supplier is not absent")
	SCV_Graph.pruneOrphanWares(graph)
	assert(graph.wareNodes.alienfood == node, "budget pruning retains a hidden-supplier-backed input node")
	assert(SCV_Graph.build({read()}).wareNodes.alienfood == nil, "self supply needs no isolated node")
	s.production=400
	SCV_Graph.refreshMetrics(graph,{read(),buyer})
	assert(graph.structureChanged and not graph.metricStations.A.wares.alienfood.output)
	assert(node.supplyCap == 400 and node.demandCap == 120, "visibility changes still publish valid metrics")
	s.badActual=true
	SCV_Graph.refreshMetrics(graph,{read(),buyer})
	assert(not node.demandKnown and #node.metricConsumers == 2, "failed reads preserve demand obligation")

	local function station(id, output, input, provenance)
		local wares={}
		for _, w in ipairs(output) do wares[w]={output=true,prodMax=10,prodKnown=true,stock=1} end
		for _, w in ipairs(input) do wares[w]=wares[w] or {}; wares[w].input=true; wares[w].inputProvenance=provenance end
		return {id=id,code="CODE-"..id,name=id,wares=wares}
	end
	local function path(graph, start, target)
		local seen, stack={}, {start}
		while #stack>0 do
			local n=table.remove(stack)
			if n == target then return true end
			if not seen[n] then
				seen[n]=true
				for _, e in ipairs(graph.edges) do if e.from == n then stack[#stack+1]=e.to end end
			end
		end
		return false
	end
	local function verify(stations)
		local g=SCV_Graph.build(stations)
		local expected, outputs=0,0
		for _, st in ipairs(stations) do for _, w in pairs(st.wares) do if w.output then expected=expected+1 end end end
		for _, e in ipairs(g.edges) do
			assert(not path(g,e.to,e.from), "acyclic")
			if e.from.scvkind == "station" then outputs=outputs+1 end
		end
		assert(outputs == expected, "all outputs preserved")
		local signature={}
		for _, e in ipairs(g.droppedEdges) do
			assert(e.from.scvkind == "ware" and e.to.scvkind == "station")
			assert(path(g,e.to,e.from), "each remaining cut is necessary")
			signature[#signature+1]=e.ware..":"..e.to.scvid
		end
		return g,table.concat(signature,",")
	end
	local stations={station("A",{"food"},{"meds"},"workforce"),station("B",{"meds"},{"food"},"other"),station("C",{},{"food"},"workforce")}
	local g, sig=verify(stations)
	assert(sig == "meds:A" and #g.wareNodes.food.consumers == 2)
	local _, reversed=verify({stations[3],stations[2],stations[1]})
	assert(sig == reversed, "equivalent ordering yields identical cuts")
	verify({station("A",{"x"},{"x"},"workforce")})
	verify({station("A",{"a"},{"c","b"}),station("B",{"b"},{"a","c"}),station("C",{"c"},{"b"})})
	-- Multiple overlapping cycles, mixed and unknown provenance, deterministic ties.
	for seed=1,30 do
		local list={}
		for i=1,6 do
			local inputs={}
			for j=1,6 do if (i*7+j*13+seed)%5<2 then inputs[#inputs+1]="w"..j end end
			list[i]=station(tostring(i),{"w"..i},inputs,i%2 == 0 and "workforce" or "other")
		end
		local _, first=verify(list)
		local reverse={}; for i=#list,1,-1 do reverse[#reverse+1]=list[i] end
		local _, second=verify(reverse); assert(first == second)
	end
end
