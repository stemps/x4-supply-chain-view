"""Exercise scv_store.lua's persistence and re-linking outside X4.

Two failures from real play drive these tests:

  * After /reloadui a chain came back with its NAME but no MEMBERS - fixed by the flat
    storage shape. A /reloadui re-runs the lua FILE (fresh locals) while the savedvariable
    global survives, which reload_file() below simulates.
  * After a SAVEGAME LOAD every member was "no longer existing" - the stored runtime ids
    were correct at save time, but the engine hands out new ids on load. Fixed by storing
    each station's code and re-linking by it. reconcile() is tested here against a fake
    world whose ids change, which is exactly what a load does.

Run:  uv run --with lupa python test/test_store.py
"""
import pathlib
import sys

from lupa import LuaRuntime

STORE = pathlib.Path(__file__).resolve().parent.parent / "ui" / "scv_store.lua"
SRC = STORE.read_text(encoding="utf-8")

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("DebugError = function(msg) _G.__lastlog = msg end")

fails = []


def check(label, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + label + (f"   {detail}" if detail else ""))
    if not cond:
        fails.append(label)


def reload_file():
    """Simulate /reloadui: re-run the chunk (fresh locals), keep globals."""
    lua.execute(SRC)
    return lua.globals().SCV_Store


def fresh():
    lua.execute("__SCV_GROUPS = nil")
    return reload_file()


def recs(*pairs):
    """lua list of member records from (id, code) pairs; code may be None"""
    t = lua.table()
    for i, (mid, code) in enumerate(pairs, start=1):
        t[i] = lua.table(id=mid, code=code) if code is not None else lua.table(id=mid)
    return t


def ids(store, idx):
    chain = store.get(idx)
    if chain is None:
        return None
    m = chain.members
    return [m[i].id for i in range(1, len(m) + 1)]


def codes(store, idx):
    m = store.get(idx).members
    return [m[i].code for i in range(1, len(m) + 1)]


def persisted_members(i):
    return lua.globals().__SCV_GROUPS.members[i]


# --- a fake world: id -> station code. A savegame load = a new mapping. ------------------
def make_world(mapping):
    """Returns (describe, lookupCode) lua functions over {id: code}."""
    w = lua.table()
    for k, v in mapping.items():
        w[str(k)] = v
    lua.globals().__world = w
    describe = lua.eval("""function(id)
        local code = __world[tostring(id)]
        if not code then return nil end
        return { id = tostring(id), code = code, name = "St " .. code }
    end""")
    lookup = lua.eval("""function(code)
        for id, c in pairs(__world) do if c == code then return id end end
        return nil
    end""")
    return describe, lookup


print("\n=== v4 storage: each member is id + station code ===")
S = fresh()
S.create("Ore Chain", recs(("506813", "HEA-485"), ("501323", "CXG-006")))
check("members stored as records", ids(S, 1) == ["506813", "501323"], f"got={ids(S, 1)}")
check("  ...with their codes", codes(S, 1) == ["HEA-485", "CXG-006"], f"got={codes(S, 1)}")
check("persisted flat as id|code", persisted_members(1) == "506813|HEA-485,501323|CXG-006",
      f"got={persisted_members(1)!r}")

print("\n=== survives a /reloadui ===")
S = reload_file()
check("ids survive", ids(S, 1) == ["506813", "501323"], f"got={ids(S, 1)}")
check("codes survive", codes(S, 1) == ["HEA-485", "CXG-006"], f"got={codes(S, 1)}")

print("\n=== migration: v3 stored bare ids with no code ===")
lua.execute("""__SCV_GROUPS = { version = 3, selected = 1,
    names = { "Old" }, members = { "506813,501323" } }""")
S = reload_file()
check("v3 ids carried over", ids(S, 1) == ["506813", "501323"], f"got={ids(S, 1)}")
check("  ...with no code (none was ever recorded)", codes(S, 1) == [None, None])
check("rewritten in the v4 shape", persisted_members(1) == "506813|,501323|",
      f"got={persisted_members(1)!r}")

print("\n=== migration: v1/v2 nested form ===")
lua.execute("""__SCV_GROUPS = { version = 2, selected = 1,
    groups = { { name = "Nested", members = { "111", "222" } } } }""")
S = reload_file()
check("nested chains recovered", S.count() == 1 and ids(S, 1) == ["111", "222"])
check("  ...old key gone after rewrite", lua.globals().__SCV_GROUPS.groups is None)

print("\n=== THE REPORTED BUG: a savegame load renumbers every station ===")
S = fresh()
S.create("Shipyard Feed", recs(("506813", "HEA-485"), ("501323", "CXG-006"),
                               ("413143", "ZUB-121")))
S = reload_file()                         # the save is written, the game reloads
# after the load the same three stations exist, under completely new ids
describe, lookup = make_world({"900001": "HEA-485", "900002": "CXG-006", "900003": "ZUB-121"})
live, missing = S.reconcile(1, describe, lookup)
check("every member re-found by its code", len(live) == 3 and missing == 0,
      f"live={len(live)} missing={missing}")
check("stored ids updated to the new ones", sorted(ids(S, 1)) == ["900001", "900002", "900003"],
      f"got={ids(S, 1)}")
check("  ...and saved", "900001|HEA-485" in persisted_members(1), f"got={persisted_members(1)!r}")
S = reload_file()
check("the fresh ids survive the next reload", sorted(ids(S, 1)) == ["900001", "900002", "900003"])

print("\n=== a stale id now pointing at a DIFFERENT station must not be trusted ===")
S = fresh()
S.create("Guard", recs(("100", "AAA-111")))
# after a load, id 100 exists - but it is some other station now
describe, lookup = make_world({"100": "ZZZ-999", "555": "AAA-111"})
live, missing = S.reconcile(1, describe, lookup)
check("the impostor at the old id is rejected", live[1].code == "AAA-111",
      f"got code={live[1].code}")
check("  ...and the real station re-found under its new id", ids(S, 1) == ["555"],
      f"got={ids(S, 1)}")

print("\n=== fast path: nothing changed, nothing rewritten ===")
S = fresh()
S.create("Stable", recs(("7", "SEV-007")))
before = persisted_members(1)
describe, lookup = make_world({"7": "SEV-007"})
calls = lua.eval("{ n = 0 }")
lua.globals().__calls = calls
counting_lookup = lua.eval("function(c) __calls.n = __calls.n + 1; return nil end")
live, missing = S.reconcile(1, describe, counting_lookup)
check("resolves by id", len(live) == 1 and missing == 0)
check("  ...without a single code lookup", calls.n == 0, f"lookups={calls.n}")
check("  ...and without rewriting storage", persisted_members(1) == before)

print("\n=== genuinely gone stations are counted, not deleted ===")
S = fresh()
S.create("Mixed", recs(("1", "ONE-001"), ("2", "TWO-002")))
describe, lookup = make_world({"1": "ONE-001"})          # TWO-002 was destroyed
live, missing = S.reconcile(1, describe, lookup)
check("one live, one missing", len(live) == 1 and missing == 1,
      f"live={len(live)} missing={missing}")
check("the missing member is KEPT (a lookup miss is not proof it is gone)",
      ids(S, 1) == ["1", "2"], f"got={ids(S, 1)}")

print("\n=== a stale and a fresh record for the same station collapse ===")
S = fresh()
S.create("Dupe", recs(("10", "DUP-010")))
# after a load the old record is stale; a right-click adds the same station under its new id
S.addStations(1, recs(("20", "DUP-010")))
check("addStations already refuses it by CODE", ids(S, 1) == ["10"], f"got={ids(S, 1)}")
lua.execute("""__SCV_GROUPS.members[1] = "10|DUP-010,20|DUP-010" """)   # force the dupe
S = reload_file()
describe, lookup = make_world({"20": "DUP-010"})
live, missing = S.reconcile(1, describe, lookup)
check("  ...and reconcile collapses a forced duplicate", len(live) == 1 and ids(S, 1) == ["20"],
      f"live={len(live)} ids={ids(S, 1)}")

print("\n=== legacy code-less members are upgraded when their id still resolves ===")
lua.execute("""__SCV_GROUPS = { version = 3, selected = 1, names = { "L" },
    members = { "42,43" } }""")
S = reload_file()
describe, lookup = make_world({"42": "LEG-042"})
live, missing = S.reconcile(1, describe, lookup)
check("resolvable legacy member upgraded with its code", codes(S, 1)[0] == "LEG-042",
      f"got={codes(S, 1)}")
check("unresolvable legacy member counted missing", missing == 1, f"missing={missing}")

print("\n=== contains() matches by code as well as id ===")
S = fresh()
S.create("C", recs(("10", "CON-010")))
check("same id", S.contains(1, lua.table(id="10", code="CON-010")))
check("new id, same code (stale store after a load)", S.contains(1, lua.table(id="99", code="CON-010")))
check("different station", not S.contains(1, lua.table(id="99", code="OTH-001")))
check("bare id still accepted", S.contains(1, "10"))

print("\n=== mutations persist ===")
S = fresh()
S.create("M", recs(("1", "AAA-001")))
S.addStations(1, recs(("2", "BBB-002")))
S = reload_file()
check("added station survived reload", ids(S, 1) == ["1", "2"])
S.removeStation(1, "1")
S = reload_file()
check("removal survived reload", ids(S, 1) == ["2"])
S.create("Second", recs(("9", "NIN-009")))
S.select(1)
S = reload_file()
_, idx = S.selected()
check("second chain and selection survived", S.count() == 2 and idx == 1, f"idx={idx}")
S.delete(1)
S = reload_file()
check("deletion survived reload", S.count() == 1 and S.get(1).name == "Second")

print("\n=== separators cannot leak into stored codes ===")
S = fresh()
S.create("Sep", recs(("1", "A,B|C")))
check("separator characters stripped from a code", codes(S, 1) == ["ABC"], f"got={codes(S, 1)}")
S = reload_file()
check("  ...so the record still round-trips", ids(S, 1) == ["1"] and codes(S, 1) == ["ABC"])

print("\n=== hostile input does not crash the store ===")
for bad in ["__SCV_GROUPS = 42", "__SCV_GROUPS = {}",
            "__SCV_GROUPS = { names = 'nope', members = 7 }",
            "__SCV_GROUPS = { names = {'A'}, members = {} }",
            "__SCV_GROUPS = { names = {'A'}, members = {'|||,,,|'} }"]:
    lua.execute(bad)
    try:
        S = reload_file()
        S.count()
    except Exception as exc:  # noqa: BLE001
        check(f"survives {bad}", False, str(exc))
        continue
    check(f"survives {bad}", True)

print("\n=== rename preserves membership and selection across reload ===")
S = fresh()
S.create("First", recs(("10", "AAA-001")))
S.create("Second", recs(("20", "BBB-002")))
check("rename trims surrounding whitespace", S.rename(1, "  Renamed chain  "))
check("blank name rejected", not S.rename(1, " \t "))
check("missing chain rejected", not S.rename(99, "Missing"))
S = reload_file()
check("renamed name persisted", S.get(1).name == "Renamed chain")
check("members unchanged", ids(S, 1) == ["10"] and codes(S, 1) == ["AAA-001"])
check("selection and other chain unchanged", S.selected()[1] == 2 and S.get(2).name == "Second")

print("\n=== per-station ware warning exclusions ===")
S = fresh()
S.create("First", recs(("10", "AAA-001")))
S.create("Second", recs(("10", "AAA-001")))
check("old storage defaults to enabled", not S.isWarningIgnored("AAA-001", "ore"))
check("ignore stored", S.setWarningIgnored("AAA-001", "ore", True))
check("other station independent", not S.isWarningIgnored("BBB-002", "ore"))
check("other ware independent", not S.isWarningIgnored("AAA-001", "food"))
S.removeStation(1, "10")
S.delete(2)
S = reload_file()
check("exclusion survives reload and membership removal", S.isWarningIgnored("AAA-001", "ore"))
S.addStations(1, recs(("999", "AAA-001")))
check("new runtime id retains preference", S.isWarningIgnored(S.get(1).members[1].code, "ore"))
S.setWarningIgnored("AAA-001", "ore", False)
S = reload_file()
check("restoring warnings survives reload", not S.isWarningIgnored("AAA-001", "ore"))
check("missing durable code rejected", not S.setWarningIgnored(None, "ore", True))
check("separator injection rejected", not S.setWarningIgnored("AAA|001", "ore", True))
lua.execute('__SCV_GROUPS = {version=4, names={}, members={}, ignoredWarnings={false, "bad", "AAA-001|ore", "A|B|C"}}')
S = reload_file()
check("malformed entries safely ignored", S.isWarningIgnored("AAA-001", "ore") and not S.isWarningIgnored("A", "B"))

print("\n" + "=" * 52)
if fails:
    print(f"{len(fails)} FAILED:")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("All checks passed.")
