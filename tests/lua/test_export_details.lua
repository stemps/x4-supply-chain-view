-- Shared with test_metrics.py's real detail renderers and native-style widgets.
local function producer(demand)
	return {id="hidden",name="Hidden supplier",wares={food={name="Food",output=false,input=false,
		metricOutput=true,metricInput=demand,prodMax=200,prodKnown=true,consMax=100,consKnown=true,
		stock=10,limit=100,workforce=100,workforceKnown=true,
		export=SCV_Metrics.exportDecision(200,100,1,true)}}}
end
local buyer={id="buyer",name="Buyer",wares={food={name="Food",input=true,stock=20,limit=100,consMax=20,consKnown=true}}}
local graph=SCV_Graph.build({producer(true),buyer})
local node=graph.wareNodes.food
menu.graph=graph
local panel, frame=tableMock(),{properties={height=400}}
-- Suppliers hidden by the station budget are still available to the popup.
graph.stationNodes.hidden=nil
menu.expandWare(nil,frame,panel,node)
local suppliers, explanation=0,false
for _, row in ipairs(panel.rows) do
	if row.key == "station:hidden" then suppliers=suppliers+1 end
	local text=row[1].text
	if type(text) == "string" and text:find("full-staffing reserve: 100/h",1,true) then
		assert(text:find("current workforce demand: 100/h",1,true))
		assert(text:find("export surplus: 100/h",1,true))
		assert(text:find("average module: 200/h",1,true))
		explanation=true
	end
end
assert(suppliers == 2 and explanation, "hidden station is both supplier and internal consumer")
local rebuilds, closes=0,0
local widget={customdata={nodedata=node}}
function widget:collapse() closes=closes+1 end
function widget:expand() rebuilds=rebuilds+1 end
menu.expandedNode, menu.expandedMenuFrame=widget,nil
local update=menu.updateMetricDisplay
menu.updateMetricDisplay=function() end
menu.publishMetrics({producer(true),buyer})
assert(rebuilds == 0, "unchanged contributor rows do not rebuild popup")
menu.publishMetrics({producer(false),buyer})
assert(rebuilds == 1 and closes == 1, "changed contributor rows rebuild popup once")
menu.publishMetrics({producer(false),buyer})
assert(rebuilds == 1)
menu.updateMetricDisplay=update
menu.expandedNode,menu.expandedMenuFrame=nil,nil

-- Fresh eligibility explains the frozen visible role until a rebuild.
local fresh=producer(true)
fresh.wares.food.prodMax=400
fresh.wares.food.export=SCV_Metrics.exportDecision(400,100,1,true)
fresh.wares.food.output=true
SCV_Graph.refreshMetrics(graph,{fresh,buyer})
assert(graph.structureChanged and graph.metricStations.hidden.wares.food.output == false)
panel=tableMock()
menu.expandWare(nil,frame,panel,node)
local pending=false
for _, row in ipairs(panel.rows) do
	local text=row[1].text
	if type(text) == "string" and text:find("Connection changes apply after rebuilding the view.",1,true) then pending=true end
end
assert(pending)
print("PASS hidden supplier/demand details, export explanations and contributor-only popup rebuilds")
