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
      footnoteMarkers=function() return "" end, footnoteLine=function(key) return key end,
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
    lua.execute('''
    -- Reproduce a compact row using Helper's symmetric node-padding model.
    -- The native renderer counts a visible row only for rowHeight < available.
    Color={}; Helper.borderSize=1; Helper.frameBorder=5
    SCV_Store.selected=function() return {} end
    SCV_Graph={LIMITS={maxCols=20,maxNodes=100,maxEdges=100}}
    for _,scale in ipairs({1,1.48,2}) do
      Helper.scaleY=function(value) return value*scale end
      for _,rows in ipairs({1,2,13}) do
        for _,show in ipairs({true,false}) do
          local stripHeight=39*scale/1.48
          local originalY=(stripHeight/scale+3+9)/2
          local station={scvkind='station',row=rows,col=1,text='Station',predecessors={},
            logisticsRows=show and {{height=stripHeight}} or nil,
            [1]={properties={y=originalY}}}
          local nodes={station}
          for row=1,rows-1 do
            nodes[#nodes+1]={scvkind='station',row=row,col=1,text='Interior',predecessors={},
              logisticsRows=station.logisticsRows,[1]={properties={y=originalY}}}
          end
          local graph={nodes=nodes,wareNodes={ore={}},collapsedWares={},
            droppedStations={},droppedEdges={}}
          local menu={graph=graph,graphLayout={rows=rows,cols=1,junctions={},fits=true},decorateNodes=function() end}
          local component=SCV_Chart.new(menu,{}, {T=function() return 'Legend' end, footnoteLine=function() return 'Legend' end})
          menu.renderFlowchart=component.renderFlowchart
          menu.drawChainLegend=component.drawChainLegend
          local frame={getAvailableHeight=function() return 1800 end}
          local footer={properties={},getFullHeight=function() return 30 end,
            addRow=function() return {{createText=function() end}} end}
          function frame:addTable() return footer end
          function frame:addFlowchart(nrows,_,props)
            local chart={properties=props,nodePropertiesByRow={}}
            function chart:setDefaultNodeProperties() end
            function chart:addNode(row,_,_,properties)
              self.nodePropertiesByRow[row]=properties
              local widget={properties={text={},statustext={}},handlers={}}
              function widget:setText() return self end
              return widget
            end
            function chart:getMaxVisibleHeight() return self.properties.maxVisibleHeight end
            function chart:getVisibleHeight()
              local total=0
              self.rowHeights={}
              for row=1,nrows do
                self.rowHeights[row]=44*scale/1.48+2*self.nodePropertiesByRow[row].y*scale
                total=total+self.rowHeights[row]
              end
              self.rowHeight=self.rowHeights[nrows]
              self.borderHeight=2*(3*scale+Helper.borderSize)
              return math.min(total+self.borderHeight,self:getMaxVisibleHeight())
            end
            return chart
          end
          component.displayChain(frame,18,173,3742,true)
          local chart=menu.flowchart
          local height=chart:getVisibleHeight()
          assert(station[1].properties.y==originalY, 'render padding must not mutate graph records')
          assert(footer.properties.y==173+height+Helper.borderSize)
          if show then
            -- Last visible row ends at the native content boundary, regardless
            -- of scroll position. Its strip must fit in that row's lower half.
            local stripBottom=chart.rowHeight/2+22*scale/1.48+math.ceil(3*scale)+stripHeight
            assert(stripBottom<=chart.rowHeight-1,
              'final station strip must clear the bottom border')
          end
          if rows==1 then
            assert(chart.rowHeight < height-chart.borderHeight, 'native strict fit must count the row')
            if show then
              local stripBottom=height/2+22*scale/1.48+3*scale+stripHeight
              assert(stripBottom<=height-chart.borderHeight/2,
                'complete strip must fit above compact chart border and inner padding')
            end
            chart.properties.maxVisibleHeight=height-10
            assert(chart:getVisibleHeight()==height-10, 'never exceed available frame space')
          end
          for row=1,rows do
            if not show or row<rows then assert(chart.nodePropertiesByRow[row].y==originalY) end
            if show and row<rows then
              assert(chart.rowHeights[row]<chart.rowHeights[rows], 'interior rows are tighter')
              local stripBottom=22*scale/1.48+math.ceil(3*scale)+stripHeight
              local nextTop=(chart.rowHeights[row]+chart.rowHeights[row+1])/2-22*scale/1.48
              assert(stripBottom<nextTop, 'metrics must not overlap the next station')
            end
          end
        end
      end
    end
    ''')


if __name__ == '__main__':
    for runtime in (LuaRuntime, LuaJITRuntime):
        run(runtime)
    print('Chart and logistics component ownership/dispatch passed (Lua and LuaJIT)')
