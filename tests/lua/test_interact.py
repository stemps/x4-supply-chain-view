"""Map action labels and membership callbacks against the real Lua store."""
from pathlib import Path
from addon_loader import load_modules
import re
from xml.etree import ElementTree as ET
from lupa import LuaRuntime

root = Path(__file__).resolve().parents[2]


def read_text(text):
    # Model X4's translator comments and escaped visible parentheses.
    text = text.replace(r'\(', '\x01').replace(r'\)', '\x02')
    text = re.sub(r'\([^()]*\)', '', text)
    return text.replace('\x01', '(').replace('\x02', ')')


for path in sorted((root/'src/t').glob('*.xml')):
    entries = list(ET.parse(path).iter('t'))
    texts = {int(t.attrib['id']): read_text(t.text or '') for t in entries}
    for tid, count in [(2001, 1), (2003, 2), (2006, 1), (2007, 2)]:
        assert sum(t.attrib['id'] == str(tid) for t in entries) == 1
        assert texts[tid].count('%s') == count, (path, tid)
    assert '(+' in texts[2003] and ')' in texts[2003], path
    assert '(-' in texts[2007] and ')' in texts[2007], path
    assert 2002 not in texts, (path, 'the inert "(already in)" entry is gone')
    if path.name == '0001.xml':
        assert texts[2001] == 'Add to "%s"'
        assert texts[2003] == '%s (+%s)'
        assert texts[2006] == 'Remove from "%s"'
        assert texts[2007] == '%s (-%s)'

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().texts = lua.table_from(texts)
    lua.execute('''
function DebugError(message) error(message) end
function ReadText(_, id) return texts[id] end
function ConvertStringTo64Bit(id) return id end
package.preload.ffi=function() return {C={IsComponentClass=function(id) return id~='ship' end}} end
SCV_Data={describe=function(id) return {code='code'..id} end}
actions={}; opened=0; pending=nil
interact={componentSlot={component='1'},selectedotherobjects={},
    insertInteractionContent=function(_,action) actions[#actions+1]=action end}
Helper={getMenu=function() return interact end,
    closeMenuAndOpenNewMenu=function() opened=opened+1 end}
''')
    lua.execute((root/'src/ui/scv_store.lua').read_text(encoding='utf-8'))
    load_modules(lua, 'scv_interact.lua')
    lua.execute('''
-- Include percent signs and parentheses: names are data, never format strings.
local name='Energy 100% (West)'
SCV_Store.create(name,{})
SCV_Interact.buildActions()
local label=string.format(texts[2001],name)
local removeLabel=string.format(texts[2006],name)
assert(#actions==2 and actions[2].text==label and actions[2].active)
actions[2].script()
assert(SCV_Store.contains(1,{id='1',code='code1'}) and opened==1)
-- A single station already in the chain gets only Remove.
actions={}; SCV_Interact.buildActions()
assert(#actions==2 and actions[2].text==removeLabel and actions[2].active)
-- Mixed selection: Add for the newcomers and Remove for the members, side by side.
interact.selectedotherobjects={'1','2','ship'}
actions={}; SCV_Interact.buildActions()
assert(#actions==3)
assert(actions[2].text==string.format(texts[2003],label,'1'))
assert(actions[3].text==string.format(texts[2007],removeLabel,'1'))
actions[2].script(); assert(#SCV_Store.get(1).members==2)
actions={}; SCV_Interact.buildActions()
assert(#actions==2 and actions[2].text==string.format(texts[2007],removeLabel,'2'))
interact.componentSlot.component='3'; interact.selectedotherobjects={'4'}
actions={}; SCV_Interact.buildActions()
assert(#actions==2 and actions[2].text==string.format(texts[2003],label,'2'))
-- Remove takes only the members of a mixed selection and reports the count.
interact.componentSlot.component='1'; interact.selectedotherobjects={'3'}
actions={}; SCV_Interact.buildActions()
assert(actions[3].text==string.format(texts[2007],removeLabel,'1'))
local before=opened
actions[3].script()
local p=SCV_Store.takePending()
assert(opened==before+1 and p.mode=='chain' and p.index==1 and p.removed==1)
assert(not SCV_Store.contains(1,{id='1',code='code1'}) and SCV_Store.contains(1,{id='2',code='code2'}))
-- Matching is by code too: after a load the stored id is stale.
SCV_Store.get(1).members[1].id='stale'
interact.componentSlot.component='2'; interact.selectedotherobjects={}
actions={}; SCV_Interact.buildActions()
assert(actions[2].text==removeLabel); actions[2].script()
assert(#SCV_Store.get(1).members==0, 'a stale id is still removed by station code')
interact.componentSlot.component='ship'; interact.selectedotherobjects={}
actions={}; SCV_Interact.buildActions(); assert(#actions==0)
''')

print('PASS context labels in all languages, visible hints, selection and station membership')
