"""Exercise scv_graph.lua outside X4. This is the payoff for keeping the model free of game
API calls: cycle breaking, budget degradation and the linking rule get tested without a
load-save cycle.

Run:  uv run --with lupa python test/test_graph.py
"""
import sys
from lupa import LuaRuntime

MOD = r"C:\Users\simon\projects\play\x4-claude-toolkit\dev\supply_chain_view\ui\scv_graph.lua"

lua = LuaRuntime(unpack_returned_tuples=True)
with open(MOD, encoding="utf-8") as fh:
    lua.execute(fh.read())

G = lua.globals().SCV_Graph
fails = []


def check(label, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + label + (f"   {detail}" if detail else ""))
    if not cond:
        fails.append(label)


def station(sid, name, wares):
    """wares: {ware: dict(output=, input=, stock=, limit=, production=, consumption=,
                          transport=, inbound=)}"""
    t = lua.table()
    for ware, w in wares.items():
        t[ware] = lua.table(
            name=ware,
            transport=w.get("transport", "container"),
            stock=w.get("stock", 0),
            limit=w.get("limit", 1000),
            production=w.get("production", 0),
            consumption=w.get("consumption", 0),
            output=w.get("output", False),
            input=w.get("input", False),
            inbound=w.get("inbound", False),
            prodMax=w.get("prodMax", w.get("production", 0)),
            consMax=w.get("consMax", w.get("consumption", 0)),
        )
    return lua.table(id=sid, name=name, wares=t)


def to_list(t):
    return [] if t is None else [t[i] for i in range(1, len(t) + 1)]


def key(n):
    """lupa returns a fresh wrapper per access, so Python identity is useless here."""
    return f"{n.scvkind}:{n.scvid if n.scvkind == 'station' else n.scvware}"


def is_acyclic(graph):
    """Independent check: the surviving edge set must topologically sort."""
    nodes = to_list(graph.nodes)
    indeg = {key(n): 0 for n in nodes}
    succ = {key(n): [] for n in nodes}
    for e in to_list(graph.edges):
        succ[key(e["from"])].append(key(e["to"]))
        indeg[key(e["to"])] += 1
    queue = [key(n) for n in nodes if indeg[key(n)] == 0]
    seen = 0
    while queue:
        n = queue.pop()
        seen += 1
        for m in succ[n]:
            indeg[m] -= 1
            if indeg[m] == 0:
                queue.append(m)
    return seen == len(nodes)


print("\n=== the linking rule: output of one, input of another ===")
stations = lua.table(
    station("hub", "Mining Hub", {
        # sells ore, produces nothing — the case manufacturing-only detection missed
        "ore": dict(output=True, stock=4000, limit=10000, transport="solid")}),
    station("fac", "Refinery", {
        "ore": dict(input=True, stock=50, limit=5000, consumption=300, transport="solid"),
        "hullparts": dict(output=True, stock=900, limit=1000, production=100)}),
    station("yard", "Shipyard", {
        # buys hull parts through its build queue, consumes nothing
        "hullparts": dict(input=True, stock=10, limit=20000)}),
)
g = G.build(stations, lua.table())
check("graph built", g is not None)
check("3 stations + 2 crossing wares = 5 nodes", g.counts.nodes == 5, f"got {g.counts.nodes}")
check("4 edges", g.counts.edges == 4, f"got {g.counts.edges}")
check("ore linked (seller -> buyer)", g.wareNodes["ore"] is not None)
check("hullparts linked", g.wareNodes["hullparts"] is not None)
check("hub is ore's supplier", "hub" in to_list(g.wareNodes["ore"].producers))
check("yard takes hullparts", "yard" in to_list(g.wareNodes["hullparts"].consumers))

print("\n=== a ware needs BOTH ends inside the chain ===")
stations = lua.table(
    station("a", "Seller", {"widgets": dict(output=True, stock=100, production=10)}),
    station("b", "Other", {"gadgets": dict(input=True, stock=10, consumption=5)}),
)
g = G.build(stations, lua.table())
check("no ware node when offers do not meet", next(iter(to_list(g.nodes) or []), None) is not None
      and g.wareNodes["widgets"] is None and g.wareNodes["gadgets"] is None)
check("seller reports its output as untaken", "widgets" in to_list(g.stationNodes["a"].unsold))
check("buyer reports its input as unsupplied", "gadgets" in to_list(g.stationNodes["b"].unmet))
check("no edges at all", g.counts.edges == 0, f"got {g.counts.edges}")

print("\n=== internal intermediates are excluded upstream ===")
# The data layer strips a ware the station both makes and eats, so the model never sees it
# flagged. Assert the model honours the flags rather than re-deriving from rates.
stations = lua.table(
    station("f1", "Factory", {
        # produces AND consumes: data layer sets neither output nor input
        "wafers": dict(output=False, input=False, production=100, consumption=100, stock=500),
        "chips": dict(output=True, production=20, stock=800, limit=1000)}),
    station("f2", "Assembler", {
        "chips": dict(input=True, consumption=20, stock=40, limit=1000),
        "wafers": dict(input=True, consumption=10, stock=5, limit=100)}),
)
g = G.build(stations, lua.table())
check("internal intermediate gets no node even though f2 wants it",
      g.wareNodes["wafers"] is None)
check("f2 reports wafers as unsupplied", "wafers" in to_list(g.stationNodes["f2"].unmet))
check("the real product still links", g.wareNodes["chips"] is not None)

print("\n=== chain-wide ware aggregates (the numbers the tooltip shows) ===")
# Two suppliers holding stock, two consumers drawing it down. The old code reported ONE
# station's figures, which is how "offered 0/h, stock 0" appeared for a ware whose
# suppliers were full: "offered" read a hub's PRODUCTION (zero) and "stock" read the
# starving consumer.
stations = lua.table(
    station("hubA", "Hub A", {"silicon": dict(output=True, stock=8000, limit=10000,
                                              production=0, transport="solid")}),
    station("hubB", "Hub B", {"silicon": dict(output=True, stock=4000, limit=10000,
                                              production=50, transport="solid")}),
    station("f1", "Factory 1", {"silicon": dict(input=True, stock=20, limit=5000,
                                                consumption=300, transport="solid")}),
    station("f2", "Factory 2", {"silicon": dict(input=True, stock=10, limit=5000,
                                                consumption=200, transport="solid")}),
)
g = G.build(stations, lua.table())
w = g.wareNodes["silicon"]
check("supply stock summed over SUPPLIERS", w.supplyStock == 12000, f"got={w.supplyStock}")
check("supply rate summed over suppliers", w.supplyRate == 50, f"got={w.supplyRate}")
check("demand stock summed over CONSUMERS", w.demandStock == 30, f"got={w.demandStock}")
check("demand rate summed over consumers", w.demandRate == 500, f"got={w.demandRate}")
check("unmeasured mining throughput makes net unknown", w.netRate is None, f"got={w.netRate}")
check("cover is consumer stock over consumer draw",
      abs(w.coverHours - 30 / 500) < 1e-9, f"got={w.coverHours}")
check("severity from the consumer that runs dry first", w.severity == "critical")
check("a supplier that holds stock but produces nothing still counts as supply",
      w.supplyStock > 0 and w.supplyRate == 50)

print("\n=== no consumption rate: cover undefined, not zero ===")
stations = lua.table(
    station("fac", "Factory", {"hullparts": dict(output=True, stock=900, limit=1000,
                                                 production=100)}),
    station("yard", "Shipyard", {"hullparts": dict(input=True, stock=10, limit=20000,
                                                   consumption=0)}),
)
g = G.build(stations, lua.table())
w = g.wareNodes["hullparts"]
check("cover is nil when nothing consumes at a rate", w.coverHours is None)
check("  ...severity stays ok rather than fabricating urgency", w.severity == "ok")
check("  ...consumer capacity available for the stock fallback bar",
      w.demandLimit == 20000, f"got={w.demandLimit}")
check("  ...net is unknown when demand is unknown", w.netRate is None)

print("\n=== unknown limit must not fake a backed-up ware ===")
h = G.wareHealth(lua.table(stock=4000, limit=0, prodMax=50, consMax=0, output=True))
check("unknown limit -> no time-to-full", h.tofull is None)
check("  ...so severity is ok, not critical", h.severity == "ok", f"got={h.severity}")
h = G.wareHealth(lua.table(stock=990, limit=1000, prodMax=50, consMax=0, output=True))
check("a KNOWN limit still detects backing up",
      h.reason == "backedup" and h.tofull is not None, f"tofull={h.tofull}")


print("\n=== health: time, not fill ===")
h = G.wareHealth(lua.table(stock=100, limit=1000, prodMax=0, consMax=200, input=True))
check("input with 0.5h cover -> critical", h.severity == "critical", f"hours={h.hours:.2f}")
check("  ...role is input", h.role == "input")
h = G.wareHealth(lua.table(stock=500, limit=1000, prodMax=0, consMax=200, input=True))
check("input with 2.5h cover -> warning", h.severity == "warning", f"hours={h.hours:.2f}")
h = G.wareHealth(lua.table(stock=980, limit=1000, prodMax=100, consMax=0, output=True))
check("output 20 from full at 100/h -> critical (backed up)",
      h.severity == "critical" and h.reason == "backedup", f"hours={h.hours:.2f}")
h = G.wareHealth(lua.table(stock=10, limit=1000, prodMax=0, consMax=0))
check("idle ware never flagged", h.severity == "ok" and h.role == "idle")
check("  ...and no divide-by-zero", h.hours is None)
h = G.wareHealth(lua.table(stock=1, limit=10, prodMax=5, consMax=100, output=True, input=True))
check("both-ends ware judged on the worse side", h.severity == "critical" and h.role == "both")

print("\n=== station severity is the worst of its wares ===")
stations = lua.table(
    station("s", "Mixed", {
        "fine": dict(output=True, stock=10, limit=1000, production=1),
        "dire": dict(input=True, stock=1, limit=1000, consumption=500)}),
    station("t", "Sink", {"fine": dict(input=True, stock=500, limit=1000, consumption=1)}),
)
g = G.build(stations, lua.table())
check("station takes its worst ware's severity", g.stationNodes["s"].severity == "critical")
check("  ...and names it", g.stationNodes["s"].worstWare == "dire")

print("\n=== cycle breaking ===")
stations = lua.table(
    station("s1", "Alpha", {"a": dict(output=True, production=50, stock=100),
                            "b": dict(input=True, consumption=50, stock=100)}),
    station("s2", "Beta", {"b": dict(output=True, production=50, stock=100),
                           "a": dict(input=True, consumption=50, stock=100)}),
)
g = G.build(stations, lua.table())
check("cyclic chain still builds", g is not None)
check("an edge was dropped to break it", len(to_list(g.droppedEdges)) >= 1,
      f"dropped={len(to_list(g.droppedEdges))}")
check("surviving graph topologically sorts (truly acyclic)", is_acyclic(g))

stations = lua.table(
    station("s1", "SelfLoop", {"a": dict(output=True, input=True, production=50,
                                         consumption=50, stock=100)}),
    station("s2", "Other", {"a": dict(input=True, consumption=10, stock=100)}),
)
g = G.build(stations, lua.table())
check("a station that is both ends of one ware does not hang", g is not None)
check("  ...and stays acyclic", is_acyclic(g))

print("\n=== budget degradation ===")
tbl = []
for i in range(20):
    tbl.append(station(f"s{i}", f"Station {i}", {
        "energycells": dict(output=True, production=500, stock=100) if i == 0
        else dict(input=True, consumption=50, stock=100),
        f"w{i}": dict(output=True, production=10, stock=100),
        f"w{(i + 1) % 20}": dict(input=True, consumption=10, stock=100),
    }))
g = G.build(lua.table(*tbl),
            lua.table(limits=lua.table(maxNodes=100, maxEdges=25, maxCols=30)))
check("over-budget chain still returns a graph", g is not None)
check("respects maxEdges", g.counts.edges <= 25, f"edges={g.counts.edges}")
check("reports what it gave up",
      len(to_list(g.collapsedWares)) > 0 or len(to_list(g.droppedStations)) > 0,
      f"collapsed={to_list(g.collapsedWares)} dropped={len(to_list(g.droppedStations))}")
check("still acyclic after budgeting", is_acyclic(g))

print("\n=== predecessors handed to the layout ===")
stations = lua.table(
    station("p", "Producer", {"gas": dict(output=True, production=10, stock=100,
                                          transport="liquid")}),
    station("c", "Consumer", {"gas": dict(input=True, consumption=10, stock=100,
                                          transport="liquid")}),
)
g = G.build(stations, lua.table())
w = g.wareNodes["gas"]
check("ware node has the producer as predecessor", w.predecessors is not None)
check("consumer has the ware as predecessor", g.stationNodes["c"].predecessors is not None)
check("liquid gets slot rank 2", w.predecessors[g.stationNodes["p"]] == 2,
      f"got {w.predecessors[g.stationNodes['p']]}")
check("solid gets slot rank 3", G.slotRank("solid") == 3)
check("unknown transport falls back to 1", G.slotRank("nonsense") == 1)

print("\n=== theoretical module rates (LSO formula) ===")


def recipe(*products):
    """products: (ware, amount, cycle_seconds, [(res_ware, res_amount), ...])"""
    t = lua.table()
    for i, (ware, amount, cycle, res) in enumerate(products, start=1):
        rt = lua.table()
        for j, (rw, ra) in enumerate(res, start=1):
            rt[j] = lua.table(ware=rw, amount=ra)
        t[i] = lua.table(ware=ware, amount=amount, cycle=cycle, resources=rt)
    return t


# single product: 60 wafers per 300 s -> 720/h; consumes 90 silicon per cycle -> 1080/h
prod, cons = G.moduleRates(recipe(("wafers", 60, 300, [("silicon", 90), ("energy", 60)])))
check("single product: amount * 3600 / cycle", abs(prod["wafers"] - 720) < 1e-9,
      f"got={prod['wafers']}")
check("  ...resource on the same denominator", abs(cons["silicon"] - 1080) < 1e-9,
      f"got={cons['silicon']}")
check("  ...every resource is counted", abs(cons["energy"] - 720) < 1e-9, f"got={cons['energy']}")

# THE TRAP: a module with two products cycles through BOTH, so each rate is over the whole
# queue (300 + 600 = 900 s), not over its own cycle. Own-cycle would give 720 and 360.
prod, cons = G.moduleRates(recipe(("a", 60, 300, [("x", 30)]), ("b", 60, 600, [("x", 30)])))
check("multi-product: rate is over the WHOLE queue, not the product's own cycle",
      abs(prod["a"] - 240) < 1e-9 and abs(prod["b"] - 240) < 1e-9,
      f"a={prod['a']} b={prod['b']}")
check("  ...a resource used by both products sums over the queue",
      abs(cons["x"] - 240) < 1e-9, f"got={cons['x']}")

prod, cons = G.moduleRates(None)
check("no recipe -> no rates, no crash", len(list(prod.keys())) == 0)
prod, cons = G.moduleRates(recipe(("z", 10, 0, [])))
check("zero cycle -> no rates rather than a divide by zero", len(list(prod.keys())) == 0)

print("\n=== reservation bar (vanilla trade-bar semantics) ===")
b = G.reservationBar(lua.table(stock=100, limit=1000, incoming=300, outgoing=0))
check("incoming delivery raises the future level", b.start == 100 and b.current == 400,
      f"start={b.start} current={b.current}")
check("  ...against the ware's own allocation", b.max == 1000 and b.estimated is False)

b = G.reservationBar(lua.table(stock=800, limit=1000, incoming=0, outgoing=500))
check("outgoing pickup lowers the future level", b.current == 300, f"current={b.current}")

# a mining hub: miners delivering AND factories collecting, at the same time
b = G.reservationBar(lua.table(stock=500, limit=1000, incoming=200, outgoing=450))
check("both directions apply: NET change, not one side by role", b.current == 250,
      f"current={b.current}")

b = G.reservationBar(lua.table(stock=100, limit=1000, incoming=0, outgoing=400))
check("an over-committed hold floors at zero, never negative", b.current == 0,
      f"current={b.current}")

b = G.reservationBar(lua.table(stock=900, limit=1000, incoming=400, outgoing=0))
check("the allocation stays fixed and only the drawing clips on overflow",
      b.max == 1000 and b.current == 1300 and b.drawCurrent == 1000 and b.futurePercent == 130, f"max={b.max} current={b.current}")

b = G.reservationBar(lua.table(stock=50, limit=0, capacityUnits=2000, incoming=0, outgoing=0))
check("unknown allocation falls back to transport-type capacity",
      b.max == 2000 and b.estimated is True and b.unknown is False, f"max={b.max}")

b = G.reservationBar(lua.table(stock=0, limit=0, capacityUnits=0))
check("no allocation and no capacity: flagged unknown, denominator stays positive",
      b.unknown is True and b.max >= 1, f"max={b.max}")

print("\n=== A: capacity balance (can the chain sustain it?) ===")
stations = lua.table(
    station("fac", "Factory", {"meds": dict(output=True, stock=8000, limit=100000,
                                            production=40000, prodMax=60000)}),
    station("hab1", "Habitat 1", {"meds": dict(input=True, stock=80000, limit=100000,
                                               consumption=5000, consMax=10000)}),
    station("hab2", "Habitat 2", {"meds": dict(input=True, stock=70000, limit=100000,
                                               consumption=5000, consMax=10000)}),
)
g = G.build(stations, lua.table())
w = g.wareNodes["meds"]
check("supply capacity sums prodMax over suppliers", w.supplyCap == 60000, f"got={w.supplyCap}")
check("demand capacity sums consMax over consumers", w.demandCap == 20000, f"got={w.demandCap}")
check("balance = supply capacity / demand capacity", abs(w.balance - 3.0) < 1e-9,
      f"got={w.balance}")
check("balance known, so no unknown flag", w.balanceUnknown is None)

# The reported case: ONE supplier nearly empty, consumers sitting on big stocks. That reads
# as a crisis in the detail panel, but capacity exceeds demand and nobody is running dry -
# the supplier is empty because its output was shipped out. The bar must say so.
check("a drained supplier with ample capacity is NOT a shortage", w.balance > 1)
check("  ...and with no consumer near empty, urgency stays ok", w.severity == "ok",
      f"severity={w.severity}")

stations = lua.table(
    # a mining hub: sells ore, has no production module, so no supply capacity figure
    station("hub", "Mining Hub", {"ore": dict(output=True, stock=50000, prodMax=0)}),
    station("ref", "Refinery", {"ore": dict(input=True, stock=100, consumption=500,
                                            consMax=900)}),
)
g = G.build(stations, lua.table())
w = g.wareNodes["ore"]
check("no supplier module -> balance UNKNOWN, not zero", w.balance is None
      and w.balanceUnknown == "supply", f"balance={w.balance} unknown={w.balanceUnknown}")

stations = lua.table(
    station("fac", "Factory", {"hull": dict(output=True, stock=900, prodMax=100)}),
    # a shipyard's build queue has no consumption rate at all
    station("yard", "Shipyard", {"hull": dict(input=True, stock=10, consMax=0)}),
)
g = G.build(stations, lua.table())
w = g.wareNodes["hull"]
check("no demand rate -> balance unknown on the demand side",
      w.balance is None and w.balanceUnknown == "demand", f"unknown={w.balanceUnknown}")

stations = lua.table(
    station("fac", "Factory", {"x": dict(output=True, stock=10, prodMax=100)}),
    station("big", "Big Consumer", {"x": dict(input=True, stock=10, consMax=400)}),
)
g = G.build(stations, lua.table())
check("structural shortfall shows as balance below 1",
      abs(g.wareNodes["x"].balance - 0.25) < 1e-9, f"got={g.wareNodes['x'].balance}")

print("\n=== B: total stock (how much is banked?) ===")
stations = lua.table(
    station("s", "Supplier", {"y": dict(output=True, stock=1200, prodMax=10)}),
    station("c1", "Consumer 1", {"y": dict(input=True, stock=300, consMax=5)}),
    station("c2", "Consumer 2", {"y": dict(input=True, stock=500, consMax=5)}),
)
g = G.build(stations, lua.table())
check("total stock = supplier stock + consumer stock", g.wareNodes["y"].totalStock == 2000,
      f"got={g.wareNodes['y'].totalStock}")

print("\n=== C: urgency from the consumer that runs dry FIRST ===")
# Nine consumers sitting on huge stocks and one at minutes. The chain AVERAGE is hundreds of
# hours - it said "healthy" - while one station was about to stall.
many = [station("s", "Supplier", {"z": dict(output=True, stock=5000, prodMax=5000)})]
for i in range(9):
    many.append(station(f"rich{i}", f"Rich {i}", {"z": dict(input=True, stock=80000,
                                                            consumption=100, consMax=100)}))
many.append(station("poor", "Poor", {"z": dict(input=True, stock=20, consumption=100,
                                               consMax=100)}))
g = G.build(lua.table(*many), lua.table())
w = g.wareNodes["z"]
check("the chain AVERAGE looks healthy", w.coverHours > 100, f"avg={w.coverHours:.0f}h")
check("but the worst consumer is found", w.worstConsumer == "poor", f"got={w.worstConsumer}")
check("  ...with its own cover", abs(w.worstCover - 0.2) < 1e-9, f"got={w.worstCover}")
check("  ...and IT decides the urgency: critical", w.severity == "critical",
      f"severity={w.severity}")

stations = lua.table(
    station("s", "Supplier", {"q": dict(output=True, stock=10, prodMax=10)}),
    station("y", "Yard", {"q": dict(input=True, stock=10, consumption=0, consMax=0)}),
)
g = G.build(stations, lua.table())
check("no consumer draws at a rate -> no worst consumer, urgency ok",
      g.wareNodes["q"].worstConsumer is None and g.wareNodes["q"].severity == "ok")

print("\n=== edge cases ===")
empty = G.build(lua.table(), lua.table())
check("empty station list refuses with a reason",
      empty == (None, "empty") or empty is None, f"got={empty!r}")
g = G.build(lua.table(station("s1", "Lonely", {"x": dict(output=True, production=1, stock=5)})),
            lua.table())
check("single station builds with no ware nodes", g is not None and g.counts.nodes == 1)
check("  ...and no edges", g.counts.edges == 0)

print("\n" + "=" * 52)
if fails:
    print(f"{len(fails)} FAILED:")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("All checks passed.")
