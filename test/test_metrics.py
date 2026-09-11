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
assert(w.balance == 2 and w.netRate == 2400000 and w.demandRate == 2400000)
assert(w.worstCover == 0.05) -- idle consumer still needs full-rate stock coverage
consumer.wares.energycells.consKnown=false
local partial=SCV_Graph.build({producer,consumer}).wareNodes.energycells
assert(partial.balance == nil and partial.netRate == nil and partial.demandCap == 2400000)
menu.decorateNodes(SCV_Graph.build({producer,consumer})) -- nil net must not crash rendering
consumer.wares.energycells.consKnown=true
consumer.wares.energycells.consMax=0
assert(SCV_Graph.build({producer,consumer}).wareNodes.energycells.balanceUnknown == 'zero-demand')

-- Record actual widget calls to compare both popup entry points.
function tableMock()
    local t={properties={},rows={}}
    function t:setColWidthPercent() end
    function t:addRow(key)
        local r={key=key}; self.rows[#self.rows+1]=r
        for i=1,2 do
            local c={handlers={}}; r[i]=c
            function c:setColSpan(n) self.span=n; return self end
            function c:createText(text, props) self.text=text; self.props=props; return self end
            function c:createStatusBar(props) self.bar=props; return self end
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
    assert(a.rows[i+4][1].props.height == 6 and b.rows[j+4][1].props.height == 6)
    assert(a.rows[i][1].props.mouseOverText and b.rows[j][1].props.mouseOverText)
    local input = stationID == 'B'
    local data = graph.stationNodes[stationID].wares.energycells
    if data.health.severity ~= 'ok' then
        assert(string.find(a.rows[i][1].props.mouseOverText,'warning:',1,true))
        assert(string.find(b.rows[j][1].props.mouseOverText,'warning:',1,true))
    end
    assert(a.rows[i+2][2].props.color == (not input and 'text_positive' or 'text_inactive'))
    assert(a.rows[i][1].props.wordwrap and b.rows[j][1].props.wordwrap)
    assert(a.properties.maxVisibleHeight==220 and b.properties.maxVisibleHeight==220)
    return a.rows[i+2][1].text,a.rows[i+2][2].text
end
consumer.wares.energycells.consMax=2400000
local stock,rate=compareEntry(false,'A')
assert(stock == 'Stock 120.0k' and rate == '+4.8M/h',stock..rate)
local _, inputRate=compareEntry(true,'B')
assert(inputRate == '-2.4M/h')
consumer.wares.energycells.consKnown=false
assert(select(2,compareEntry(true,'B')) == '? /h')

-- Output can have little stock but limited headroom measured in production hours.
local output={output=true,stock=3300,limit=18333,prodMax=28200,prodKnown=true}
output.health=SCV_Graph.wareHealth(output)
assert(output.health.severity=='critical' and output.health.reason=='backedup')
assert(math.abs(output.health.tofull-(18333-3300)/28200)<1e-9)
local m=SCV_Graph.detailMetrics(output,false)
assert(math.abs(m.stockHours-3300/28200)<1e-9 and math.abs(m.capacityHours-18333/28200)<1e-9)
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
assert(selectable==61 and t.properties.maxVisibleHeight==220)
local node,frame={},{}
menu.expandedNode=node; menu.expandedMenuFrame=frame
menu.onFlowchartNodeCollapsed({},frame)
assert(menu.expandedNode==node)
menu.onFlowchartNodeCollapsed(node,frame)
assert(cleared and menu.expandedNode==nil and menu.expandedMenuFrame==nil)
''')
for source in (root/'ui').glob('*.lua'):
    lua.execute('assert(load(...))', source.read_text(encoding='utf-8'))
print('Reader, maximum-rate, unknown-data, paired popup, scroll, collapse and Lua syntax checks passed.')
