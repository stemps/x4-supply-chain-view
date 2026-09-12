"""Exercise the optional consumer against a fake API and native menu boundary."""
from pathlib import Path
from lupa import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
clock = 10
startmenu = false
listeners, registrations, opens = {}, {}, {}
Menus = {}
package.preload.ffi = function()
    return { cdef=function() end, C={IsStartmenu=function() return startmenu end} }
end
function RegisterEvent(event, fn)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], fn)
end
function UnregisterEvent(event, fn)
    for i, value in ipairs(listeners[event]) do
        if value == fn then table.remove(listeners[event], i); return end
    end
    error('unregistered callback')
end
function ready()
    for _, fn in ipairs(listeners['HotkeyApi.Register_Request']) do fn() end
end
function ReadText(page, id)
    assert(page == 90210 and id == 1001)
    return 'Open Supply Chain View'
end
function getElapsedTime() return clock end
function OpenMenu(name, params, back)
    assert(name == 'SCVSupplyChainMenu' and params[1] == 0 and params[2] == 0)
    assert(back == nil)
    table.insert(opens, 'gameplay')
end
Helper = {closeMenuAndOpenNewMenu=function(menu, name, params)
    assert(menu.name == 'MapMenu' and name == 'SCVSupplyChainMenu')
    assert(params[1] == 0 and params[2] == 0)
    table.insert(opens, 'map')
end}
''')
source = (root / 'ui/scv_hotkey.lua').read_text(encoding='utf-8')
lua.execute(source)
lua.execute('''
ready() -- absent API is inert, including an unexpected readiness event
assert(#registrations == 0 and #opens == 0)
HotkeyApi = {} -- incomplete/unavailable API
ready()
HotkeyApi.RegisterAction = function(request) table.insert(registrations, request) end
ready() -- API appears later
local request = registrations[1]
assert(request.id == 'scv_open_supply_chain' and request.name == 'Open Supply Chain View')
assert(request.area == 'map;pilot;fps' and request.isObjectRequired == false)
assert(request.defaultKey == nil and request.key == nil)
request.actionLua()
assert(#opens == 1 and opens[1] == 'gameplay')
request.actionLua() -- suppress duplicate callbacks before the menu becomes shown
assert(#opens == 1)
clock = clock + 1
Menus = {{name='SCVSupplyChainMenu', shown=true}}
request.actionLua(); assert(#opens == 1)
Menus = {{name='OptionsMenu', shown=true}}
request.actionLua(); assert(#opens == 1)
Menus = {{name='ChatWindow', shown=true}, {name='MapMenu', shown=true}}
request.actionLua(); assert(#opens == 1)
Menus = {{name='MapMenu', shown=true, noupdate=true}}
request.actionLua(); assert(#opens == 1)
Menus[1].noupdate = false; Menus[1].contextMenuMode = 'searchfield'
request.actionLua(); assert(#opens == 1)
Menus[1].contextMenuMode = nil
request.actionLua(); assert(#opens == 2 and opens[2] == 'map')
clock = clock + 1; Menus = {}; startmenu = true
request.actionLua(); assert(#opens == 2)
startmenu = false
ready() -- same stable identity restores registration after API registry reset
assert(#registrations == 2 and registrations[2].id == request.id)
''')
lua.execute(source)  # simulate a reused Lua environment
lua.execute('''
assert(#listeners['HotkeyApi.Register_Request'] == 1)
ready()
assert(#registrations == 3)
assert(registrations[3].actionLua == SCV_Hotkey.open)
HotkeyApi = nil
ready(); assert(#registrations == 3)
''')
print('PASS optional API, late readiness, reload, localization, menu opening and editing guards')
