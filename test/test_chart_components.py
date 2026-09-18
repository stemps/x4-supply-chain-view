"""Chart/native-logistics component ownership and controller dispatch contracts."""
from addon_loader import load_modules
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime


def run(runtime):
    lua = runtime(unpack_returned_tuples=True)
    lua.execute('''
    function DebugError(_) end
    Helper={standardFontSize=10,scaleY=function(x) return x end}
    SCV_Store={getShowLogistics=function() return false end}
    ''')
    load_modules(lua, 'scv_chart.lua', 'scv_logistics_view.lua', provided=(
        'scv_presentation.lua', 'scv_graph.lua', 'scv_data.lua',
        'scv_store.lua', 'scv_overlay_view.lua'))
    lua.execute('''
    local presentation={T=function(id) return tostring(id) end,
      severityColor=function(s) return s end,warningReason=function() return nil end}
    local config={stationNodeWidth=310,nodeOffsetX=20}
    local first,second={},{}
    local a=SCV_Chart.new(first,config,presentation)
    local b=SCV_Chart.new(second,config,presentation)
    local widget={}
    local node={scvkind='station',name='Alpha',unmet={},unsold={},collapsed={},
      wares={},severity='ok',healthKnown=true,[1]={node=widget}}
    local graph={nodes={node}}
    a.decorateNodes(graph)
    assert(graph.nodes[1]==node and node[1].node==widget and node.logisticsRows==nil)
    first.chainPlaceholder={header='waiting',text='partial'}
    local calls=0
    first.drawChainPlaceholder=function(_,_,_,_,header,text)
      calls=calls+1; assert(header=='waiting' and text=='partial')
    end
    a.displayChain({},0,0,100,true)
    assert(calls==1 and second.chainPlaceholder==nil)
    -- Late controller replacement remains the cross-component interception point.
    first.drawChainPlaceholder=function() calls=calls+10 end
    a.displayChain({},0,0,100,true)
    b.displayChain({},0,0,100,true)
    assert(calls==11)

    local hidden,resets=0,0
    first.nativeLogistics={hide=function() hidden=hidden+1 end,
      reset=function() resets=resets+1 end}
    second.nativeLayoutRevision=7
    local view=SCV_LogisticsView.new(first,config,presentation)
    view.updateLogisticsStrip()
    assert(hidden==1 and not first.nativeLogisticsFailed)
    first.nativeLayoutRevision=3; first.nativeLayoutGraph=graph
    view.clearLogisticsStrip()
    assert(resets==1 and first.nativeLayoutRevision==nil and first.nativeLayoutGraph==nil)
    assert(second.nativeLayoutRevision==7)
    -- Failure is latched on this controller only, with one native hide.
    SCV_Store.getShowLogistics=function() return true end
    first.mode='chain'; first.graph=graph
    first.flowchart={id=10,properties={}}
    first.prepareLogisticsColumns=function() error('native layout failure') end
    view.updateLogisticsStrip()
    assert(first.nativeLogisticsFailed and first.nativeLogistics==nil and hidden==2)
    assert(first.notice=='3184' and not second.nativeLogisticsFailed)
    view.updateLogisticsStrip()
    assert(hidden==2)
    ''')


if __name__ == '__main__':
    for runtime in (LuaRuntime, LuaJITRuntime):
        run(runtime)
    print('Chart and logistics component ownership/dispatch passed (Lua and LuaJIT)')
