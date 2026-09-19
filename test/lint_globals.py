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
    "getfenv",  # Lua 5.1: native widget environment access
    "assert", "collectgarbage", "dofile", "error", "getmetatable", "ipairs", "load",
    "loadstring", "next", "pairs", "pcall", "print", "rawequal", "rawget", "rawlen",
    "rawset", "require", "select", "setmetatable", "tonumber", "tostring", "type",
    "unpack", "xpcall",
}

# X4 engine globals this mod uses. Every entry was verified against reference/ui/ as a
# GLOBAL (not a C.<name> ffi function) before being added here.
ENGINE_GLOBALS = {
    "GetWidgetSystemSize", "GetLocalMousePosition", "SetMouseOverOverride", "GetCurRealTime",  # native logistics overlay
	"GetSize", "GetFactionData", "GetFlowchartNodeExpandedFrameData",  # helper.lua expand(): native shape padding
    "ConvertStringTo64Bit", "ConvertIDTo64Bit", "ConvertStringToLuaID",
    "DebugError", "ReadText", "TraceBack",
    "GetComponentData", "GetWareData", "GetMacroData", "GetLibraryEntry",
    "GetContainedStationsByOwner", "GetProductionModules", "GetProductionModuleData",
    "GetProcessingModuleData", "IsValidComponent",  # vanilla station overview processing reader
    "GetWorkForceRaceResources",  # helper.getWorkforceConsumption
    # cluster -> station walk, as vanilla does it (menu_encyclopedia.lua:524 and :2727)
    "GetClusters", "GetContainedStations",
    "GetStorageData", "GetTradeList", "GetWareProductionLimit", "CheckSuitableTransportType",
    "IsMacroClass", "IsComponentConstruction", "IsKnownItem",
    "GetNPCBlackboard", "SetNPCBlackboard",
    "GetSubordinates",  # menu_map.getPropertyOwnedFleetDataInternal
    "getElapsedTime",
    "RegisterEvent", "UnregisterEvent", "OpenMenu", "AddUITriggeredEvent", "SetScript", "registerForEvent",
    "unregisterForEvent", "getElement", "CallWidgetEventScripts",
    "GetEditBoxText", "SetSliderCellValue", "ActivateEditBox",  # vanilla menu_map rename focus
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


def strip_literals(src):
    # Tokenize strings/comments together: '--' inside a string is not a comment.
    pattern = (r'--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|'
               r'"(?:\\.|[^"\\])*"|'
               r"'(?:\\.|[^'\\])*'")
    return re.sub(pattern, lambda m: " " + "\n" * m.group().count("\n"), src, flags=re.S)


def exported_names(src):
    # A field function on a local receiver is not an exported global.
    locals_ = set()
    for match in re.finditer(r"\blocal\s+(?:function\s+)?([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)", src):
        locals_.update(part.strip() for part in match.group(1).split(','))
    names = set(re.findall(r"^\s*function\s+([A-Za-z_]\w*)[.(]", src, re.M))
    names.update(re.findall(r"^\s*([A-Za-z_]\w*)\s*=", src, re.M))
    return names - locals_


def analyze(sources):
    stripped = {name: strip_literals(src) for name, src in sources.items()}
    exports = set().union(*(exported_names(src) for src in stripped.values()))
    common = LUA_KEYWORDS | LUA_BUILTINS | ENGINE_GLOBALS | KNOWN_TABLES | exports
    problems = []
    for name, src in stripped.items():
        allowed = common | defined_names(src)
        for match in CALL.finditer(src):
            ident = match.group(1)
            if ident not in allowed:
                problems.append((name, src[:match.start()].count("\n") + 1, ident))
    return problems


def main():
    files = sorted(UI.glob("*.lua"))
    if not files:
        print("no lua files found")
        return 1
    sources = {f.name: f.read_text(encoding="utf-8") for f in files}
    problems = analyze(sources)
    for name, line, ident in problems:
        print(f"  UNDEFINED  {name}:{line} calls '{ident}' — not defined in this file or exported by the addon")
    if problems:
        print(f"{len(problems)} undefined call(s). Check local scope and C.<name> versus engine globals.")
        return 1
    print(f"  OK  {len(files)} files, no calls to undefined names")
    return 0


if __name__ == "__main__":
    sys.exit(main())
