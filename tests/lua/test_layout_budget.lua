local G = SCV_Graph
local function station(id)
	return {id=tostring(id),name="Station "..id,code="Code "..id,
		wares={["w"..id]={output=true,prodMax=100,prodKnown=true,stock=10,limit=100}}}
end
local function graph(stations) return G.build(stations,{deferBudget=true}) end
local function countRouted(g, result)
	local count=0
	for _, n in ipairs(g.nodes) do for _ in pairs(n.predecessors or {}) do count=count+1 end end
	for _, n in ipairs(result.junctions) do for _ in pairs(n.predecessors or {}) do count=count+1 end end
	assert(count == result.postEdges, "accepted layout predecessor maps match routed totals")
	return count
end
local function mockLayout(g)
	local calls=0
	return function(nodes)
		calls=calls+1
		local real,junctions={},{}
		for _, n in ipairs(nodes) do real[n]=true end
		for _, n in ipairs(nodes) do
			for pred in pairs(n.predecessors or {}) do assert(real[pred], "old junction leaked into retry") end
			n.row,n.col=1,calls
		end
		for _, e in ipairs(g.edges) do
			local pred=e.from
			for i=2,e.testSegments or 1 do
				local j={predecessors={[pred]=e.rank},row=1,col=calls}
				junctions[#junctions+1],pred=j,j
			end
			e.to.predecessors[e.from]=nil
			e.to.predecessors[pred]=e.rank
		end
		return 1,2,junctions
	end, function() return calls end
end

-- Exact reported allocation: 24 stations + 24 wares + 20 junctions, 152 segments.
local stations={}
for i=1,24 do
	stations[i]=station(i)
	if i>12 then
		for j=1,9 do stations[i].wares["w"..j]={input=true,consMax=1,consKnown=true,stock=1,limit=10} end
	end
end
local g=graph(stations)
assert(#g.nodes == 48 and #g.edges == 132 and #g.droppedEdges == 0)
local inputs=0
for _, e in ipairs(g.edges) do
	if e.from.scvkind == "ware" then
		inputs=inputs+1
		if inputs<=20 then e.testSegments=2 end
		if inputs == 1 then e.inputProvenance="workforce" end
	end
end
local node=g.wareNodes.w1
local supply,demand,stock=node.supplyCap,node.demandCap,node.storage.stock
local layout,calls=mockLayout(g)
local fitted=G.fitLayout(g,layout)
assert(fitted.initial.nodes == 68 and fitted.initial.edges == 152)
assert(fitted.fits and fitted.postEdges == 150 and #g.budgetDroppedEdges == 1 and calls() == 3)
assert(#g.nodes == 48 and #g.droppedStations == 0 and #g.collapsedWares == 0 and #g.droppedEdges == 0)
assert(g.budgetDroppedEdges[1].inputProvenance == "workforce")
assert(node.supplyCap == supply and node.demandCap == demand and node.storage.stock == stock)
local outputs=0
for _, e in ipairs(g.edges) do if e.from.scvkind == "station" then outputs=outputs+1 end end
assert(outputs == 24)
countRouted(g,fitted)
-- Failed restoration must restore positions as well as predecessor maps.
for _, n in ipairs(g.nodes) do assert(n.col == 2) end
local edges=g.edges
G.refreshMetrics(g,stations)
assert(g.edges == edges and #g.budgetDroppedEdges == 1 and node.demandCap == demand)

-- Undo an individually redundant cut: short workforce link is tried first,
-- but hiding a long other-purpose link ultimately makes the first cut unnecessary.
local a,b,c=station("a"),station("b"),station("c")
c.wares.wa={input=true,inputProvenance="workforce"}
c.wares.wb={input=true,inputProvenance="other"}
g=graph({a,b,c})
for _, e in ipairs(g.edges) do if e.from.scvkind == "ware" and e.ware == "wb" then e.testSegments=4 end end
layout=mockLayout(g)
fitted=G.fitLayout(g,layout,{maxNodes=100,maxEdges=4,maxCols=30})
assert(fitted.fits and #g.budgetDroppedEdges == 1 and g.budgetDroppedEdges[1].ware == "wb")
assert(countRouted(g,fitted) == 4)

-- Equal purpose prefers the connection with more routing segments.
c.wares.wa.inputProvenance="other"
g=graph({a,b,c})
for _, e in ipairs(g.edges) do if e.from.scvkind == "ware" and e.ware == "wb" then e.testSegments=4 end end
layout,calls=mockLayout(g)
fitted=G.fitLayout(g,layout,{maxNodes=100,maxEdges=4,maxCols=30})
assert(#g.budgetDroppedEdges == 1 and g.budgetDroppedEdges[1].ware == "wb" and calls() == 3)

-- Nothing is removed when the first layout fits.
g=graph({station(1),station(2)})
layout,calls=mockLayout(g)
fitted=G.fitLayout(g,layout)
assert(fitted.fits and calls() == 1 and #g.budgetDroppedEdges == 0)
-- Output-only diagrams fall back to node reductions, retaining metric contributors.
g=graph({station(1),station(2),station(3),station(4)})
layout=mockLayout(g)
fitted=G.fitLayout(g,layout,{maxNodes=6,maxEdges=150,maxCols=30})
assert(fitted.fits and #g.droppedStations == 1 and #g.nodes == 6)
assert(g.metricStations[g.droppedStations[1].id])

-- Common-ware fallback retains all metric records, even with no ware node left.
local common={}
for i=1,4 do common[i]={id=tostring(i),name="Common "..i,wares={water={output=true,prodMax=10,prodKnown=true}}} end
g=graph(common)
layout=mockLayout(g)
fitted=G.fitLayout(g,layout,{maxNodes=4,maxEdges=150,maxCols=30})
assert(fitted.fits and #g.collapsedWares == 1 and #g.droppedStations == 0)
assert(g.metricStations["1"].wares.water.prodMax == 10)

-- Cycle and budget cuts remain distinct; neither alters consumer accounting.
a,b=station("a"),station("b")
a.wares.wb={input=true,stock=10,consMax=5,consKnown=true,inputProvenance="workforce"}
b.wares.wa={input=true,stock=10,consMax=7,consKnown=true,inputProvenance="workforce"}
g=graph({a,b})
assert(#g.droppedEdges == 1)
layout=mockLayout(g)
fitted=G.fitLayout(g,layout,{maxNodes=100,maxEdges=2,maxCols=30})
assert(fitted.fits and #g.droppedEdges == 1 and #g.budgetDroppedEdges == 1)
assert(g.wareNodes.wa.demandCap == 7 and g.wareNodes.wb.demandCap == 5)
assert(#g.nodes == 4 and #g.edges == 2)

if Helper.setupDAGLayout then
	-- Exercise the actual mutable layout, including long-chain column pressure.
	local chain={}
	for i=1,20 do
		chain[i]=station(i)
		if i>1 then chain[i].wares["w"..(i-1)]={input=true,inputProvenance="workforce"} end
	end
	g=graph(chain)
	fitted=G.fitLayout(g,Helper.setupDAGLayout)
	assert(fitted.initial.cols == 40 and fitted.fits and fitted.cols<=30)
	assert(#g.nodes == 40 and #g.droppedStations == 0 and #g.budgetDroppedEdges>0)
	countRouted(g,fitted)
	-- Dense 24-station DAG: pre-layout counts fit but routing may not.
	g=graph(stations)
	fitted=G.fitLayout(g,Helper.setupDAGLayout)
	assert(fitted.fits and fitted.postNodes<=100 and fitted.postEdges<=150 and fitted.cols<=30)
	assert(#g.droppedStations == 0 and #g.nodes == 48)
	countRouted(g,fitted)
	print("PASS local vanilla routing, column fallback and fresh predecessor reconstruction")
end
