"""Logistics reader, MD mailbox, live display and exact threshold contracts.

The fake engine controls dock availability. Actual reservation semantics must
still be verified in X4; this suite does not pretend to simulate the engine.
"""
from pathlib import Path
from xml.etree import ElementTree as ET
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime

ROOT = Path(__file__).resolve().parents[1]


def run(runtime):
    lua = runtime(unpack_returned_tuples=True)
    texts = {int(t.get('id')): t.text for t in ET.parse(ROOT/'t/0001.xml').iter('t')}
    lua.globals().texts = lua.table_from(texts)
    lua.execute('''
logs={}; now=100; changes=0; events={}; requests={}; mailbox=nil
function DebugError(s) logs[#logs+1]=s end
function ReadText(_,id) return texts[id] or tostring(id) end
function getElapsedTime() return now end
function ConvertIDTo64Bit(id) return id end
function ConvertStringTo64Bit(id) return id end
function ConvertStringToLuaID(id) return id end
world={
 A={code='AAA',owned=true,children={'T','M','F','dead','T'},drones=24},
 B={code='BBB',owned=true,children={},drones=0},
 T={purpose='trade',size='s',orders=0,children={'N'},icon='custom_trade'},
 M={purpose='mine',size='l',orders=1,children={'T'},assignment='trade'},
 N={purpose='mine',size='m',orders=0,children={}},
 F={purpose='fight',size='m',orders=0,children={}},
}
function IsValidComponent(id) return world[id] ~= nil end
function GetComponentData(id,key)
 local w=assert(world[id])
 if key=='idcode' then return w.code end
 if key=='isplayerowned' then return w.owned == true end
 if key=='macro' then return id end
 if key=='owner' then return 'player' end
 if key=='shiptypename' then return (w.size or '')..' '..(w.purpose or '') end
 error('unexpected property '..key)
end
function GetMacroData(id,key)
 local w=world[id]
 if key=='primarypurpose' then return w.purpose end
 if key=='primarypurposeicon' then return w.icon or '' end
 if key=='icon' then return 'macro_icon' end
 error('unexpected macro property '..key)
end
function GetFactionData(owner,key) assert(owner=='player' and key=='color'); return 'faction_green' end
function GetSubordinates(id)
 if brokenChildren==id then error('reader failed') end
 return world[id].children
end
C={}
function C.IsComponentClass(id,class) return class=='ship_'..(world[id].size or '') end
function C.GetNumOrders(id) return world[id].orders end
function C.IsInfoUnlockedForPlayer(_,key)
 assert(key=='units_amount' or key=='units_details')
 return not unitsLocked
end
function C.GetNumStoredUnits(id,cat,virtual)
 assert(cat=='transport' and virtual==false)
 return world[id].drones
end
function C.GetTextWidth(text,_,fontsize)
 local plain=text:gsub(string.char(27)..'%[[^%]]*%]','XX'):gsub('<[^>]+>',''):gsub(string.char(27)..'X','')
 return #plain*7*(fontsize or 16)/16
end
function C.GetTextHeight(text,_,fontsize) local _,n=text:gsub('\\n',''); return (n+1)*fontsize*1.5 end
function C.GetPlayerID() return 'player' end
function RegisterEvent(name,fn) events[name]=fn end
function UnregisterEvent(name,fn) assert(events[name]==fn); events[name]=nil end
function SetNPCBlackboard(player,key,value) assert(player=='player' and key=='$scv_dock_results'); mailbox=value end
function GetNPCBlackboard(player,key) assert(player=='player' and key=='$scv_dock_results'); return mailbox end
function AddUITriggeredEvent(screen,control,params)
 assert(screen=='SCVSupplyChainMenu' and control=='dock_capacity')
 requests[#requests+1]=params
end
package.preload.ffi=function() return {C=C,string=tostring} end
Helper={topLevelMenus={},standardFontSize=9,standardTextHeight=20,headerRow1Properties={},
 registerMenu=function() end,scaleY=function(x) return x end}
Color=setmetatable({}, {__index=function(_,key) return key end})
function Helper.convertColorToText(color) return '<'..color..'>' end
function deliver(entries,preserve)
 mailbox={}
 for key,value in pairs(entries) do
  -- Real MD -> Lua conversion normally removes the dollar from nested keys.
  mailbox[not preserve and key:sub(1,1)=='$' and key:sub(2) or key]=value
 end
 events.scv_dock_capacity_ready()
end
''')
    for name in ['scv_graph.lua', 'scv_data.lua', 'scv_store.lua']:
        lua.execute((ROOT/'ui'/name).read_text(encoding='utf-8'))
    lua.globals().menu = lua.execute((ROOT/'ui/scv_menu.lua').read_text(encoding='utf-8'))
    lua.execute('assert(menu.updateInterval == 0 and menu.toggleLogisticsRenderer == nil)')
    lua.execute('local clock = 0; function GetCurRealTime() clock = clock + 0.25; return clock end')
    lua.execute('''
local data=SCV_Data.readLogistics('A')
assert(data.shipsKnown and data.idleKnown and data.drones==24)
assert(data.traders.s.total==1 and data.traders.s.idle==1 and data.traders.s.icon=='custom_trade')
assert(data.miners.l.total==1 and data.miners.l.idle==0 and data.miners.l.icon=='macro_icon')
assert(data.miners.m.total==1 and data.miners.m.idle==1)
assert(data.categories[35].total==1 and data.categories[35].purpose=='fight')
assert(data.factionColor=='faction_green')
local entries=menu.logisticsEntries(data)
assert(#entries==10, 'dock icon + 3 docks + drones + 4 nonzero ship categories + idle')
assert(entries[6].text:find('macro_icon',1,true) and entries[6].tip:find('L',1,true))
for i=6,9 do assert(entries[i].color=='faction_green' and entries[i].tip:find('Idle:',1,true)) end
assert(#menu.logisticsEntries(SCV_Data.readLogistics('B'))==6, 'zero categories must be absent')
assert(#requests==0, 'closed menu must not request docks')
local totals=SCV_Graph.logisticsTotals(data)
assert(totals.total==3 and totals.idle==2 and totals.severity=='warning')
world.T.orders=nil
local missing=SCV_Data.readLogistics('A')
assert(missing.shipsKnown and not missing.idleKnown and missing.drones==24)
assert(SCV_Graph.logisticsTotals(missing).severity=='ok')
world.T.orders=0
brokenChildren='M'
assert(not SCV_Data.readLogistics('A').shipsKnown)
brokenChildren=nil
world.A.owned=false
local npc=SCV_Data.readLogistics('A')
assert(not npc.shipsKnown and npc.drones==24 and next(npc.docks)==nil)
unitsLocked=true
assert(SCV_Data.readLogistics('A').drones==nil)
unitsLocked=false; world.A.owned=true
local empty=SCV_Data.readLogistics('B')
assert(empty.shipsKnown and SCV_Graph.logisticsTotals(empty).severity=='ok')

-- Strict inclusive boundaries, without rounding or division by zero.
for _,pair in ipairs({{49,100,'ok'},{50,100,'warning'},{74,100,'warning'},
 {75,100,'critical'},{10,21,'ok'},{11,21,'warning'},{15,21,'warning'},
 {16,21,'critical'},{0,0,'ok'},{1,1,'critical'},{4999,10000,'ok'},{7499,10000,'warning'}}) do
 local snapshot={shipsKnown=true,idleKnown=true,traders={m={total=pair[2],idle=pair[1]}}}
 assert(SCV_Graph.logisticsTotals(snapshot).severity==pair[3])
 if pair[1]==7499 then assert(menu.idleText(snapshot):find('74.9%',1,true)) end
 snapshot.idleKnown=false; assert(SCV_Graph.logisticsTotals(snapshot).severity=='ok')
end

SCV_Data.startLogistics(function() changes=changes+1 end)
local a=SCV_Data.readLogistics('A'); local first=requests[#requests][2]
local b=SCV_Data.readLogistics('B'); local second=requests[#requests][2]
-- Coalesced engine events must not lose either result. Includes 0/0 and a
-- completely occupied or reserved class, as reported by native match_dock.
deliver({[first]={'AAA',0,0,0,6,1,3},[second]={'BBB',0,0,0,0,0,0}})
assert(a.docks.m.free==0 and a.docks.m.total==6 and a.docks.l.total==3)
assert(b.docks.s.total==0 and changes==1 and mailbox==nil)
assert(first:sub(1,1)=='$', 'MD string table keys require a dollar prefix')
local retained=SCV_Data.readLogistics('B'); local retainedKey=requests[#requests][2]
deliver({[retainedKey]={'BBB',1,2,0,0,0,0}},true)
assert(retained.docks.s.free==1, 'also accept bridges that preserve the dollar prefix')
local summary=menu.logisticsSummary(a)
assert(summary:find('<text_warning>M 0/6',1,true))
assert(not summary:find('<text_warning>S 0/0',1,true))
assert(summary:find('<text_warning>'..string.char(27)..'[ships_idling_01] 2',1,true))
a.miners.l.idle=1
assert(menu.logisticsSummary(a):find('<text_error>'..string.char(27)..'[ships_idling_01] 3',1,true))
assert(menu.logisticsTooltip(a):find('100.0%',1,true))

-- Out-of-order response from a superseded station refresh.
local old=SCV_Data.readLogistics('A'); local stale=requests[#requests][2]
local fresh=SCV_Data.readLogistics('A'); local current=requests[#requests][2]
assert(fresh.docks.m.total==6, 'keep known berth counts while the next response is pending')
deliver({[stale]={'AAA',1,1,1,1,1,1}})
assert(old.docks.m.total==6 and fresh.docks.m.total==6, 'stale responses must not replace the retained sample')
deliver({[current]={'AAA',1,1,2,2,3,3}})
assert(fresh.docks.m.free==2)
local timeout=SCV_Data.readLogistics('A'); local late=requests[#requests][2]
assert(timeout.docks.m.free==2)
local beforeTimeout=changes
now=now+5; deliver({[late]={'AAA',1,1,1,1,1,1}})
assert(next(timeout.docks)==nil and changes==beforeTimeout+1, 'timeout clears and republishes retained counts')
for _,bad in ipairs({{'WRONG',1,1,1,1,1,1},{'AAA',2,1,0,0,0,0},
 {'AAA',-1,1,0,0,0,0},{'AAA',0.5,1,0,0,0,0},{'AAA',0,0}}) do
 local seed=SCV_Data.readLogistics('A'); local seedToken=requests[#requests][2]
 deliver({[seedToken]={'AAA',1,1,2,2,3,3}})
 local record=SCV_Data.readLogistics('A'); local token=requests[#requests][2]
 assert(record.docks.m.free==2)
 local beforeInvalid=changes
 deliver({[token]=bad}); assert(next(record.docks)==nil and changes==beforeInvalid+1)
end
local seed=SCV_Data.readLogistics('A'); deliver({[requests[#requests][2]]={'AAA',1,1,2,2,3,3}})
local sold=SCV_Data.readLogistics('A'); local token=requests[#requests][2]
assert(sold.docks.m.free==2)
world.A.owned=false; deliver({[token]={'AAA',1,1,1,1,1,1}})
assert(next(sold.docks)==nil); world.A.owned=true
-- Replacing an in-flight request cannot indefinitely extend retained data.
local waiting=SCV_Data.readLogistics('B')
now=now+4
local replacement=SCV_Data.readLogistics('B')
assert(replacement.docks.s.free==1)
now=now+1; SCV_Data.expireDockRequests(now)
assert(next(replacement.docks)==nil)
local seeded=SCV_Data.readLogistics('B'); deliver({[requests[#requests][2]]={'BBB',1,2,0,0,0,0}})
world.B.code='NEW'
assert(next(SCV_Data.readLogistics('B').docks)==nil, 'different station code must not inherit berth counts')
world.B.code='BBB'
local previous=SCV_Data.readLogistics('A'); token=requests[#requests][2]
SCV_Data.invalidate(); deliver({[token]={'AAA',1,1,1,1,1,1}})
assert(next(previous.docks)==nil, 'changed chain cannot consume old replies')
SCV_Data.stopLogistics(); local count=#requests
SCV_Data.readLogistics('A'); assert(#requests==count and next(events)==nil)
SCV_Data.onDockCapacity() -- stale native callback is harmless
SCV_Data.startLogistics(function() changes=changes+1 end)
assert(next(SCV_Data.readLogistics('B').docks)==nil, 'new session has no retained dock counts')
deliver({[token]={'AAA',1,1,1,1,1,1}})
assert(next(previous.docks)==nil, 'save/reopen cannot consume previous session data')

-- Initial graph and publication retain the actual snapshot object, so a valid
-- MD response updates both node and an already-open detail panel in place.
local station={id='A',name='A',wares={},logistics=a}
local graph=SCV_Graph.build({station})
local node=graph.stationNodes.A
assert(node.logistics==a)
SCV_Graph.refreshMetrics(graph,{{id='A',name='A',wares={},logistics=fresh}})
assert(node.logistics==fresh and graph.stationNodes.A==node)

-- Keep actual expanded-panel callbacks alive across publication and MD replies.
local panel={properties={height=300}}
local rows={properties={},entries={}}
function rows:setColWidthPercent() end
function rows:setColWidth() end
function rows:addRow()
 local row={}
 for i=1,4 do
  local cell={handlers={}}; row[i]=cell
  function cell:setColSpan() return self end
  function cell:createText(text,props) self.text=text; self.props=props; return self end
  function cell:createButton() return self end
  function cell:setText(text) self.text=text; return self end
 end
 self.entries[#self.entries+1]=row; return row
end
menu.expandStation(nil,panel,rows,node)
local dockCell
for _,row in ipairs(rows.entries) do
 local label=type(row[1].text)=='function' and row[1].text() or row[1].text
 if label=='Docks M' then dockCell=row[2] end
end
assert(dockCell and dockCell.text()=='2/2')
fresh.docks.m={free=0,total=2}
assert(dockCell.text():find('<text_warning>0/2',1,true))
local outline=node.severity
menu.decorateNodes(graph)
assert(node.severity==outline, 'logistics must not modify ware health')
assert(not node.text:find(string.char(10),1,true))
assert(node[1].properties.width==310 and node[1].properties.y>=20 and node[1].properties.y<28)
assert(not node[1].properties.mouseOverText:find('Docks:',1,true))
for _,row in ipairs(rows.entries) do
 local label=type(row[1].text)=='function' and row[1].text() or row[1].text or ''
 assert(not label:find('Traders',1,true) and not label:find('Miners',1,true) and not label:find('ships_idling',1,true))
end
SCV_Graph.refreshMetrics(graph,{{id='A',name='A',wares={},failed=true}})
assert(node.logistics==nil)
assert(dockCell.text()=='?/?')
assert(not menu.logisticsSummary(nil):find('<text_',1,true))
SCV_Data.stopLogistics()
''')
    lua.execute((ROOT/'test/test_refresh_coverage.lua').read_text(encoding='utf-8'))
    lua.execute((ROOT/'test/test_logistics_overlay.lua').read_text(encoding='utf-8'))
    colors = ET.parse(ROOT.parents[1]/'reference/libraries/colors.xml')
    palette = {}
    for name in ('text_normal', 'text_warning', 'text_error'):
        ref = colors.find(f'.//mapping[@id="{name}"]').get('ref')
        color = colors.find(f'.//color[@id="{ref}"]')
        palette[name] = {k: int(color.get(k)) for k in ('r','g','b')}
        palette[name].update(a=int(color.get('a'))*100/255, glow=float(color.get('glow','0')))
    lua.globals().nativePalette = lua.table_from(palette, recursive=True)
    lua.execute((ROOT/'ui/scv_overlay.lua').read_text(encoding='utf-8'))
    lua.execute((ROOT/'ui/scv_overlay_view.lua').read_text(encoding='utf-8'))
    lua.execute((ROOT/'test/test_native_overlay.lua').read_text(encoding='utf-8'))


for runtime in [LuaRuntime, LuaJITRuntime]:
    run(runtime)

# Assert the XML calls the proven native query, not a docked-ship subtraction.
md = ET.parse(ROOT/'md/scv_logistics.xml')
finds = md.findall('.//find_dockingbay')
assert len(finds) == 2
for find in finds:
    assert find.get('object') == '$Station' and find.get('checkoperational') == 'true'
    filters = find.find('match_dock').attrib
    assert all(filters[key] == 'false' for key in ['storage','hidden','showroom','ventureronly','allowplayeronly'])
    assert filters['trading'] == 'true'
assert finds[1].find('match_dock').get('free') == 'true'
# XSD validates attribute types, not MD expression grammar. Regression for the
# actual engine parse errors: MD uses list.indexof, never Python-style `in`.
values = [el.get('value', '') for el in md.iter()]
assert not any(' in ' in value for value in values)
assert '$FreeDocks.indexof.{$Dock}' in values
assert '$Dock.docksize.indexof.{tag.dock_xl} or $Dock.docksize.indexof.{tag.dock_l}' in values
assert len(md.findall('.//event_ui_triggered')) == 1
assert not md.findall('.//delay')
assert not md.findall('.//set_order')
print('PASS logistics: Lua and LuaJIT readers, thresholds, dock mailbox, lifecycle, graph and native query contract')
