-- Real SCV metric preparation/menu + fake scene primitives. Native verdict still
-- needs X4; this catches integration bugs the isolated synthetic fixture cannot.
Color=setmetatable(nativePalette,{__index=function() return nativePalette.text_normal end})
Helper.convertColorToText=function(c) return string.format("\27#%02x%02x%02x%02x#",255,c.r,c.g,c.b) end
Helper.uiScale=1; Helper.viewWidth=12000; Helper.viewHeight=1000; Helper.borderSize=1
Helper.scaleX=function(x) return x end; Helper.scaleY=Helper.scaleX
Helper.scaleFont=function(_,s) return s end
local env={config={nativePresentationWidth=880,frame={layerOffset=0.2}}}
local elements,clones,writes={},0,0
function env.getElement(name,parent)
    local key=(parent and parent.key or '')..'/'..name
    elements[key]=elements[key] or {key=key,attributes={['position.z']=0}}
    return elements[key]
end
function env.clone(_,name) clones=clones+1; return {key=name,attributes={['position.z']=0}} end
function env.getAttribute(e,k) return e.attributes[k] end
function env.setAttribute(e,k,v) writes=writes+1; e.attributes[k]=v end
function env.goToSlide(e,s) e.slide=s end
function getfenv() return env end
function GetWidgetSystemSize() end
local mx,my,tip
local hits={}
local hitTest=SCV_Overlay.hit
SCV_Overlay.hit=function(metrics,x,y) hits=metrics; return hitTest(metrics,x,y) end
function GetLocalMousePosition() return mx or -100000,my or -100000 end
function SetMouseOverOverride(_,text) tip=text end
function GetCurRealTime() return now end
C.GetTextWidth=function(t,_,size)
    t=t:gsub("\27#[%x]+#",""):gsub("\27X",""):gsub("\27%[[^%]]*%]","XX")
    return #t*size/2
end
local anchors={}
function GetFlowchartNodeExpandedFrameData(id)
    local p=anchors[id]; if p then return p[1],p[2] end
end
function GetSize(id) if id=='chart' then return 12000,1000 end return 310,30 end
local nodes,expected={},0
for i=1,50 do
    local data={docks={s={free=0,total=12345},m={free=1,total=2},l={free=0,total=0}},
        shipsKnown=true,idleKnown=true,drones=999,categories={},traders={s={total=4,idle=3}},
        factionColor={r=0,g=255,b=0,a=100,glow=0}}
    for j=1,(i==1 and 18 or 1) do
        data.categories[j]={rank=j,size='l',purpose='trade',total=j,idle=0,icon='ship_l_transporter_01'}
    end
    if i==2 then data.shipsKnown=false; data.idleKnown=false; data.docks={}; data.drones=nil end
    if i==3 then data.categories={} end
    local id='native'..i
    anchors[id]={500+((i-1)%10)*1100,100+math.floor((i-1)/10)*150}
    nodes[i]={scvkind='station',col=((i-1)%10)+1,logistics=data,
        logisticsRows=menu.logisticsRows(data),[1]={node={id=id},properties={}}}
    expected=expected+6+#data.categories
end
menu.closed=false; menu.mode='chain'; menu.refresh=nil; menu.nativeLogisticsFailed=nil
menu.expandedMenuFrame=nil; menu.managementFrame=nil; menu.statusFrame=nil
menu.graph={nodes=nodes}; menu.metricRevision=1
menu.flowchart={id='chart',properties={x=0,y=0,borderHeight=3},
    hasScrollBar=function() return false end,hasHorizontalScrollBar=function() return false end}
local graph,chart=menu.graph,menu.flowchart
menu.updateLogisticsStrip()
assert(menu.nativeLogistics, 'native access succeeded')
local view=menu.nativeLogistics
local function active()
    local n=0
    for _,cell in ipairs(view.backend.state.cells) do if cell.root.slide=="text" then n=n+1 end end
    return n
end
local draws=0
local draw=view.backend.draw
view.backend.draw=function(self,...) draws=draws+1; return draw(self,...) end
assert(#hits==expected, 'all 50 real strips including >13 categories render')
assert(active()<expected and not view.warned, 'native glows group successfully')
assert(menu.logisticsFrame==nil, 'custom renderer consumes no logistics tables')
local beforeWrites,beforeDraws=writes,draws
menu.updateLogisticsStrip()
assert(writes==beforeWrites and draws==beforeDraws, 'unchanged SCV frame reuses visuals')
-- Bottom-border clipping must use the inner content bounds, also before the
-- last scroll position. Every excluded entry must lose its hover target.
local savedY=anchors.native1[2]
local entryCount=#view.cache[nodes[1]].entries
local stripHeight=menu.logisticsColumnLayouts[nodes[1].col].height
anchors.native1[2]=1000-stripHeight-18
menu.updateLogisticsStrip()
assert(#hits==expected-entryCount, 'strip touching outer chart bottom must not cover border')
anchors.native1[2]=anchors.native1[2]-4
menu.updateLogisticsStrip()
assert(#hits==expected, 'strip ending at inner content boundary remains visible')
Helper.scrollbarWidth=20
chart.hasHorizontalScrollBar=function() return true end
menu.updateLogisticsStrip()
assert(#hits==expected-entryCount, 'horizontal scrollbar is outside strip drawing and hover area')
anchors.native1[2]=anchors.native1[2]-20
menu.updateLogisticsStrip()
assert(#hits==expected, 'strip fits above scrollbar')
chart.hasHorizontalScrollBar=function() return false end
anchors.native1[2]=savedY
menu.updateLogisticsStrip()
local hit=hits[2]
mx=hit.x+1-Helper.viewWidth/2; my=Helper.viewHeight/2-hit.y-1
menu.updateLogisticsStrip(); assert(tip==hit.tip, 'individual tooltip')
SCV_Store.setShowLogistics(false)
local hiddenDraws=draws
menu.updateLogisticsStrip()
assert(active()==0 and tip==nil, 'disabled display clears visuals and hovered tooltip')
menu.updateLogisticsStrip()
assert(draws==hiddenDraws, 'disabled display does not render')
SCV_Store.setShowLogistics(true)
menu.updateLogisticsStrip()
assert(active()>0 and tip==hit.tip, 're-enabled display restores visuals and hover')
mx,my=nil,nil
menu.updateLogisticsStrip(); assert(tip==nil, 'blank pointer clears tooltip')
local capacity=clones
nodes[1].logistics.drones=1000
nodes[1].logisticsRows=menu.logisticsRows(nodes[1].logistics)
menu.metricRevision=2; menu.updateLogisticsStrip()
assert(menu.graph==graph and menu.flowchart==chart and clones==capacity)
local found=false
for _,m in ipairs(hits) do if m.text:find('1000',1,true) then found=true end end
assert(found,'published count visible')
menu.onFlowchartNodeExpanded({}, {properties={x=0,y=0,width=12000,height=1000}}, nil)
assert(active()==0, 'expansion hides synchronously before native panel finalization')
menu.updateLogisticsStrip(); assert(active()==0,'pending native panel hides everything')
menu.expandedMenuFrame.id='panel'
menu.updateLogisticsStrip(); assert(active()==0,'final panel occludes metrics')
menu.expandedMenuFrame=nil; menu.updateLogisticsStrip(); assert(#hits==expected)
anchors.native1=nil; menu.updateLogisticsStrip(); assert(#hits==expected-24,'scroll-out releases first strip')
anchors.native1={500,100}; menu.updateLogisticsStrip(); assert(#hits==expected)
menu.clearLogisticsStrip(); assert(active()==0 and tip==nil)
menu.updateLogisticsStrip(); assert(clones==capacity,'reuse after cleanup')
menu.closed=true; menu.updateLogisticsStrip(); assert(active()==0)
menu.closed=false
-- Native failure hides strips without allocating tables or retrying every frame.
menu.nativeLogistics=nil; env.clone=nil; menu.closed=false
local attempts=0
local newView=SCV_Overlay.newView
SCV_Overlay.newView=function() attempts=attempts+1; return newView() end
local createFrame=Helper.createFrameHandle
Helper.createFrameHandle=function() error("logistics must not allocate a table frame") end
menu.updateLogisticsStrip()
assert(menu.nativeLogisticsFailed and menu.notice==texts[3184])
assert(menu.updateInterval==0 and menu.graph==graph and menu.flowchart==chart)
menu.updateLogisticsStrip(); assert(attempts==1, "failed renderer must not retry each frame")
Helper.createFrameHandle=createFrame
SCV_Overlay.newView=newView
print('PASS native SCV integration: 50 stations, colours, cache, clipping, tooltip and failure without tables')
