"""Exercise creation/rename callbacks against the real store, outside X4."""
from pathlib import Path
from xml.etree import ElementTree as ET
from lupa import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().texts = lua.table_from({int(t.attrib['id']): t.text for t in ET.parse(root/'t/0001.xml').iter('t')})
lua.execute('''
function DebugError() end
function getElapsedTime() return 10 end
function ReadText(page, id)
    if page == 1001 then return ({[3]='Station', [4]='Stations', [1114]='Rename'})[id] end
    -- X4 strips text comments in parentheses.
    return (texts[id]:gsub('%b()', ''))
end
package.preload.ffi = function() return {C={}} end
Helper = {topLevelMenus={}, registerMenu=function() end,
    scaleX=function(x) return x*1.5 end, scaleY=function(y) return y*1.5 end,
    viewHeight=1080, frameBorder=5, standardTextOffsetx=5,
    headerRowCenteredProperties={}, headerRow1Properties={}}
Color = {}
rows = {}
local function cell()
    return setmetatable({handlers={}}, {__index={
        setColSpan=function(self) return self end,
        createText=function(self, text) self.text=text; return self end,
        createEditBox=function(self, props) self.props=props; return self end,
        createButton=function(self) return self end,
        setText=function(self, text, props) self.text=text; self.textprops=props; return self end,
    }})
end
frame = {addTable=function()
    rows={}
    return {setColWidth=function() end, addRow=function()
        local row={cell(),cell()}; rows[#rows+1]=row; return row
    end}
end}
''')
lua.execute((root/'ui/scv_store.lua').read_text(encoding='utf-8'))
lua.globals().menu = lua.execute((root/'ui/scv_menu.lua').read_text(encoding='utf-8'))
lua.execute('''
menu.markDirty=function() end
SCV_Store.create('First', {{id='10',code='AAA-001'}})
SCV_Store.create('Second', {})
menu.renameIndex=1; menu.nameText='First'; menu.mode='name'
menu.displayNameEntry(frame, 5, 20, 800)
assert(rows[1][1].text == 'Rename')
assert(rows[2][1].props.width == nil, 'name field must inherit cell width')
assert(rows[2][1].textprops.x == 5, 'left-aligned text needs an explicit left inset')
rows[2][1].handlers.onTextChanged(nil, '  Renamed  ')
rows[2][2].handlers.onClick()
assert(SCV_Store.get(1).name == 'Renamed' and SCV_Store.count() == 2)
assert(SCV_Store.get(1).members[1].code == 'AAA-001')
local _, selected = SCV_Store.selected(); assert(selected == 2)
menu.renameIndex=1; menu.nameText='Renamed'; menu.mode='name'
menu.displayNameEntry(frame, 5, 20, 800)
rows[2][1].handlers.onTextChanged(nil, '   ')
rows[2][2].handlers.onClick()
assert(menu.mode == 'name' and SCV_Store.get(1).name == 'Renamed')
rows[2][1].handlers.onTextChanged(nil, 'Cancelled')
rows[3][1].handlers.onClick()
assert(menu.mode == 'chain' and menu.renameIndex == nil)
assert(SCV_Store.get(1).name == 'Renamed')
menu.nameText='New'; menu.pendingStations={}; menu.mode='name'
menu.displayNameEntry(frame, 5, 20, 800)
assert(rows[2][1].text == 'Name the new supply chain. 0 stations will be added to it.')
rows[3][2].handlers.onClick()
assert(SCV_Store.count() == 3 and SCV_Store.get(3).name == 'New')

-- Native widget IDs arrive after display. Focus once, selecting the existing text.
local activations = 0
function ActivateEditBox(id) assert(id == 42); activations = activations + 1 end
menu.mode='name'; menu.nameText='Default'; menu.pendingStations={}
menu.displayNameEntry(frame, 5, 20, 800)
local edit, save, cancel = rows[3][1], rows[3][2], rows[4][1]
assert(edit.props.selectTextOnActivation)
menu.scanDone=false; menu.refresh=1
menu.onUpdate(); assert(activations == 0)
edit.id=42
menu.onUpdate(); menu.onUpdate()
assert(activations == 1 and menu.refresh == 1 and not menu.scanDone)
edit.handlers.onTextChanged(nil, 'First draft')
edit.handlers.onTextChanged(nil, '  Typed name  ')
edit.handlers.onEditBoxDeactivated(nil, 'Default', false, false)
assert(menu.nameText == '  Typed name  ', 'focus loss must not restore old text')
save.handlers.onClick()
edit.handlers.onEditBoxDeactivated(nil, 'Stale', true, true)
save.handlers.onClick()
assert(SCV_Store.count() == 4 and SCV_Store.get(4).name == 'Typed name')

-- Enter submits once, even if the button callback follows it.
menu.mode='name'; menu.nameText='Default'; menu.pendingStations={}
menu.displayNameEntry(frame, 5, 20, 800)
edit, save = rows[3][1], rows[3][2]
edit.handlers.onTextChanged(nil, 'Enter name')
edit.handlers.onEditBoxDeactivated(nil, 'Enter name', true, true)
save.handlers.onClick()
assert(SCV_Store.count() == 5 and SCV_Store.get(5).name == 'Enter name')

-- Old callbacks cannot submit or cancel a newly opened dialog.
menu.mode='name'; menu.nameText='Default'; menu.pendingStations={}
menu.displayNameEntry(frame, 5, 20, 800)
edit.handlers.onTextChanged(nil, 'Stale'); cancel.handlers.onClick()
assert(menu.nameText == 'Default' and menu.nameEntry)
rows[3][1].handlers.onTextChanged(nil, 'Cancelled')
local cancelledEdit = rows[3][1]
rows[4][1].handlers.onClick()
cancelledEdit.handlers.onEditBoxDeactivated(nil, 'Cancelled', true, true)
assert(SCV_Store.count() == 5 and menu.nameEntry == nil)

-- Empty creation still uses the existing fallback; Enter rename trims and persists.
menu.mode='name'; menu.nameText='Default'; menu.pendingStations={}
menu.displayNameEntry(frame, 5, 20, 800)
rows[3][1].handlers.onTextChanged(nil, '')
rows[3][2].handlers.onClick()
assert(SCV_Store.get(6).name == ReadText(90210,1014):format('6'))
menu.mode='name'; menu.renameIndex=1; menu.nameText='Renamed'
menu.displayNameEntry(frame, 5, 20, 800)
edit=rows[2][1]
edit.handlers.onTextChanged(nil, '')
edit.handlers.onEditBoxDeactivated(nil, '', true, true)
assert(menu.nameEntry and SCV_Store.get(1).name == 'Renamed')
edit.handlers.onTextChanged(nil, '  Enter rename  ')
edit.handlers.onEditBoxDeactivated(nil, '  Enter rename  ', true, true)
SCV_Store.load()
assert(SCV_Store.get(1).name == 'Enter rename')
assert(SCV_Store.get(1).members[1].code == 'AAA-001')
local _, after = SCV_Store.selected(); assert(after == 6)
for _, count in ipairs({1, 7, 16}) do
    local noun=string.lower(ReadText(1001, count == 1 and 3 or 4))
    assert(string.format(ReadText(90210,3021),count,noun) ==
        'Added '..count..' '..(count == 1 and 'station' or 'stations')..'.')
end
''')
print('PASS creation, rename, cancel, blank-name rejection, membership, selection and count wording')
