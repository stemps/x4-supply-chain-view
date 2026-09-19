"""Routed budget regression with mutating layout doubles and local vanilla code."""
import sys
from pathlib import Path
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime
from addon_loader import load_modules

reference = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[3] / 'reference'
helper = reference / 'ui/addons/ego_detailmonitorhelper/helper.lua'
for runtime in (LuaRuntime, LuaJITRuntime):
    lua = runtime(unpack_returned_tuples=True)
    load_modules(lua, 'scv_graph.lua')
    lua.execute('Helper={}; function DebugError(s) error(s) end')
    if helper.exists():
        source = helper.read_text(encoding='utf-8')
        start = source.index('local setupDAGLayoutHelper =')
        end = source.index('-- Cell Formatting', start)
        lua.execute(source[start:end])
    lua.execute(Path(__file__).with_suffix('.lua').read_text(encoding='utf-8'))
    print(f'PASS layout budget ({runtime.__module__}); vanilla helper={helper.exists()}')
