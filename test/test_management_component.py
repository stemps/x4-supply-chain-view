"""Isolated management lifecycle contracts, without registering a menu."""
from pathlib import Path
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime

root = Path(__file__).resolve().parents[1]
for runtime in (LuaRuntime, LuaJITRuntime):
    lua = runtime(unpack_returned_tuples=True)
    lua.execute((root / 'ui/scv_management.lua').read_text(encoding='utf-8'))
    lua.execute('''
        local chain = { name='Before', members={} }
        local selected = chain
        local writes, deleted = 0, 0
        SCV_Store = {
            selected=function() return selected,1 end,
            rename=function(index,name)
                if name=='' then return false end
                assert(index==1); writes=writes+1; chain.name=name; return true
            end,
            setShowLogistics=function(value)
                assert(value==false); return true
            end,
            delete=function(index) assert(index==1); deleted=deleted+1 end,
        }
        function getElapsedTime() return 10 end
        function ReadText(_,id) return tostring(id) end
        Color = {}
        local cleared = 0
        Helper = { viewHeight=720,frameBorder=5,standardTextOffsetx=5,
            scaleX=function(v) return v end,scaleY=function(v) return v end,
            clearFrame=function(_,layer) assert(layer==1); cleared=cleared+1 end }
        local graph,refresh,layout = {},{},{}
        local menu = {graph=graph,refreshState=refresh,graphLayout=layout}
        local p = {T=function(id) return tostring(id) end}
        local component = SCV_Management.new(menu,{managementFrameLayer=1},p)
        for name,fn in pairs(component) do menu[name]=fn end
        local dirty = 0
        menu.markDirty=function() dirty=dirty+1 end
        menu.display=function(only)
            assert(only and menu.graph==graph and menu.refreshState==refresh and menu.graphLayout==layout)
        end
        local opened = 0
        menu.openManagement=function(mode) assert(mode=='settings'); opened=opened+1 end
        component.setShowLogistics(false)
        assert(opened==1 and dirty==0)
        SCV_Store.setShowLogistics=function() return false end
        component.setShowLogistics(false)
        assert(opened==1)

        local rows={}
        local function cell()
            local c={handlers={}}
            for _,name in ipairs({'setColSpan','createText','createButton','createEditBox','setText'}) do
                c[name]=function(self) return self end
            end
            return c
        end
        local frame={addTable=function()
            return {setColWidth=function() end,addRow=function()
                local row={cell(),cell()}; rows[#rows+1]=row; return row
            end}
        end}
        menu.renameIndex=1; menu.nameText='Before'; menu.managementMode='rename'
        component.displayNameEntry(frame,0,0,700)
        local old=menu.nameEntry
        assert(old.focusPending==true)
        local oldChange,oldConfirm=rows[2][1].handlers.onTextChanged,rows[2][2].handlers.onClick
        rows={}
        component.displayNameEntry(frame,0,0,700)
        oldChange(nil,'stale'); oldConfirm()
        assert(menu.nameText=='Before' and writes==0)
        rows[2][1].handlers.onTextChanged(nil,'  Renamed  ')
        rows[2][2].handlers.onClick()
        assert(chain.name=='Renamed' and writes==1 and menu.nameEntry==nil)
        assert(menu.managementMode==nil and menu.renameIndex==nil and dirty==0)
        rows[2][2].handlers.onClick()
        assert(writes==1)

        menu.renameIndex=1; menu.nameText='Renamed'; menu.managementMode='rename'; rows={}
        component.displayNameEntry(frame,0,0,700)
        rows[2][1].handlers.onEditBoxDeactivated(nil,'Entered',nil,true)
        assert(chain.name=='Entered' and writes==2)
        menu.managementMode='delete'; menu.managementChain={}
        component.confirmDelete()
        assert(deleted==0)
        menu.managementChain=chain
        component.confirmDelete()
        assert(deleted==1 and dirty==1)

        menu.managementMode='rename'; menu.nameEntry={}; menu.renameIndex=1
        menu.nameText='closing'; menu.managementFrame={}
        component.closeManagement()
        assert(cleared==1 and menu.nameEntry==nil and menu.nameText==nil)
        assert(menu.managementFrame==nil and menu.managementMode==nil)
    ''')
    print(f'Management component contracts passed: {runtime.__module__}')
