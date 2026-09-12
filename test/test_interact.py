"""Map action labels and membership callbacks against the real Lua store."""
from pathlib import Path
import re
from xml.etree import ElementTree as ET
from lupa import LuaRuntime

root = Path(__file__).resolve().parents[1]


def read_text(text):
    # Model X4's translator comments and escaped visible parentheses.
    text = text.replace(r'\(', '\x01').replace(r'\)', '\x02')
    text = re.sub(r'\([^()]*\)', '', text)
    return text.replace('\x01', '(').replace('\x02', ')')


for path in sorted((root/'t').glob('*.xml')):
    entries = list(ET.parse(path).iter('t'))
    texts = {int(t.attrib['id']): read_text(t.text or '') for t in entries}
    for tid, count in [(2001, 1), (2002, 1), (2003, 2)]:
        assert sum(t.attrib['id'] == str(tid) for t in entries) == 1
        assert texts[tid].count('%s') == count, (path, tid)
    assert '(+' in texts[2003] and ')' in texts[2003], path
    assert len(texts[2002]) > len('%s '), path
    if path.name == '0001.xml':
        assert texts[2001] == 'Add to "%s"'
        assert texts[2002] == '%s (already in)'
        assert texts[2003] == '%s (+%s)'

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().texts = lua.table_from(texts)
    lua.execute('''
function DebugError(message) error(message) end
function ReadText(_, id) return texts[id] end
function ConvertStringTo64Bit(id) return id end
package.preload.ffi=function() return {C={IsComponentClass=function(id) return id~='ship' end}} end
SCV_Data={describe=function(id) return {code='code'..id} end}
actions={}; opened=0
interact={componentSlot={component='1'},selectedotherobjects={},
    insertInteractionContent=function(_,action) actions[#actions+1]=action end}
Helper={getMenu=function() return interact end,
    closeMenuAndOpenNewMenu=function() opened=opened+1 end}
''')
    lua.execute((root/'ui/scv_store.lua').read_text(encoding='utf-8'))
    lua.execute((root/'ui/scv_interact.lua').read_text(encoding='utf-8'))
    lua.execute('''
-- Include percent signs and parentheses: names are data, never format strings.
local name='Energy 100% (West)'
SCV_Store.create(name,{})
SCV_Interact.buildActions()
local label=string.format(texts[2001],name)
assert(#actions==2 and actions[2].text==label and actions[2].active)
actions[2].script()
assert(SCV_Store.contains(1,{id='1',code='code1'}) and opened==1)
actions={}; SCV_Interact.buildActions()
assert(actions[2].text==string.format(texts[2002],label))
actions[2].script(); assert(#SCV_Store.get(1).members==1)
interact.selectedotherobjects={'1','2','ship'}
actions={}; SCV_Interact.buildActions()
assert(actions[2].text==string.format(texts[2003],label,'1'))
actions[2].script(); assert(#SCV_Store.get(1).members==2)
actions={}; SCV_Interact.buildActions()
assert(actions[2].text==string.format(texts[2002],label))
interact.componentSlot.component='3'; interact.selectedotherobjects={'4'}
actions={}; SCV_Interact.buildActions()
assert(actions[2].text==string.format(texts[2003],label,'2'))
interact.componentSlot.component='ship'; interact.selectedotherobjects={}
actions={}; SCV_Interact.buildActions(); assert(#actions==0)
''')

print('PASS context labels in all languages, visible hints, selection and station membership')
