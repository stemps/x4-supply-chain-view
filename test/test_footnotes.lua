-- Shared formatter registry, station attribution and wrapped footer layout.
local previousGraph, previousChart = menu.graph, menu.flowchart
local a={id="a",name="Producer*",wares={
	food={name="Food",output=true,prodKnown=false,prodMax=10},
	meds={name="Meds",output=true,prodKnown=true,prodMax=10}}}
local b={id="b",name="Buyer",wares={
	food={name="Food",input=true,consKnown=true,consMax=5,stock=10},
	meds={name="Meds",input=true,consKnown=true,consMax=5,stock=10}}}
local graph=SCV_Graph.build({a,b,{id="c",name="Unrelated",wares={}}})
local kept={}
for _, edge in ipairs(graph.edges) do
	if edge.to == graph.stationNodes.b then
		if edge.ware == "food" then graph.droppedEdges={edge}
		else graph.budgetDroppedEdges={edge} end
	else kept[#kept+1]=edge end
end
graph.edges=kept
menu.graph=graph
for i=1,2 do
	menu.decorateNodes(graph)
	assert(graph.stationNodes.a.text == "Producer*", "do not interpret name punctuation as a footnote")
	assert(graph.stationNodes.b.text == "Buyer [1][2]" and graph.stationNodes.b.name == "Buyer")
	assert(graph.stationNodes.c.text == "Unrelated")
	assert(graph.wareNodes.food[1].statusText:sub(-1) == "*")
	assert(#graph.footnoteKeys == 3, "one entry per footnote type, not per station or edge")
	assert(graph.stationNodes.b[1].properties.mouseOverText:find("[1] Some incoming connections hidden to avoid cycles",1,true))
	assert(graph.stationNodes.b[1].properties.mouseOverText:find("[2] Some incoming connections hidden to fit constraints",1,true))
end
local border,frameBorder=Helper.borderSize,Helper.frameBorder
Helper.borderSize,Helper.frameBorder=2,8
local footer={properties={},lines={}}
function footer:addRow(_, props)
	assert(props.fixed)
	return {{createText=function(_,text,style)
		assert(style.wordwrap); footer.lines[#footer.lines+1]=text
	end}}
end
function footer:getFullHeight() return #self.lines*40 end
local frame={getAvailableHeight=function() return 600 end}
function frame:addTable(_, props) footer.properties=props; return footer end
menu.flowchart={properties={}}
function menu.flowchart:getVisibleHeight() return self.properties.maxVisibleHeight end
menu.drawChainLegend(frame,10,100,500)
assert(#footer.lines == 3 and footer.lines[1]:sub(1,1) == "*")
assert(footer.lines[2]:sub(1,3) == "[1]" and footer.lines[3]:sub(1,3) == "[2]")
assert(footer.properties.y+footer:getFullHeight() == 592, "reserve the whole multiline footer")
-- Budget-removed endpoints must not create a misleading station annotation.
local removed=graph.wareNodes.food
for i,node in ipairs(graph.nodes) do if node == removed then table.remove(graph.nodes,i); break end end
menu.decorateNodes(graph)
assert(graph.stationNodes.b.text == "Buyer [2]" and #graph.footnoteKeys == 2)
graph.budgetDroppedEdges={}
menu.decorateNodes(graph)
assert(graph.stationNodes.b.text == "Buyer" and #graph.footnoteKeys == 1)
menu.graph,menu.flowchart=previousGraph,previousChart
Helper.borderSize,Helper.frameBorder=border,frameBorder
print("PASS shared footnotes, affected-station captions, tooltip parity and wrapped footer")
