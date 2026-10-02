"""Metrics run without X4; graph compatibility keeps shared policy and live dispatch."""
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime

from addon_loader import load_modules


for runtime in (LuaRuntime, LuaJITRuntime):
    lua = runtime(unpack_returned_tuples=True)
    load_modules(lua, "scv_metrics.lua")
    lua.execute("""
        assert(SCV_Graph == nil, "metrics must work independently of the graph")
        local m = SCV_Metrics
        assert(m.severityFor(0.249) == "critical")
        assert(m.severityFor(0.25) == "warning")
        assert(m.severityFor(0.5) == "ok")
        assert(m.validRate(0) and not m.validRate(-1))
        assert(not m.validRate(0/0) and not m.validRate(math.huge))
        local _, known = m.effectiveCapacity({ capacityUnits = 0 })
        assert(not known, "legacy zero capacity is unknown")
        _, known = m.effectiveCapacity({ capacityUnits = 0, capacityUnitsKnown = true })
        assert(known, "explicit zero capacity is known")
        local w = { input = true, stock = 0, consMax = 0, consKnown = true }
        assert(m.wareHealth(w).known and m.wareHealth(w).severity == "ok")
        w.consKnown = false
        assert(not m.wareHealth(w).known)
        local total = m.storageTotals({ a = { wares = { ore = {
            stock = 4, limit = 10
        } } } }, "ore", { "a" }, { "a" })
        assert(total.stock == 4 and total.capacity == 10, "dual roles count once")
        local bar = m.reservationBar({stock=4, limit=10, incoming=3, outgoing=2})
        assert(bar.current == 5 and bar.futurePercent == 50)
        local logistics = m.logisticsTotals({shipsKnown=true, idleKnown=true,
            traders={container={total=4, idle=3}}})
        assert(logistics.total == 4 and logistics.severity == "critical")
    """)
    load_modules(lua, "scv_graph.lua")
    lua.execute("""
        local g, m = SCV_Graph, SCV_Metrics
        assert(rawequal(g.THRESHOLDS, m.THRESHOLDS))
        local critical = m.THRESHOLDS.criticalHours
        g.THRESHOLDS.criticalHours = 0.1
        assert(g.severityFor(0.2) == "warning")
        m.THRESHOLDS.criticalHours = critical
        local original = m.moduleRates
        m.moduleRates = function() return "produced", "consumed" end
        local produced, consumed = g.moduleRates({})
        assert(produced == "produced" and consumed == "consumed")
        m.moduleRates = original
        local originalHealth = g.wareHealth
        g.wareHealth = function() return {severity="critical", known=true} end
        local node = {wares={ore={}}}
        g.updateStationMetrics(node)
        assert(node.severity == "critical", "graph must dispatch through facade")
        g.wareHealth = originalHealth
    """)
    print(f"PASS metric module and graph compatibility ({runtime.__module__})")
