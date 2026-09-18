"""Exercise complete manifest boot/reload without rendering or optional APIs."""
from addon_loader import load_modules, module_order
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime


for runtime in (LuaRuntime, LuaJITRuntime):
    lua = runtime(unpack_returned_tuples=True)
    lua.execute('''
        package.preload.ffi=function() return {C={}} end
        function DebugError() end
        function ReadText(_, id) return tostring(id) end
        registrations=0; events={}
        function RegisterEvent(name, fn) events[name]=fn end
        function UnregisterEvent(name, fn)
            assert(events[name]==fn, 'unregistered a different callback')
            events[name]=nil
        end
        Helper={topLevelMenus={}}
        function Helper.registerMenu(menu)
            registrations=registrations+1
            for _, name in ipairs({'expandStation','expandWare','displayNameEntry',
                'confirmName','displayToolbar','setShowLogistics','decorateNodes',
                'displayChain','renderFlowchart','updateLogisticsStrip','onUpdate',
                'onShowMenu','onCloseElement','onTabScroll','onDockMetrics',
                'onFlowchartNodeExpanded','onFlowchartNodeCollapsed'}) do
                assert(type(menu[name])=='function', 'registered incomplete menu: '..name)
            end
        end
    ''')
    names = module_order()
    load_modules(lua, *names)
    lua.execute('''
        assert(#Menus==1 and registrations==1 and #Helper.topLevelMenus==1)
        registeredMenu=Menus[1]
        assert(SCV_Store.version==6 and SCV_Store.getShowLogistics()==true)
        assert(next(SCV_Data.cache)==nil)
        hidden=0
        SCV_Overlay.active={hide=function() hidden=hidden+1 end}
    ''')
    load_modules(lua, *names, reload=True)
    lua.execute('''
        assert(#Menus==1 and Menus[1]==registeredMenu and registrations==1)
        assert(#Helper.topLevelMenus==1 and hidden==1)
    ''')
    print('PASS complete addon boot/reload: ' + runtime.__module__)
