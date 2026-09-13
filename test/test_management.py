"""Toolbar and management-frame contracts using the real Lua menu and store."""
from pathlib import Path
from xml.etree import ElementTree as ET
from lupa import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().texts = lua.table_from({int(t.attrib['id']): t.text for t in ET.parse(root/'t/0001.xml').iter('t')})
lua.execute('''
function DebugError() end
function GetComponentData(_, key) return key == 'isplayerowned' end
now=10
function getElapsedTime() return now end
function ReadText(page,id) return page == 90210 and texts[id] or tostring(id) end
package.preload.ffi=function() return {C={}} end
Color=setmetatable({}, {__index=function(_,key) return key end})
frames={}; invalidations=0; builds=0; closed=0; refreshes=0
local function value(v) return type(v)=='function' and v() or v end
Helper={topLevelMenus={}, registerMenu=function() end, viewWidth=1280, viewHeight=720,
    frameBorder=5, borderSize=2, sidebarWidth=30, standardTextHeight=16,
    standardButtonHeight=26, standardTextOffsetx=5,
    headerRowCenteredProperties={}, headerRow1Properties={},
    scaleX=function(x) return x*1.5 end, scaleY=function(x) return x*1.5 end,
    clearFrame=function(_,layer) frames[layer]=nil end,
    clearDataForRefresh=function() end, closeMenu=function() closed=closed+1 end,
    createTopLevelTab=function() return 45 end}
function Helper.sortNameAndObjectID(a,b)
    if a.name==b.name then return a.objectid<b.objectid end
    return a.name<b.name
end
function Helper.createFrameHandle(_, props)
    local frame={properties=props,tables={}}
    function frame:setBackground() end
    function frame:display() frames[props.layer]=self end
    function frame:update() self.updates=(self.updates or 0)+1 end
    function frame:getUsedHeight()
        local h=0; for _,t in ipairs(self.tables) do h=math.max(h,(t.properties.y or 0)+t:getVisibleHeight()) end
        return h
    end
    function frame:addTable(n, p)
        local t={properties=p,rows={},widths={}}
        function t:setColWidth(i,w) self.widths[i]=w end
        function t:getFullHeight()
            local height=0
            for _,row in ipairs(self.rows) do
                local rowheight=39
                for _,cell in ipairs(row) do
                    if cell.textprops and cell.textprops.wordwrap and type(cell.text)=='string' then
                        rowheight=math.max(rowheight,math.ceil(#cell.text*8/self.properties.width)*24)
                    end
                end
                height=height+rowheight
            end
            return height
        end
        function t:getVisibleHeight() return math.min(self:getFullHeight(),self.properties.maxVisibleHeight or 10000) end
        function t:addRow(_, rowprops)
            local row={properties=rowprops}
            for i=1,n do
                local c={handlers={},span=1}
                function c:setColSpan(span) self.span=span; return self end
                function c:createText(text,pr) self.text=text; self.textprops=pr; return self end
                function c:createButton(pr) self.properties=pr or {}; return self end
                function c:createEditBox(pr) self.properties=pr; return self end
                function c:createDropDown(options,pr) self.options=options; self.properties=pr; return self end
                function c:setTextProperties(pr) self.textprops=pr; return self end
                function c:setText(text,pr) self.text=text; self.textprops=pr; return self end
                function c:setIcon(icon,pr) self.icon=icon; self.iconprops=pr; return self end
                function c:getWidth()
                    if t.widths[i] then return t.widths[i] end
                    local fixed=0; local count=0
                    for _,w in pairs(t.widths) do fixed=fixed+w; count=count+1 end
                    return (p.width-fixed-(n-1)*2)/(n-count)
                end
                function c:getHeight() return 39 end
                row[i]=c
            end
            self.rows[#self.rows+1]=row; return row
        end
        self.tables[#self.tables+1]=t; return t
    end
    return frame
end
SCV_Data={invalidate=function() invalidations=invalidations+1 end,
    describe=function(id) if id=='missing' then return nil end
        return {id=id,id64=id,code='code'..id,name='Station '..id} end,
    lookupCode=function() end,
    scanGroup=function() return {},true end,
    refreshStep=function() refreshes=refreshes+1 end}
''')
lua.execute((root/'ui/scv_store.lua').read_text(encoding='utf-8'))
lua.globals().menu = lua.execute((root/'ui/scv_menu.lua').read_text(encoding='utf-8'))
lua.execute('''
-- Replace only graph rendering: real display, toolbar and overlay paths run below.
local nativeDisplayChain=menu.displayChain
function menu.displayChain(_,x,y,width,reuse)
    graphRect={x=x,y=y,width=width}
    if reuse then return end
    builds=builds+1
    menu.currentMembers()
    menu.graph={stationNodes={}}; menu.flowchart={}; menu.refreshState={}; menu.scanDone=true
end
menu.mode='chain'; menu.display()
local function toolbar() return frames[4].tables[1].rows[1] end
local row=toolbar()
for _,i in ipairs({1,2,3,4,5}) do assert(row[i].properties.active==false) end
row[1].handlers.onClick(); row[3].handlers.onClick()
assert(SCV_Store.count()==0)
assert(row[2].options[1].id=='0')
assert(graphRect.x==Helper.frameBorder)
assert(graphRect.width==1280-45-5-5-2, 'graph uses all available width')
assert(frames[4].properties.width==graphRect.width/2, 'toolbar matches LSO half-width proportions')
assert(frames[4].properties.x==graphRect.x+graphRect.width/4, 'toolbar is centered')
assert(frames[4].tables[1].widths[1]==frames[4].properties.height, 'navigation buttons are square')
assert(menu.toolbarGeometry.anchorX>frames[4].properties.x and
    menu.toolbarGeometry.anchorX<frames[4].properties.x+frames[4].properties.width)

SCV_Store.create('A very long chain name '..string.rep('abc ',40),{{id='1',code='code1'}})
menu.display(); row=toolbar()
assert(not row[1].properties.active and not row[3].properties.active)
local singleBuilds=builds
row[1].handlers.onClick(); row[3].handlers.onClick()
assert(select(2,SCV_Store.selected())==1 and builds==singleBuilds)
assert(row[2].properties.mouseOverText==SCV_Store.get(1).name)
SCV_Store.create('Chain 2',{})
menu.display()
for _,button in ipairs({1,3}) do
    for _,expected in ipairs({1,2}) do
        assert(toolbar()[button].properties.active)
        toolbar()[button].handlers.onClick()
        assert(select(2,SCV_Store.selected())==expected)
        menu.display()
    end
end
for i=3,8 do SCV_Store.create('Chain '..i,{}) end
SCV_Store.select(1); menu.display(); row=toolbar()
assert(#row[2].options==8 and row[2].options[8].text=='Chain 8')
assert(row[1].properties.active and row[3].properties.active)

local graph,flow,refresh,before=menu.graph,menu.flowchart,menu.refreshState,builds
menu.expandedNode={collapse=function() collapsed=true end}
row[4].handlers.onClick()
assert(collapsed and menu.expandedNode==nil and menu.managementMode=='stations')
assert(menu.graph==graph and menu.flowchart==flow and menu.refreshState==refresh and builds==before)
local p=frames[1].properties
assert(p.x>=5 and p.x+p.width<=1275 and p.y+p.height<=715)
menu.onUpdate(); assert(refreshes==1 and frames[1].updates>0)
menu.onCloseElement('back',1)
assert(not frames[1] and closed==0 and menu.graph==graph)
menu.toggleManagement('stations'); menu.toggleManagement('stations'); assert(not frames[1])

menu.openManagement('actions')
frames[1].tables[1].rows[2][1].handlers.onClick()
assert(menu.managementMode=='rename')
local edit=frames[1].tables[1].rows[2]
edit[1].handlers.onEditBoxDeactivated(nil,' Renamed ',true); edit[2].handlers.onClick()
assert(SCV_Store.get(1).name=='Renamed' and menu.graph==graph and builds==before)
assert(toolbar()[2].options[1].text=='Renamed')
menu.openManagement('rename')
edit=frames[1].tables[1].rows[2]
menu.scanDone=false; menu.refresh=1
menu.onUpdate()
assert(menu.managementMode=='rename' and frames[1].tables[1].rows[2]==edit and builds==before)
menu.scanDone=true; menu.refresh=nil
edit[1].handlers.onEditBoxDeactivated(nil,'   ',true); edit[2].handlers.onClick()
assert(menu.managementMode=='rename' and SCV_Store.get(1).name=='Renamed')
menu.onCloseElement('back',1); assert(menu.renameIndex==nil and closed==0)

-- Status is on the canvas, warning rows first, independent of management.
menu.notice='Added 7 stations.'; menu.missingMembers=2
menu.graph.structureChanged=true; menu.graph.refreshFailed=true; menu.graph.lockedCount=3
menu.updateStatusStrip()
assert(#toolbar()==5 and frames[3])
local status=frames[3].tables[1]
assert(#status.rows==5 and status.rows[1][1].text:find('could not be found',1,true))
assert(status.rows[5][1].text=='Added 7 stations.')
assert(status.rows[1][1].textprops.color=='text_warning')
assert(status.rows[5][1].textprops.color=='text_positive')
assert(frames[3].properties.height<=status.properties.maxVisibleHeight)
assert(menu.graph==graph and menu.refreshState==refresh and builds==before)
assert(graphRect.y>=frames[3].properties.y+frames[3].properties.height)
local nativeFrame=menu.frame
menu.graph.lockedCount=4; menu.updateStatusStrip()
assert(menu.frame==nativeFrame, 'same height leaves graph widgets alone')
now=15.9; menu.updateStatusStrip(); assert(menu.notice)
now=16; menu.updateStatusStrip(); assert(menu.notice==nil and #frames[3].tables[1].rows==4)
menu.graph.structureChanged=nil; menu.graph.refreshFailed=nil; menu.graph.lockedCount=0
menu.missingMembers=1; menu.updateStatusStrip()
assert(frames[3].tables[1].rows[1][1].text=='1 station could not be found and is not shown.')
menu.missingMembers=0; menu.updateStatusStrip(); assert(not frames[3] and menu.statusHeight==0)
assert(menu.graph==graph and menu.refreshState==refresh and builds==before)
menu.openManagement('rename')
local renameFrame=frames[1]
menu.nameText='Unsaved draft'; menu.notice='Those stations were already in this supply chain.'
now=30; menu.updateStatusStrip(); assert(frames[1]==renameFrame and menu.nameText=='Unsaved draft')
assert(menu.noticeUntil==36)
now=36; menu.updateStatusStrip(); assert(not frames[3] and frames[1]==renameFrame and menu.nameText=='Unsaved draft')
menu.closeManagement()
menu.notice=string.rep('Long translated feedback ',100); menu.updateStatusStrip()
assert(frames[3].tables[1]:getFullHeight()>frames[3].properties.height)
assert(frames[3].properties.height==frames[3].tables[1].properties.maxVisibleHeight)
menu.notice=nil; menu.noticeUntil=nil; menu.updateStatusStrip()
menu.openManagement('stations')
assert(#frames[1].tables[1].rows==3, 'no duplicate status block')

-- Remove a member, rebuild once, and restore the panel. No chain deletion occurs.
local rows=frames[1].tables[1].rows
rows[#rows][4].handlers.onClick(); assert(menu.managementMode=='stations' and menu.refreshState==nil)
menu.display(); assert(menu.managementMode=='stations' and #SCV_Store.get(1).members==0)
menu.closeManagement()
toolbar()[2].handlers.onDropDownConfirmed(nil,'8')
assert(select(2,SCV_Store.selected())==8 and menu.refreshState==nil)
menu.display(); row=toolbar(); assert(row[1].properties.active and row[3].properties.active)
menu.openManagement('stations')
row[3].handlers.onClick()
assert(select(2,SCV_Store.selected())==1, 'next wraps from last to first')
assert(menu.managementMode==nil and menu.refreshState==nil)
menu.display()
toolbar()[1].handlers.onClick()
assert(select(2,SCV_Store.selected())==8, 'previous wraps from first to last')
menu.display()
toolbar()[1].handlers.onClick(); assert(select(2,SCV_Store.selected())==7)
menu.display()
toolbar()[3].handlers.onClick(); assert(select(2,SCV_Store.selected())==8)
menu.display()
toolbar()[1].handlers.onClick(); assert(select(2,SCV_Store.selected())==7)
menu.display()

menu.openManagement('delete'); assert(SCV_Store.count()==8)
assert(frames[1].tables[1].rows[2][1].text:find('Chain 7',1,true))
frames[1].tables[1].rows[4][1].handlers.onClick(); assert(SCV_Store.count()==8)
menu.openManagement('delete'); frames[1].tables[1].rows[3][1].handlers.onClick()
assert(SCV_Store.count()==7 and menu.managementMode==nil)
menu.display()

-- A large station list scrolls inside the overlay; square icons fill buttons.
local entries={}; for i=1,100 do entries[i]={id=tostring(i),code='code'..i} end
SCV_Store.create('Large',entries); menu.display(); menu.openManagement('stations')
local t=frames[1].tables[1]
assert(#t.rows==102 and t:getVisibleHeight()<=t.properties.maxVisibleHeight)
local icon=t.rows[3][2].iconprops
assert(icon.width==39 and icon.height==39 and icon.x==3 and icon.y==0 and icon.scaling==false)
before=builds; menu.closeManagement(); assert(builds==before)
menu.onCloseElement('back',5); assert(closed==1)

-- The real graph renderer reuses cached layout and scan state, even with no links.
SCV_Store.select(1)
local cache={nodes={},wareNodes={}}
menu.graph=cache; menu.graphLayout={rows=0,cols=0,junctions={}}
local cursor={}; menu.refreshState=cursor
local oldScan=SCV_Data.scanGroup
SCV_Data.scanGroup=function() error('status resize must not scan') end
SCV_Graph={LIMITS={maxCols=100,maxNodes=100,maxEdges=100}}
nativeDisplayChain(Helper.createFrameHandle(menu,{layer=5}),5,100,1000,true)
assert(menu.graph==cache and menu.refreshState==cursor)
menu.graph=nil; menu.chainPlaceholder={header='Loading'}
nativeDisplayChain(Helper.createFrameHandle(menu,{layer=5}),5,100,1000,true)
assert(menu.graph==nil and menu.refreshState==cursor, 'loading placeholder does not scan')
SCV_Data.scanGroup=oldScan

-- The creation screen also survives display cleanup with its pending name intact.
menu.mode='name'; menu.nameText='New chain'; menu.pendingStations={}
menu.display()
assert(menu.nameText=='New chain' and frames[5].tables[1].rows[3][1].text=='New chain')
''')

# Every translation has the new confirmation and exactly one chain-name placeholder.
for path in (root/'t').glob('*.xml'):
    for tid in ['2020', '3022', '3025']:
        entries = [t for t in ET.parse(path).iter('t') if t.attrib['id']==tid]
        assert len(entries)==1 and entries[0].text.count('%s')==1, (path, tid)
print('PASS toolbar navigation, overlays, rename/delete/remove, graph identity, warnings, bounds and localization')
