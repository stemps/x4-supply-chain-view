"""Reader-to-graph-to-popup contract tests with an explicit fake engine.

These verify our use of engine results, not the engine's implementation of ignorestate.
Run from any directory: uv run --with lupa python test_metrics.py
"""
from pathlib import Path
from xml.etree import ElementTree as ET
from lupa import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
texts = {int(t.attrib['id']): ''.join(t.itertext()) for t in ET.parse(root/'t/0001.xml').iter('t')}
g.texts = lua.table_from(texts)
lua.execute('''
logs = {}
function DebugError(s) logs[#logs+1] = s end
function ReadText(page, id) return texts[id] or tostring(id) end
function ConvertStringTo64Bit(v) return v end
state = { modules=true, build=false, stockKnown=true, reservations=true, workforce=100,
          prod=4800000, cons=2400000, cargo={energycells=120000, food=10000},
          incoming=2000, outgoing=12000 }
C = {}
package.preload.ffi = function() return {C=C, new=function() return {} end, string=tostring} end
function C.IsComponentClass() return true end
function C.IsRealComponentClass(id, class) return class == 'production' end
function C.IsComponentOperational() return not state.nonOperational end
function C.IsInfoUnlockedForPlayer(id, key)
    if key == 'production_rate' then return not state.rateLocked end
    return key ~= 'storage_amounts' or state.stockKnown
end
function C.GetNumStationModules() return state.modules and 1 or 0 end
function C.GetStationModules(buf) buf[0]='module'; return 1 end
function C.GetNumContainerBuildResources() return state.build and 1 or 0 end
function C.GetContainerBuildResources(buf) buf[0]='energycells'; return 1 end
function C.GetNumContainerWareReservations2()
    if not state.reservations then error('reservation failure') end
    return 2
end
function C.GetContainerWareReservations2(buf)
    buf[0]={ware='energycells', amount=state.incoming, isbuyreservation=false, tradedealid=1}
    buf[1]={ware='energycells', amount=state.outgoing, isbuyreservation=true, tradedealid=2}
    return 2
end
function C.GetNumCargoTransportTypes() return 0 end
function C.GetContainerWareProduction(id, ware, ignorestate)
    assert(ignorestate == true, 'displayed production must use maximum mode')
    return ware == 'energycells' and state.prod or 0
end
function C.GetContainerWareConsumption(id, ware, ignorestate)
    assert(ignorestate == true, 'displayed consumption must use maximum mode')
    return ware == 'energycells' and state.cons or 0
end
function C.GetContainerWareIsSellable() return true end
function C.GetContainerWareIsBuyable() return true end
function GetComponentData(id, key)
    if key == 'isplayerowned' then return not state.npcStation end
    if key == 'availableproducts' then return {'energycells'} end
    if key == 'pureresources' then return {'food'} end
    if key == 'tradewares' then return {'energycells'} end
    if key == 'intermediatewares' then return {} end
    if key == 'cargo' then return state.cargo end
    return key
end
function GetMacroData() return 'production' end
function GetLibraryEntry()
    return { products={{ware='energycells', amount=100, cycle=60, resources={{ware='food',amount=5}}}} }
end
function GetWareProductionLimit() return 200000 end
function GetWareData(ware, key)
    if key == 'volume' then return 1 end
    return key == 'transport' and 'container' or ware
end
Helper = { standardTextHeight=20, topLevelMenus={}, headerRow1Properties={},
    scaleY=function(value) return value end,
    registerMenu=function() end, clearFrame=function() cleared=true end,
    getWorkforceConsumption=function(id, ware) return ware == 'food' and state.workforce or 0 end }
Color = setmetatable({}, {__index=function(_, key) return key end})
''')
for name in ['scv_graph.lua', 'scv_data.lua']:
    lua.execute((root/'ui'/name).read_text(encoding='utf-8'))
menu = lua.execute((root/'ui/scv_menu.lua').read_text(encoding='utf-8'))
g.menu = menu
lua.execute('''
function read() return SCV_Data.readStation({id='A', id64='A', name='A'}) end
station = read()
assert(station.code == 'idcode', 'reader must carry the durable station code into the graph')
assert(station.wares.energycells.prodMax == 4800000) -- never the base recipe's 6000
assert(station.wares.energycells.prodKnown)
assert(station.wares.food.consMax == 100) -- workforce counted exactly once
assert(station.wares.food.consKnown)
assert(not station.wares.energycells.input) -- sell wins over buy
local b = SCV_Graph.reservationBar(station.wares.energycells)
assert(math.abs(b.percent - 60) < 1e-9 and math.abs(b.futurePercent - 55) < 1e-9 and b.current == 110000)
state.prod=0
assert(read().wares.energycells.prodKnown) -- real zero is known when a module exists
state.prod=4800000
state.modules=false
assert(not read().wares.energycells.prodKnown) -- mining/trade throughput isn't production
state.modules=true
state.nonOperational=true
assert(not read().wares.energycells.prodKnown)
state.nonOperational=false
state.rateLocked=true
assert(not read().wares.energycells.prodKnown)
state.rateLocked=false
state.build=true
assert(not read().wares.energycells.consKnown) -- build demand stays unknown
state.build=false
state.stockKnown=false
local hidden=read().wares.energycells
assert(not hidden.stockKnown and SCV_Graph.reservationBar(hidden).percent == nil)
state.stockKnown=true
state.reservations=false
local missing=read().wares.energycells
assert(not missing.reservationsKnown and SCV_Graph.reservationBar(missing).futurePercent == nil)
state.reservations=true
state.prod=0/0
assert(not read().wares.energycells.prodKnown) -- invalid numeric results cannot become valid zero
state.prod=4800000
station=read()

-- Maximum balance and coverage are independent of current activity.
local producer={id='A',name='A',wares={energycells=station.wares.energycells}}
local consumer={id='B',name='B',wares={energycells={name='energycells',input=true,
    stock=120000,limit=200000,consMax=2400000,consKnown=true,consumption=0}}}
graph=SCV_Graph.build({producer,consumer})
local w=graph.wareNodes.energycells
assert(w.supplyCap == 4800000 and w.netRate == 2400000 and w.demandCap == 2400000)
assert(consumer.wares.energycells.health.cover == 0.05) -- idle consumer still needs full-rate stock coverage
consumer.wares.energycells.consKnown=false
local partial=SCV_Graph.build({producer,consumer}).wareNodes.energycells
assert(not partial.netKnown and partial.netRate == nil and partial.demandCap == 2400000)
menu.decorateNodes(SCV_Graph.build({producer,consumer})) -- nil net must not crash rendering
consumer.wares.energycells.consKnown=true
consumer.wares.energycells.consMax=0
assert(SCV_Graph.build({producer,consumer}).wareNodes.energycells.demandCap == 0)

-- Record actual widget calls to compare both popup entry points.
function resolve(value)
    return type(value) == 'function' and value() or value
end
function resolveProperties(props)
    local out={}
    for key,value in pairs(props or {}) do out[key]=resolve(value) end
    return out
end
function tableMock()
    local t={properties={},rows={},groups={}}
    function t:setColWidthPercent() end
    function t:setColWidth() end
    function t:addRowGroup(properties)
        local group={properties=properties,rows={}}
        self.groups[#self.groups+1]=group
        local owner=self
        function group:addRow(key,props)
            local r=owner:addRow(key,props)
            r.group=self; self.rows[#self.rows+1]=r
            return r
        end
        return group
    end
    function t:addRow(key, props)
        local r={key=key,properties=props}; self.rows[#self.rows+1]=r
        for i=1,4 do
            local c={handlers={}}; r[i]=c
            function c:setColSpan(n) self.span=n; return self end
            function c:createIcon(icon, props) self.icon=icon; self.iconProps=props; return self end
            function c:getColSpanWidth() return 160 end
            function c:createCheckBox(checked, props) self.checked=checked; self.checkbox=props; return self end
            function c:setBackgroundColSpan(n) self.bgspan=n; return self end
            function c:createText(text, props)
                self.rawText=text; self.rawProps=props
                self.text=resolve(text); self.props=resolveProperties(props); return self
            end
            function c:createStatusBar(props)
                self.rawBar=props; self.bar=resolveProperties(props); return self
            end
            function c:update()
                if self.rawText then self.text=resolve(self.rawText) end
                if self.rawProps then self.props=resolveProperties(self.rawProps) end
                if self.rawBar then self.bar=resolveProperties(self.rawBar) end
            end
            function c:createButton(props) self.button=props; return self end
            function c:setText(text) self.text=text; return self end
        end
        return r
    end
    return t
end
function compareEntry(role, stationID)
    graph=SCV_Graph.build({producer,consumer})
    menu.graph=graph
    local a,b=tableMock(),tableMock()
    local frame={properties={height=220}}
    menu.expandStation(nil,frame,a,graph.stationNodes[stationID])
    menu.expandWare(nil,frame,b,graph.wareNodes.energycells)
    local function find(t,key)
        for i,r in ipairs(t.rows) do if r.key==key then return i end end
        error('missing row '..key)
    end
    local i,j=find(a,'ware:energycells'),find(b,'station:'..stationID)
    for _,key in ipairs({'start','current','max','height','valueColor','posChangeColor','negChangeColor'}) do
        assert(a.rows[i+1][1].bar[key] == b.rows[j+1][1].bar[key], key)
    end
    assert(a.rows[i+2][1].text == b.rows[j+2][1].text)
    assert(a.rows[i+2][2].text == b.rows[j+2][2].text)
    assert(a.rows[i+3][1].text == b.rows[j+3][1].text)
    assert(a.rows[i+4][1].props.height == 2 and b.rows[j+4][1].props.height == 2)
    assert(a.rows[i+4].properties.borderBelow == false)
    assert(a.rows[i+2][1].bgspan == 4 and b.rows[j+2][1].bgspan == 4)
    assert(a.rows[i+2][1].span == nil and a.rows[i+2][2].text ~= nil)
    assert(a.rows[i][1].props.mouseOverText and b.rows[j][1].props.mouseOverText)
    local input = stationID == 'B'
    local data = graph.stationNodes[stationID].wares.energycells
    local expectedLabel = data.health.severity == 'critical' and 'icon_error'
        or (data.health.severity == 'warning' and 'icon_warning' or 'text_normal')
    assert(a.rows[i][1].props.color == expectedLabel and b.rows[j][1].props.color == expectedLabel)
    if data.health.severity ~= 'ok' then
        assert(string.find(a.rows[i][1].props.mouseOverText,'threshold: below',1,true))
        assert(string.find(b.rows[j][1].props.mouseOverText,'threshold: below',1,true))
        assert(string.find(a.rows[i][1].props.mouseOverText,'\\n\\n',1,true))
        assert(not string.find(a.rows[i][1].props.mouseOverText,'At full operation:',1,true))
    end
    local color=a.rows[i+2][2].props.color
    if input and data.consKnown and data.consMax>0 then
        assert(color.r==255 and color.g==150 and color.b==150 and color.glow==0)
    else
        assert(color == (not input and data.prodKnown and data.prodMax>0 and 'text_positive' or 'text_inactive'))
    end
    assert(#a.groups==0 and #b.groups==0) -- no automatic group padding
    for n=0,3 do
        assert(a.rows[i+n].group==nil and not a.rows[i+n].properties.borderBelow)
        assert(a.rows[i+n].properties.bgColor=='row_background_unselectable')
        assert(b.rows[j+n].properties.bgColor=='row_background_unselectable')
    end
    assert(a.rows[i+4].group==nil) -- gap is outside the background
    assert(string.find(a.rows[i+3][1].text,input and 'lasts ' or 'fills in ',1,true)==1)
    local function withoutSubject(tip) return tip:sub(tip:find(string.char(10),1,true)+1) end
    for _, offset in ipairs({1,2,3}) do
        local left = offset == 1 and a.rows[i+offset][1].bar.mouseOverText or a.rows[i+offset][1].props.mouseOverText
        local right = offset == 1 and b.rows[j+offset][1].bar.mouseOverText or b.rows[j+offset][1].props.mouseOverText
        assert(withoutSubject(left) == withoutSubject(right))
    end
    assert(withoutSubject(a.rows[i+2][2].props.mouseOverText) == withoutSubject(b.rows[j+2][2].props.mouseOverText))
    assert(a.rows[i][1].props.wordwrap and b.rows[j][1].props.wordwrap)
    assert(a.properties.maxVisibleHeight==220 and b.properties.maxVisibleHeight==220)
    assert(a.properties.highlightMode=='off' and b.properties.highlightMode=='off')
    return a.rows[i+2][1].text,a.rows[i+2][2].text,a.rows[i+3][1].text
end
consumer.wares.energycells.consMax=2400000
function GetFlowchartNodeExpandedFrameData() return 210,100,20,2 end
local paddedFrame={properties={x=100,width=220,height=220}}
menu.graph=SCV_Graph.build({producer,consumer})
menu.expandWare({id=1},paddedFrame,tableMock(),menu.graph.wareNodes.energycells)
assert(paddedFrame.properties.x==82 and paddedFrame.properties.width==256)
assert(paddedFrame.properties.height==220)
menu.expandWare({id=1},paddedFrame,tableMock(),menu.graph.wareNodes.energycells)
assert(paddedFrame.properties.width==256) -- normalization is not cumulative
local stock,rate=compareEntry(false,'A')
assert(stock == 'Amount 120.0k / 200.0k' and rate == '+4.8M/h',stock..rate)
local _, inputRate=compareEntry(true,'B')
assert(inputRate == '-2.4M/h')
consumer.wares.energycells.consKnown=false
assert(select(2,compareEntry(true,'B')) == '? /h')

-- Output headroom remains informational, never a warning.
local output={output=true,stock=3300,limit=18333,prodMax=28200,prodKnown=true}
output.health=SCV_Graph.wareHealth(output)
assert(output.health.severity=='ok' and output.health.reason==nil)
local m=SCV_Graph.detailMetrics(output,false)
assert(math.abs(m.stockHours-3300/28200)<1e-9 and math.abs(m.capacityHours-18333/28200)<1e-9)
assert(math.abs(m.fillHours-(18333-3300)/28200)<1e-9)
local savedOutput=producer.wares.energycells
producer.wares.energycells=output
assert(select(3,compareEntry(false,'A'))=='fills in 31m / from empty 39m')
output.incoming,output.outgoing=9000,2000
assert(select(3,compareEntry(false,'A'))=='fills in 31m / from empty 39m')
output.stock=0
assert(select(3,compareEntry(false,'A'))=='fills in 39m / from empty 39m')
for _,stock in ipairs({18333,20000}) do
    output.stock=stock
    assert(select(3,compareEntry(false,'A'))=='fills in 0m / from empty 39m')
end
output.stock,output.limit,output.capacityUnits=3300,0,18333
assert(select(3,compareEntry(false,'A'))=='fills in ~31m / from empty ~39m')
output.stockKnown=false
assert(select(3,compareEntry(false,'A'))=='fills in ? / from empty ~39m')
output.limit,output.capacityUnits=18333,nil
assert(select(3,compareEntry(false,'A'))=='fills in ? / from empty 39m')
output.stockKnown,output.limit=true,0
assert(select(3,compareEntry(false,'A'))=='fills in ? / from empty ?')
output.limit,output.prodKnown=18333,false
assert(select(3,compareEntry(false,'A'))=='fills in ? / from empty ?')
output.prodKnown,output.prodMax=true,0
assert(SCV_Graph.detailMetrics(output,false).fillHours==nil)
assert(select(3,compareEntry(false,'A'))=='fills in ? / from empty ?')
producer.wares.energycells=savedOutput
local inputMetrics=SCV_Graph.detailMetrics({stock=100,limit=200,consKnown=true,consMax=50},true)
assert(inputMetrics.stockHours==2 and inputMetrics.capacityHours==4 and inputMetrics.fillHours==nil)
local unknown=SCV_Graph.detailMetrics({input=true,stock=100,limit=200,consKnown=false},true)
assert(unknown.stockHours==nil and unknown.capacityHours==nil)
local zero=SCV_Graph.detailMetrics({input=true,stock=100,limit=200,consKnown=true,consMax=0},true)
assert(zero.stockHours==nil and zero.capacityHours==nil)
local over=SCV_Graph.reservationBar({stock=240000,limit=200000,incoming=20000})
assert(over.percent==120 and over.drawStart==200000 and over.drawCurrent==200000)
assert(math.abs(over.futurePercent-130)<1e-9)

-- Scrollability requires a selectable entry for every long-list item.
local yard={scvid='yard',wares={}}
for i=1,60 do yard.wares['ware'..i]={name=string.rep('long name ',10)..i,input=true,
    stock=100,limit=1000,consKnown=false} end
local t=tableMock()
menu.expandStation(nil,{properties={height=220}},t,yard)
local selectable=0
for _,row in ipairs(t.rows) do if row.key then selectable=selectable+1 end end
assert(selectable==62 and t.properties.maxVisibleHeight==220)
assert(t.rows[1][1].text == 'Open Logical Station Overview')
assert(t.rows[2][1].text == 'Open Build Menu' and t.rows[2][1].button.active == true)
local savedOpen, savedCleanup = Helper.closeMenuAndOpenNewMenu, menu.cleanup
local opened, cleaned
Helper.closeMenuAndOpenNewMenu = function(source, target, params)
    assert(source == menu and target == 'StationConfigurationMenu')
    assert(params[1] == 0 and params[2] == 0 and params[3] == 'yard')
    opened = true
end
menu.cleanup = function() cleaned = true end
t.rows[2][1].handlers.onClick()
assert(opened and cleaned)
state.npcStation = true
opened, cleaned = false, false
t.rows[2][1].handlers.onClick()
assert(not opened and not cleaned, 'ownership is rechecked when clicked')
local npc = tableMock()
menu.expandStation(nil,{properties={height=220}},npc,{scvid='npc',wares={}})
assert(npc.rows[2][1].button.active == false)
state.npcStation = nil
Helper.closeMenuAndOpenNewMenu, menu.cleanup = savedOpen, savedCleanup
local node,frame={},{}
menu.expandedNode=node; menu.expandedMenuFrame=frame
menu.onFlowchartNodeCollapsed({},frame)
assert(menu.expandedNode==node)
menu.onFlowchartNodeCollapsed(node,frame)
assert(cleared and menu.expandedNode==nil and menu.expandedMenuFrame==nil)
''')
lua.execute('''
local a={id='a',name='Supplier',wares={ore={name='Ore',output=true,stock=100,limit=200,prodMax=50,prodKnown=true}}}
local b={id='b',name='Consumer',wares={ore={name='Ore',input=true,stock=50,limit=300,consMax=80,consKnown=true}}}
local graph=SCV_Graph.build({a,b})
local w=graph.wareNodes.ore
assert(w.storage.stock==150 and w.storage.capacity==500)
menu.decorateNodes(graph)
assert(w[1].properties.value==150 and w[1].properties.max==500)
assert(w[1].properties.slider1==-1 and w[1].properties.slider2==-1)
assert(w[1].statusText=='-30/h (-38%)' and w[1].color==nil)
menu.graph=graph
local t=tableMock()
menu.expandWare(nil,{properties={height=220}},t,w)
assert(t.rows[1][1].text=='Totals')
assert(t.rows[2][1].text=='Amount 150 / 500')
assert(t.rows[3][1].text=='Production' and t.rows[3][2].text=='+50/h')
assert(t.rows[3][2].props.color=='text_positive')
assert(t.rows[4][1].text=='Consumption' and t.rows[4][2].text=='-80/h')
assert(t.rows[4][2].props.color.g==150)
assert(t.rows[3][1].bgspan==4 and t.rows[4][1].bgspan==4)
assert(t.rows[5][1].text=='Supplied by')
local dedup=SCV_Graph.storageTotals(graph.stationNodes,'ore',{'a','a'},{'a','b'})
assert(dedup.stock==150 and dedup.capacity==500)
b.wares.ore.limit=0; b.wares.ore.capacityUnits=400
graph=SCV_Graph.build({a,b}); w=graph.wareNodes.ore
assert(w.storage.estimated and w.storage.capacity==600)
b.wares.ore.capacityUnits=0; b.wares.ore.stockKnown=false
graph=SCV_Graph.build({a,b}); w=graph.wareNodes.ore
assert(not w.storage.capacityKnown and not w.storage.stockKnown and w.storage.stock==100)
menu.decorateNodes(graph)
assert(w[1].properties.value==0 and w[1].statusText=='-30/h (-38%)')
b.wares.ore.limit=300; b.wares.ore.stockKnown=true; b.wares.ore.consKnown=false
graph=SCV_Graph.build({a,b}); w=graph.wareNodes.ore
menu.decorateNodes(graph)
assert(w[1].properties.value==150 and w[1].properties.max==500 and w[1].statusText=='? /h')
menu.graph=graph
local partial=tableMock()
menu.expandWare(nil,{properties={height=220}},partial,w)
assert(partial.rows[4][2].text=='-80/h + ?')
assert(string.find(partial.rows[4][2].props.mouseOverText,'known subtotal',1,true))
a.wares.ore.stock=900
graph=SCV_Graph.build({a,b}); w=graph.wareNodes.ore
menu.decorateNodes(graph)
assert(w.storage.stock==950 and w[1].properties.value==500 and w[1].properties.max==500)
''')
lua.execute(r'''
local station={id='warn',name='Factory',wares={
    food={name='Terran MRE',input=true,stock=10,limit=100,consMax=60,consKnown=true},
    ore={name='Ore',input=true,stock=0,consKnown=false},
    ice={name='Ice',input=true,stock=0,consKnown=false}}}
local graph=SCV_Graph.build({station})
menu.decorateNodes(graph)
local text=graph.stationNodes.warn[1].properties.mouseOverText
assert(text=='Terran MRE\nLow input buffer\n\nLasts: 10m\nRed threshold: below 15m\n\nInputs without supplier: 3\nSome metrics unavailable\n\nAssumes maximum consumption.\nExcludes deliveries/reservations.',text)
local output={id='out',name='Factory',wares={x={name='Product',output=true,stock=18,limit=50,prodMax=60,prodKnown=true}}}
graph=SCV_Graph.build({output}); menu.decorateNodes(graph)
text=graph.stationNodes.out[1].properties.mouseOverText
assert(not string.find(text,'Output storage risk',1,true))
assert(graph.stationNodes.out.severity=='ok' and graph.stationNodes.out[1].statusText==nil)
assert(graph.stationNodes.out[1].color==nil)
assert(not string.find(text,'Some metrics unavailable',1,true))
station.wares.food.stock=20
graph=SCV_Graph.build({station}); menu.decorateNodes(graph)
assert(string.find(graph.stationNodes.warn[1].properties.mouseOverText,'Orange threshold: below 30m',1,true))
''')
assert all(texts[key].isascii() for key in [3065,3066,*range(3090,3101)])
for source in (root/'ui').glob('*.lua'):
    lua.execute('assert(load(...))', source.read_text(encoding='utf-8'))
lua.execute((root/'test/test_tooltips.lua').read_text(encoding='utf-8'))
lua.execute((root/'test/test_capacity.lua').read_text(encoding='utf-8'))
lua.execute((root/'test/test_processing.lua').read_text(encoding='utf-8'))
lua.execute((root/'ui/scv_store.lua').read_text(encoding='utf-8'))
lua.execute((root/'test/test_warnings.lua').read_text(encoding='utf-8'))
lua.execute((root/'test/test_menu_lifecycle.lua').read_text(encoding='utf-8'))
lua.execute((root/'test/test_refresh.lua').read_text(encoding='utf-8'))
lua.execute('''
-- Exercise the real chunked scanner and menu lifecycle. No graph may be built from
-- a partial scan, including a refresh arriving while the scan is in progress.
local reads, builds, displays = 0, 0, 0
menu.closed = false -- simulate reopening after the preceding cleanup test
local members = {}
SCV_Store = { selected=function() return {} end }
menu.currentMembers = function() return members end
function getElapsedTime() return 100 end
local frame = { addTable=function() return tableMock() end }
SCV_Data.readStation = function(st)
    reads = reads + 1
    if st.id == 'failed' then error('station unavailable') end
    return {id=st.id, name=st.id, wares={}}
end
SCV_Graph.build = function(stations)
    builds = builds + 1
    assert(#stations == #members, 'partial graph published')
    return nil -- stop before native layout/widget creation
end
menu.display = function()
    displays = displays + 1
    menu.displayChain(frame, 0, 0, 500)
end
for _, count in ipairs({1, 4, 5, 12}) do
    members = {}
    for i=1,count do members[i]={id=tostring(i), name=tostring(i)} end
    reads, builds, displays = 0, 0, 0
    menu.markDirty()
    menu.display()
    assert(reads == math.min(count, SCV_Data.SCAN_CHUNK))
    if count > SCV_Data.SCAN_CHUNK then
        assert(builds == 0 and menu.graph == nil and menu.flowchart == nil)
    else
        assert(builds == 1 and menu.scanDone)
        menu.refresh = nil
    end
    for i=1,10 do menu.onUpdate() end
    assert(menu.scanDone and reads == count)
    assert(builds == 1, 'completion must publish exactly once')
end
-- A failed read still completes through the scanner's existing visible stub.
members = {{id='failed', name='failed'}}
menu.markDirty()
menu.display()
assert(menu.scanDone and SCV_Data.cache.failed.failed)
''')
print('Reader, maximum-rate, unknown-data, paired popup, scroll, collapse, atomic graph, live refresh and Lua syntax checks passed.')
