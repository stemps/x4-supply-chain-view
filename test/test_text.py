"""Shared fallback, diagnostic lifetime and real context-action contracts."""
from addon_loader import load_modules
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime


for runtime in (LuaRuntime, LuaJITRuntime):
    lua = runtime(unpack_returned_tuples=True)
    lua.execute('''
        logs={}; reads=0
        function DebugError(message) logs[#logs+1]=message end
        function ReadText(page,id)
            reads=reads+1
            if throwRead then error('unavailable') end
            return returnedText
        end
        package.preload.ffi=function() return {C={IsComponentClass=function() return true end}} end
    ''')
    load_modules(lua, 'scv_text.lua')
    lua.execute('''
        local T=SCV_Text.forPage(90210)
        for i,value in ipairs({false, 42, {}, '', '=ReadText90210-101='}) do
            returnedText=value
            assert(T(100+i)=='SCV#'..(100+i))
        end
        returnedText=nil; assert(T(106)=='SCV#106')
        throwRead=true; assert(T(107)=='SCV#107'); throwRead=false
        assert(T(108,nil,false,0,'100% (West)',nil)=='SCV#108: nil false 0 100% (West) nil')
        assert(T(109,'Energy Chain')=='SCV#109: Energy Chain')
        assert(T(110,'')=='SCV#110: ')
        local count=#logs
        assert(SCV_Text.forPage(90210)(109)=='SCV#109' and #logs==count)
        assert(SCV_Text.forPage(90211)(109)=='SCV#109' and #logs==count+1)
        assert(logs[#logs]:find('page 90211 id 109',1,true))
        assert(logs[#logs]:find('/reloadui does not reload t/ files',1,true))
        returnedText='Recovered %s'; assert(T(109,'value')=='Recovered value')
        returnedText='Changed %s'; assert(T(109,'value')=='Changed value')
        returnedText=nil; assert(T(109)=='SCV#109' and #logs==count+1)
        returnedText='%s'; assert(T(111,'100% (West)')=='100% (West)')
        returnedText='Bad %d'; assert(T(112,'not a number')=='Bad %d')
        returnedText='Bad %'; assert(T(113,'value')=='Bad %')
        returnedText='literal %s'; assert(T(114)=='literal %s')
        assert(#logs==count+1, 'formatting failures retain the original behavior')
        returnedText=nil
        beforeReload=#logs
    ''')
    load_modules(lua, 'scv_text.lua', reload=True)
    lua.execute('''
        assert(SCV_Text.forPage(90210)(109)=='SCV#109' and #logs==beforeReload+1)
        logs={}
        function ReadText(_,id)
            if id==2000 then return '=ReadText90210-2000=' end
            if id==2001 then return nil end
            if id==2002 then return false end
            if id==2003 then error('missing multiple-selection label') end
            return tostring(id)
        end
        function ConvertStringTo64Bit(id) return id end
        SCV_Data={describe=function(id) return {code='code'..id} end}
        actions={}; opened=0
        interact={componentSlot={component='1'},selectedotherobjects={},
            insertInteractionContent=function(_,action) actions[#actions+1]=action end}
        Helper={getMenu=function() return interact end,
            closeMenuAndOpenNewMenu=function() opened=opened+1 end}
    ''')
    load_modules(lua, 'scv_store.lua', 'scv_presentation.lua', 'scv_interact.lua')
    lua.execute('''
        local p=SCV_Presentation.new({textPage=90210})
        local name='Energy 100% (West)'
        assert(p.T(2001,name)=='SCV#2001: '..name)
        assert(#logs==1)
        SCV_Store.create(name,{})
        SCV_Store.create('Other',{})
        SCV_Interact.buildActions()
        assert(actions[1].text=='SCV#2000')
        assert(actions[2].text==p.T(2001,name) and actions[2].active)
        assert(#logs==2, 'context and presentation must share missing-text diagnostics')
        actions[2].script()
        assert(SCV_Store.contains(1,{id='1',code='code1'}) and opened==1)
        assert(#SCV_Store.get(2).members==0, 'label fallback must not change the action target')
        actions={}; SCV_Interact.buildActions()
        assert(actions[2].text=='SCV#2002: SCV#2001: '..name)
        interact.selectedotherobjects={'1','2'}
        actions={}; SCV_Interact.buildActions()
        assert(actions[2].text=='SCV#2003: SCV#2001: '..name..' 1')
        actions[2].script()
        assert(#SCV_Store.get(1).members==2 and #SCV_Store.get(2).members==0)
        local count=#logs
        assert(p.T(2003,'data',2)=='SCV#2003: data 2' and #logs==count)
        for _,action in ipairs(actions) do assert(type(action.text)=='string' and action.text~='') end
    ''')
    print('PASS shared localization and missing-label actions: ' + runtime.__module__)
