"""Export eligibility, native workforce allocation and input-only cycle contracts."""
from pathlib import Path
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime
from addon_loader import load_modules

for runtime in (LuaRuntime, LuaJITRuntime):
    lua = runtime(unpack_returned_tuples=True)
    if runtime is LuaJITRuntime:
        lua.execute('nativeffi = require("ffi"); nativeffi.cdef("typedef uint64_t UniverseID;")')
    run = lua.execute(Path(__file__).with_suffix('.lua').read_text(encoding='utf-8'))
    if runtime is LuaJITRuntime:
        lua.execute('local fake = package.preload.ffi(); fake.cdef=nativeffi.cdef; fake.typeof=nativeffi.typeof; package.loaded.ffi=nil; package.preload.ffi=function() return fake end')
    load_modules(lua, 'scv_reader.lua')
    if runtime is LuaJITRuntime:
        lua.execute('assert(nativeffi.sizeof("WorkforceInfluenceInfo") == 56); assert(nativeffi.offsetof("WorkforceInfluenceInfo", "target") == 48)')
        load_modules(lua, 'scv_reader.lua', reload=True)
    run()
    print(f'PASS significant exports, workforce allocation, accounting and cycles ({runtime.__module__})')
