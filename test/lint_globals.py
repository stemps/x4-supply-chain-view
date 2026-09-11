"""Catch calls to names that do not exist.

Lua's load() checks SYNTAX ONLY. A call to a function that was never defined is a runtime
error, and in this mod every station read is wrapped in pcall, so such a bug does not crash
- it silently degrades every station to an empty stub and the diagram just says "no trade
links". That exact failure has happened twice:

  * GetContainerWareConsumption called as a bare global (it is FFI-only)
  * normalizeWareList and readBuildResources dropped in a rewrite, then still called

Both were invisible to the syntax check. This linter closes that gap.

ENGINE_GLOBALS is deliberately a curated allowlist rather than something inferred: adding an
engine API to it should be a conscious act, because "is this a global or is it C.<name>?" is
precisely the question that got answered wrong before.

Run:  uv run python test/lint_globals.py
"""
import pathlib
import re
import sys

UI = pathlib.Path(__file__).resolve().parent.parent / "ui"

LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
    "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}

LUA_BUILTINS = {
    "assert", "collectgarbage", "dofile", "error", "getmetatable", "ipairs", "load",
    "loadstring", "next", "pairs", "pcall", "print", "rawequal", "rawget", "rawlen",
    "rawset", "require", "select", "setmetatable", "tonumber", "tostring", "type",
    "unpack", "xpcall",
}

# X4 engine globals this mod uses. Every entry was verified against reference/ui/ as a
# GLOBAL (not a C.<name> ffi function) before being added here.
ENGINE_GLOBALS = {
	"GetFlowchartNodeExpandedFrameData",  # helper.lua expand(): native shape padding
    "ConvertStringTo64Bit", "ConvertIDTo64Bit", "ConvertStringToLuaID",
    "DebugError", "ReadText", "TraceBack",
    "GetComponentData", "GetWareData", "GetMacroData", "GetLibraryEntry",
    "GetContainedStationsByOwner", "GetProductionModules", "GetProductionModuleData",
    # cluster -> station walk, as vanilla does it (menu_encyclopedia.lua:524 and :2727)
    "GetClusters", "GetContainedStations",
    "GetStorageData", "GetTradeList", "GetWareProductionLimit", "CheckSuitableTransportType",
    "IsMacroClass", "IsComponentConstruction", "IsKnownItem",
    "GetNPCBlackboard", "SetNPCBlackboard",
    "getElapsedTime", "GetCurRealTime",
    "RegisterEvent", "AddUITriggeredEvent", "SetScript", "registerForEvent",
    "unregisterForEvent", "getElement", "CallWidgetEventScripts",
    "GetEditBoxText", "SetSliderCellValue",
    # sn_mod_support_apis, probed with type() before use
    "Register_OnLoad_Init", "Register_Require_Response",
}

# Tables reached as Name.field / Name:method — those call sites are dot/colon prefixed and
# never matched by the call regex, but bare references still need to resolve.
KNOWN_TABLES = {"Helper", "Color", "ColorText", "Menus", "ffi", "C", "math", "string", "table", "os", "io"}

DEF_PATTERNS = [
    re.compile(r"^\s*local\s+function\s+([A-Za-z_]\w*)", re.M),
    re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\(", re.M),
    re.compile(r"^\s*function\s+([A-Za-z_]\w*)[.:]", re.M),
    re.compile(r"^\s*local\s+([A-Za-z_]\w*)\s*=", re.M),
    re.compile(r"^\s*([A-Za-z_]\w*)\s*=\s*\{", re.M),          # SCV_Graph = {}
    re.compile(r"^\s*local\s+([A-Za-z_][\w,\s]*)=", re.M),      # local a, b = ...
]

# `function name(a, b)`, `function a.b(x)`, `function a:b(x)`, or anonymous `function (x)`.
PARAM_DECL = re.compile(r"\bfunction\s+[A-Za-z_][\w.:]*\s*\(([^)\n]*)\)|\bfunction\s*\(([^)\n]*)\)")

# A bare call: NAME( not preceded by . or : or a word char
CALL = re.compile(r"(?<![\w.:])([A-Za-z_]\w*)\s*\(")


def defined_names(src):
    names = set()
    for pat in DEF_PATTERNS:
        for m in pat.finditer(src):
            for part in m.group(1).split(","):
                part = part.strip()
                if part:
                    names.add(part)
    # local function bodies can be recursive; also treat assigned table fields as defined
    for m in re.finditer(r"^\s*function\s+([A-Za-z_]\w*)\.([A-Za-z_]\w*)", src, re.M):
        names.add(m.group(1))
    # Function PARAMETERS are defined names too: a callback passed in and then called
    # (e.g. `predicate(w)`) is not an undefined global.
    #
    # The declaration shape is matched exactly and never across a newline. An earlier
    # `function[^(]*\(` let `[^(]*` run from the word "function" in a COMMENT to some
    # unrelated "(" lines later, swallowing the real declaration and missing its parameters.
    for m in PARAM_DECL.finditer(src):
        params = m.group(1) if m.group(1) is not None else m.group(2)
        for part in params.split(","):
            part = part.strip()
            if part and part != "...":
                names.add(part)
    return names


files = sorted(UI.glob("*.lua"))
if not files:
    print("no lua files found")
    sys.exit(1)

# Globals published by any file in the mod are visible to all of them (that is how the
# ui.xml load order works), so collect them across the whole set first.
cross_file = set()
sources = {}
for f in files:
    src = f.read_text(encoding="utf-8")
    sources[f] = src
    cross_file |= defined_names(src)

allowed_base = LUA_KEYWORDS | LUA_BUILTINS | ENGINE_GLOBALS | KNOWN_TABLES | cross_file

problems = []
for f in files:
    src = sources[f]
    # strip comments and strings so their contents cannot look like calls
    stripped = re.sub(r"--\[\[.*?\]\]", " ", src, flags=re.S)
    stripped = re.sub(r"--[^\n]*", " ", stripped)
    stripped = re.sub(r'"(?:\\.|[^"\\])*"', '""', stripped)
    stripped = re.sub(r"'(?:\\.|[^'\\])*'", "''", stripped)

    for m in CALL.finditer(stripped):
        name = m.group(1)
        if name in allowed_base:
            continue
        line = stripped[: m.start()].count("\n") + 1
        problems.append((f.name, line, name))

for name, line, ident in problems:
    print(f"  UNDEFINED  {name}:{line}  calls '{ident}' — not defined in the mod and not a "
          f"known engine global")

if problems:
    print(f"\n{len(problems)} undefined call(s). Either the name is misspelled, the helper was "
          f"dropped, or it is an ffi function that must be called as C.<name>.")
    print("If it IS a verified engine global, add it to ENGINE_GLOBALS in this file.")
    sys.exit(1)

print(f"  OK  {len(files)} files, no calls to undefined names "
      f"({len(cross_file)} names defined in-mod)")
