"""Session isolation and facade late binding after the data-module extraction."""
from addon_loader import load_modules
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime


def run(runtime):
    lua = runtime(unpack_returned_tuples=True)
    lua.execute('''
    function DebugError(_) end
    C = {GetPlayerID=function() return 'player' end}
    package.preload.ffi=function() return {C=C} end
    function ConvertStringTo64Bit(id) return id end
    function ConvertStringToLuaID(id) return id end
    now=0
    function getElapsedTime() return now end
    function GetComponentData(_,key)
      if key=='idcode' then return 'AAA' end
      if key=='isplayerowned' then return true end
    end
    function IsValidComponent(_) return true end
    events={}; requests={}
    function RegisterEvent(name,fn) events[name]=fn end
    function UnregisterEvent(name,fn) assert(events[name]==fn); events[name]=nil end
    function SetNPCBlackboard(_,_,value) mailbox=value end
    function GetNPCBlackboard(_,_) return mailbox end
    function AddUITriggeredEvent(_,_,params) requests[#requests+1]=params end
    ''')
    load_modules(lua, 'scv_data.lua')
    lua.execute('''
    local original={id='A',id64='A',name='A',code='AAA'}
    local members={original,{id='B',name='B'}}
    local state=SCV_Data.newRefresh(members,0)
    original.name='changed'; members[2]=nil
    assert(state.members[1].name=='A' and #state.members==2)
    local reads=0
    SCV_Data.describe=function(id) return {id=id,code='AAA'} end
    SCV_Data.readStation=function(st) reads=reads+1; return {id=st.id,wares={},generation=1} end
    assert(SCV_Data.refreshStep(state,4)==nil and reads==0)
    assert(SCV_Data.refreshStep(state,5)==nil and reads==1)
    assert(next(SCV_Data.cache)==nil)
    -- Replacing the facade reader after the first tick must affect the next read.
    SCV_Data.readStation=function(st) reads=reads+1; return {id=st.id,wares={},generation=2} end
    local snapshot=SCV_Data.refreshStep(state,5)
    assert(#snapshot==2 and snapshot[1].generation==1 and snapshot[2].generation==2)
    assert(next(SCV_Data.cache)==nil and state.pending==nil and state.cursor==nil)
    local abandoned=SCV_Data.newRefresh({original,{id='C'}},0)
    assert(SCV_Data.refreshStep(abandoned,5)==nil)
    local replacement=SCV_Data.newRefresh({{id='D'}},5)
    assert(SCV_Data.refreshStep(replacement,9)==nil)
    assert(SCV_Data.refreshStep(replacement,10)[1].id=='D')
    assert(#abandoned.pending==1 and next(SCV_Data.cache)==nil)

    local changed=0
    SCV_Data.startLogistics(function() changed=changed+1 end)
    local callback=events.scv_dock_capacity_ready
    local old={docks={}}
    SCV_Data.requestDocks('A',old)
    local oldtoken=requests[#requests][2]
    -- invalidate restarts the session and rejects its predecessor's replies.
    SCV_Data.invalidate()
    assert(events.scv_dock_capacity_ready==callback)
    local fresh={docks={}}
    SCV_Data.requestDocks('A',fresh)
    local token=requests[#requests][2]
    assert(token~=oldtoken)
    mailbox={[oldtoken]={'AAA',1,2,1,2,1,2},[token]={'AAA',0,2,1,2,2,2}}
    events.scv_dock_capacity_ready()
    assert(next(old.docks)==nil and fresh.docks.s.free==0 and changed==1)
    SCV_Data.stopLogistics()
    assert(events.scv_dock_capacity_ready==nil)
    -- A new instance starts with no retained counts from the previous one.
    local independent=SCV_DockSession.new(function() return 5 end)
    independent:start(function() error('unexpected response') end)
    local separate={docks={}}
    independent:request('A',separate)
    assert(next(separate.docks)==nil)
    independent:stop()
    ''')


if __name__ == '__main__':
    for runtime in (LuaRuntime, LuaJITRuntime):
        run(runtime)
    print('Data module session isolation and late binding passed (Lua and LuaJIT)')
