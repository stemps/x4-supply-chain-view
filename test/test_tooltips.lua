-- Recorded native-widget contracts: preserve meaning when moving explanations.
-- Loaded by test_metrics.py; no engine or graph arithmetic is replaced.
local function has(text, expected)
    assert(string.find(text, expected, 1, true), expected .. " missing from: " .. text)
end
local function lacks(text, unexpected)
    assert(not string.find(text, unexpected, 1, true), unexpected .. " leaked into: " .. text)
end
local function entry(ware)
    local station = { id = "tooltip", name = "Tooltip Station", wares = { energycells = ware } }
    local graph = SCV_Graph.build({ station })
    menu.graph = graph
    local t = tableMock()
    menu.expandStation(nil, { properties = { height = 600 } }, t, graph.stationNodes.tooltip)
    for i, row in ipairs(t.rows) do
        if row.key == "ware:energycells" then
            return { label = row[1].props.mouseOverText,
                stock = t.rows[i+1][1].bar.mouseOverText,
                amount = t.rows[i+2][1].props.mouseOverText,
                rate = t.rows[i+2][2].props.mouseOverText,
                coverage = t.rows[i+3][1].props.mouseOverText }, graph
        end
    end
    error("missing tooltip entry")
end

local w = { name = "Energy Cells", input = true, stock = 948000, limit = 3000000,
    incoming = 2000000, outgoing = 0, consMax = 3200000, consKnown = true,
    rateBasis = "continuousProcessing",
    consumptionParts = { processing = 1500000, production = 1700000, workforce = 0, total = 3200000 } }
local tips = entry(w)
assert(tips.stock == "Energy Cells\n\nStock: 948.0k / 3.0M\nReserved incoming: 2.0M\nAfter reserved trades: 2.9M", tips.stock)
assert(tips.amount == tips.stock)
assert(tips.rate == "Energy Cells\n\nMaximum consumption: 3.2M/h\n  Scrap processing: 1.5M/h\n  Other production: 1.7M/h\n\nAt full operation:\nEnough inputs and output space.\nContinuous scrap supply.\nIncludes current workforce.", tips.rate)
has(tips.coverage, "Lasts: 17m\nWhen full: 56m")
has(tips.coverage, "Excludes deliveries, reservations and local production.")
for _, text in ipairs({ tips.stock, tips.coverage }) do
    lacks(text, "Scrap processing:")
    lacks(text, "Other production:")
end
lacks(tips.stock, "At full operation:")
lacks(tips.rate, "Total:")
lacks(tips.rate, "Workforce:")
lacks(tips.rate, "Reserved")
lacks(tips.rate, "-3.2M")

w.consumptionParts.workforce, w.consumptionParts.total, w.consMax = 100, 3200100, 3200100
tips = entry(w)
has(tips.rate, "  Workforce: 100/h")
w.consKnown = false
tips = entry(w)
has(tips.rate, "Maximum consumption: ? /h\nMaximum demand unknown:")
lacks(tips.rate, "Scrap processing:")
lacks(tips.coverage, "Lasts: 17m")

-- Unknown stock must not hide an independently known capacity or invent stock.
w.stockKnown, w.reservationsKnown = false, false
tips = entry(w)
has(tips.stock, "Stock: ? / 3.0M\nStock unknown.")
has(tips.stock, "After reserved trades: ?\nReserved trades unknown;")
has(tips.coverage, "Stock unknown.")

-- Ordinary output: signed row values are unchanged, tooltip magnitudes unsigned.
w = { name = "Energy Cells", output = true, stock = 100, limit = 0, capacityUnits = 1000,
    prodMax = 100, prodKnown = true, incoming = 0, outgoing = 20 }
tips = entry(w)
has(tips.rate, "Maximum production: 100/h")
has(tips.rate, "Includes current production modifiers.")
lacks(tips.rate, "current workforce")
lacks(tips.rate, "Continuous scrap")
lacks(tips.rate, "+100/h")
assert(tips.label == tips.rate)
has(tips.stock, "Stock: 100 / ~1.0k\nEstimated capacity:")
has(tips.stock, "Reserved outgoing: 20\nAfter reserved trades: 80")
has(tips.coverage, "Full in: ~9.0h\nFrom empty: ~10.0h")
has(tips.coverage, "available space may be lower.")
has(tips.coverage, "Excludes collections/reservations.")
assert(tips.amount == tips.stock)
w.capacityUnits = nil
tips = entry(w)
has(tips.stock, "Stock: 100 / ?\nStorage capacity unknown.")
has(tips.coverage, "Storage capacity unknown.")
lacks(tips.stock, "Estimated capacity:")

-- Ordinary input and zero/unknown rates remain distinct.
w = { name = "Energy Cells", input = true, stock = 100, limit = 200, consMax = 0, consKnown = true }
tips = entry(w)
has(tips.rate, "Maximum consumption: 0/h")
lacks(tips.rate, "unknown")
lacks(tips.rate, "Continuous scrap")
w.consKnown = false
tips = entry(w)
has(tips.rate, "Rate unknown:")
lacks(tips.rate, "Maximum consumption: 0/h")

-- Aggregate qualifiers stay next to incomplete metrics; stock and rate totals focus.
local supplier = { id = "supplier", name = "Supplier", wares = {
    ore = { name = "Ore", output = true, stock = 100, limit = 200, prodMax = 50, prodKnown = true } } }
local consumer = { id = "consumer", name = "Consumer", wares = {
    ore = { name = "Ore", input = true, stockKnown = false, capacityUnits = 300,
        consMax = 80, consKnown = false } } }
local graph = SCV_Graph.build({ supplier, consumer })
menu.graph = graph
menu.decorateNodes(graph)
local node = graph.wareNodes.ore
local overview = node[1].properties.mouseOverText
has(overview, "Ore\n\nStock: 100 + ? / ~500\nIncomplete stock or capacity;")
has(overview, "Maximum production: 50/h\nMaximum consumption: 80/h + ?\nIncomplete total:")
has(overview, "Balance: ? /h")
local totals = tableMock()
menu.expandWare(nil, { properties = { height = 600 } }, totals, node)
local stock = totals.rows[2][1].props.mouseOverText
local production = totals.rows[3][2].props.mouseOverText
local consumption = totals.rows[4][2].props.mouseOverText
has(stock, "Each supplier/consumer station counted once.")
has(stock, "Reservations are not added to stock.")
has(stock, "Incomplete stock or capacity;")
lacks(stock, "Maximum production:")
has(production, "Maximum production: 50/h\nSupplier stations combined.")
has(production, "Excludes mining deliveries and trades.")
lacks(production, "Incomplete total:")
lacks(production, "Maximum consumption:")
has(consumption, "Maximum consumption: 80/h + ?\nIncomplete total:")
has(consumption, "Excludes trade orders.")
lacks(consumption, "Stock:")

-- Aggregates inherit the continuous-supply condition from consumer snapshots,
-- including a change while the ware panel remains open. No rate arithmetic changes.
local record = graph.stationNodes.consumer.wares.ore
for _, continuous in ipairs({true, false}) do
    record.rateBasis = continuous and "continuousProcessing" or nil
    menu.metricRevision = (menu.metricRevision or 0) + 1
    menu.decorateNodes(graph)
    for _, row in ipairs(totals.rows) do for col = 1, 2 do row[col]:update() end end
    local check = continuous and has or lacks
    check(node[1].properties.mouseOverText, "Continuous scrap supply.")
    check(totals.rows[4][2].props.mouseOverText, "Continuous scrap supply.")
    lacks(totals.rows[3][2].props.mouseOverText, "Continuous scrap supply.")
    lacks(totals.rows[2][1].props.mouseOverText, "Continuous scrap supply.")
    assert(totals.rows[4][2].text == "-80/h + ?")
end
print("PASS focused tooltip contracts")
