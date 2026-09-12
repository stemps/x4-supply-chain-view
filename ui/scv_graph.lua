-- Supply Chain View — the model.
--
-- This file makes NO game API calls. It takes a plain description of some stations and
-- returns a plain description of a graph, so the tricky parts (cycle breaking, budget
-- degradation, the health arithmetic) can be exercised without launching X4.
--
-- It owns no display strings either. Names arrive already resolved from the data layer;
-- ReadText and colour live in scv_menu. The model knows severities, not colours.

-- GLOBAL, not local: this is how the addon environment shares state between the files
-- listed in ui.xml. Declaring it local would make the later files find nil and go inert
-- quietly - the exact failure the ui.xml load order comment warns about.
SCV_Graph = {}

-- ---------------------------------------------------------------------------------
-- Engine limits. From reference\ui\widget\lua\widget_fullscreen.lua:778 (config.flowchart).
-- These are hard allocation limits in the widget system: exceeding them does not error,
-- it drops whatever did not fit. We budget against them explicitly so that the thing the
-- user loses is a thing we chose, and told them about.
-- ---------------------------------------------------------------------------------
SCV_Graph.LIMITS = {
	maxNodes = 100,
	maxEdges = 150,
	maxCols  = 30,
}

-- Hours of headroom below which a ware is flagged.
SCV_Graph.THRESHOLDS = {
	criticalHours = 0.25,
	warningHours  = 0.5,
}

-- Wares nearly every station trades. When a chain is over budget these collapse from their
-- own node into a per-station badge: an energy cells node wired to all twelve stations
-- costs twelve edges and says nothing you had not already assumed.
SCV_Graph.COMMON_WARES = {
	energycells = true,
	water       = true,
}

-- Transport type -> edge slot rank, matching the vanilla Logical Station Overview
-- (menu_station_overview.lua:544). The rank feeds Helper.setupDAGLayout's edge-crossing
-- reduction, so using the same convention gets the same tidy layout vanilla has.
local SLOT_RANK = { solid = 3, liquid = 2, container = 1 }

function SCV_Graph.slotRank(transporttype)
	return SLOT_RANK[transporttype] or 1
end

-- ---------------------------------------------------------------------------------
-- Health
-- ---------------------------------------------------------------------------------

-- Rates are units per hour (GetContainerWareProduction / GetContainerWareConsumption are
-- per-hour; vanilla derives a comparable figure as amount * 3600 / queueduration at
-- menu_station_overview.lua:2642).
--
-- Input warnings use maximum consumption without deliveries.
-- Output fill time is informational only.
local function hoursOfCover(stock, consumption)
	if (not consumption) or (consumption <= 0) then
		return nil    -- nothing draws it here: it cannot run dry
	end
	return stock / consumption
end

local function hoursToFull(stock, limit, production)
	if (not production) or (production <= 0) then
		return nil    -- nothing makes it here: it cannot back up
	end
	-- limit == 0 means UNKNOWN, not "no capacity". A pure trade ware has no production
	-- limit at all, and treating that as zero headroom declared every such ware critically
	-- backed up the instant anything produced it.
	if (not limit) or (limit <= 0) then
		return nil
	end
	local headroom = limit - (stock or 0)
	if headroom <= 0 then
		return 0
	end
	return headroom / production
end

function SCV_Graph.severityFor(hours)
	if hours < SCV_Graph.THRESHOLDS.criticalHours then
		return "critical"
	elseif hours < SCV_Graph.THRESHOLDS.warningHours then
		return "warning"
	end
	return "ok"
end

local SEVERITY_RANK = { ok = 0, warning = 1, critical = 2 }

function SCV_Graph.severityRank(severity)
	return SEVERITY_RANK[severity] or 0
end

-- Only input coverage determines warning severity.
function SCV_Graph.wareHealth(w)
	local cover = w.input and w.stockKnown ~= false and SCV_Graph.rateKnown(w, true)
		and hoursOfCover(w.stock, w.consMax) or nil
	local severity, hours, reason = "ok", nil, nil
	if cover then
		severity, hours, reason = SCV_Graph.severityFor(cover), cover, "starved"
	end

	local role = "idle"
	if w.output and w.input then
		role = "both"
	elseif w.output then
		role = "output"
	elseif w.input then
		role = "input"
	end

	local known = w.stockKnown ~= false
		and (not w.input or SCV_Graph.rateKnown(w, true))
		and (not w.output or (SCV_Graph.rateKnown(w, false) and (w.limit or 0) > 0))
	return { role = role, severity = severity, hours = hours, reason = reason, known = known,
	         cover = cover }
end

function SCV_Graph.validRate(value)
	local n = tonumber(value)
	return n ~= nil and n == n and n >= 0 and n < math.huge
end

-- Storage is a union of participating stations, never one copy per edge/role.
function SCV_Graph.storageTotals(stations, ware, producers, consumers)
	local total = { stock = 0, capacity = 0, stockKnown = true, capacityKnown = true, estimated = false }
	local seen = {}
	for _, ids in ipairs({ producers, consumers }) do
		for _, id in ipairs(ids) do
			if not seen[id] then
				seen[id] = true
				local w = stations[id] and stations[id].wares[ware]
				if w then
					if w.stockKnown ~= false then total.stock = total.stock + (w.stock or 0)
					else total.stockKnown = false end
					local cap = w.limit or 0
					if cap <= 0 then cap = w.capacityUnits or 0; total.estimated = total.estimated or cap > 0 end
					if cap > 0 then total.capacity = total.capacity + cap else total.capacityKnown = false end
				else total.stockKnown = false; total.capacityKnown = false end
			end
		end
	end
	return total
end

function SCV_Graph.rateKnown(w, isInput)
	local flag = w.prodKnown
	-- Explicit flags distinguish real zero from unavailable rates. Legacy callers
	-- without flags can establish only positive, measurable capacity.
	if isInput then flag = w.consKnown end
	if flag ~= nil then return flag end
	return (tonumber(isInput and w.consMax or w.prodMax) or 0) > 0
end

-- ---------------------------------------------------------------------------------
-- Detail-panel arithmetic (pure, so it is unit-tested rather than eyeballed in game)
-- ---------------------------------------------------------------------------------

-- Theoretical rates for ONE module, computed the way the Logical Station Overview does
-- (menu_station_overview.lua:2611-2621):
--     queueduration = sum of cycle over EVERY product in the module's list
--     product rate  = amount * 3600 / queueduration
--     resource rate = amount * 3600 / queueduration
-- The trap is the denominator. A module that can make several products cycles through all
-- of them, so each one's rate is its amount over the WHOLE queue, not over its own cycle.
-- Dividing by the product's own cycle overstates a multi-product module by the number of
-- products it has.
--
-- This is the BASE rate at 100% efficiency, without workforce bonus - the same figure the
-- LSO labels as the single-module rate.
function SCV_Graph.moduleRates(products)
	local produced, consumed = {}, {}
	if type(products) ~= "table" then
		return produced, consumed
	end
	local queue = 0
	for _, p in ipairs(products) do
		queue = queue + (tonumber(p.cycle) or 0)
	end
	if queue <= 0 then
		return produced, consumed
	end
	for _, p in ipairs(products) do
		if p.ware then
			produced[p.ware] = (produced[p.ware] or 0) + (tonumber(p.amount) or 0) * 3600 / queue
		end
		for _, r in ipairs(p.resources or {}) do
			if r.ware then
				consumed[r.ware] = (consumed[r.ware] or 0) + (tonumber(r.amount) or 0) * 3600 / queue
			end
		end
	end
	return produced, consumed
end

-- The stock bar for one ware at one station, including reserved trades.
--
-- Mirrors vanilla's own trade-menu cargo bar (menu_map.lua:31054):
--     start   = stock now
--     current = stock once every reserved exchange has completed
-- so a pending gain draws in the positive colour and a pending loss in the negative one.
--
-- NET change, not role-based. Deliveries in and pickups out are both applied, because a
-- station routinely has both: a mining hub receives from its own miners while factories are
-- collecting from it. Showing only one direction per role would misstate what the hold will
-- actually contain. In the common case this reduces to "inputs gain, outputs lose".
--
-- The denominator is the station's storage allocation for the ware when the engine reports
-- one; otherwise the station's whole capacity for that transport type, which is an upper
-- bound (it is shared between every ware of that type) and is flagged as an estimate.
function SCV_Graph.reservationBar(w)
	local stock    = tonumber(w.stock) or 0
	local incoming = tonumber(w.incoming) or 0
	local outgoing = tonumber(w.outgoing) or 0
	local future   = stock + incoming - outgoing
	if future < 0 then
		future = 0
	end

	local limit = tonumber(w.limit) or 0
	local estimated = false
	local maxv = limit
	if maxv <= 0 then
		maxv = tonumber(w.capacityUnits) or 0
		estimated = true
	end
	local capacityKnown = maxv > 0
	local stockKnown = w.stockKnown ~= false
	local reservationsKnown = w.reservationsKnown ~= false
	if maxv <= 0 then
		maxv = 1
	end

	return {
		start     = stock,
		current   = future,
		max       = maxv,
		incoming  = incoming,
		outgoing  = outgoing,
		estimated = estimated,
		unknown   = not capacityKnown or not stockKnown,
		stockKnown = stockKnown,
		reservationsKnown = reservationsKnown,
		percent = capacityKnown and stockKnown and stock / maxv * 100 or nil,
		futurePercent = capacityKnown and stockKnown and reservationsKnown and future / maxv * 100 or nil,
		drawStart = capacityKnown and stockKnown and math.min(stock, maxv) or 0,
		drawCurrent = capacityKnown and stockKnown and math.min(reservationsKnown and future or stock, maxv) or 0,
	}
end

-- The shared popup contract. Both entry points supply the same ware record and role.
function SCV_Graph.detailMetrics(w, isInput)
	local bar = SCV_Graph.reservationBar(w)
	local rate = isInput and w.consMax or w.prodMax
	local known = SCV_Graph.rateKnown(w, isInput)
	local measurable = known and (rate or 0) > 0
	local capacityKnown = (w.limit or 0) > 0 or (w.capacityUnits or 0) > 0
	return {
		bar = bar,
		rate = rate,
		rateKnown = known,
		stockHours = measurable and bar.stockKnown and bar.start / rate or nil,
		fillHours = not isInput and measurable and bar.stockKnown and capacityKnown
			and hoursToFull(bar.start, bar.max, rate) or nil,
		capacityHours = measurable and capacityKnown and bar.max / rate or nil,
		sign = isInput and "-" or "+",
		severity = w.health and w.health.severity or "ok",
	}
end

-- ---------------------------------------------------------------------------------
-- Graph construction
-- ---------------------------------------------------------------------------------

-- stations: array of
--   { id = "<string form of id64>", name = "...",
--     wares = { [ware] = { name=, transport=, stock=, limit=, production=, consumption=,
--                          output = <bool>, input = <bool> } } }
--
-- OUTPUT and INPUT are decided by the data layer, not here, and they are NOT the same as
-- "produces" and "consumes":
--   output = the station has a SELL offer for the ware, and no module on it consumes it
--   input  = the station has a BUY  offer for the ware, and no module on it produces it
-- The offer is what makes a ware part of the chain at all; the module test is what strips
-- out internal intermediates that never leave the station.
--
-- Bipartite by construction: station -> ware -> station. A ware earns a node ONLY if it
-- crosses between two members of the chain (an output of one, an input of another). Wares
-- with no counterpart here are the chain's BOUNDARY, reported on the station node rather
-- than drawn as dangling stubs.
-- Recalculate only metrics. Node identity, roles and predecessors belong to the layout.
function SCV_Graph.updateStationMetrics(node)
	node.severity, node.healthKnown, node.worstWare = "ok", true, nil
	for ware, w in pairs(node.wares) do
		local h = SCV_Graph.wareHealth(w)
		w.health = h
		node.healthKnown = node.healthKnown and h.known
		if SCV_Graph.severityRank(h.severity) > SCV_Graph.severityRank(node.severity) then
			node.severity  = h.severity
			node.worstWare = ware
		end
	end
end

function SCV_Graph.updateWareMetrics(wnode, stationNodes)
	local ware, producers, consumers = wnode.scvware, wnode.producers, wnode.consumers
	-- Totals used by the inventory and maximum hourly-rate displays.
	wnode.supplyCap, wnode.demandCap = 0, 0
	wnode.supplyKnown, wnode.demandKnown = true, true
	for _, sid in ipairs(producers) do
		local w = stationNodes[sid] and stationNodes[sid].wares[ware]
		wnode.supplyKnown = wnode.supplyKnown and w ~= nil and SCV_Graph.rateKnown(w, false)
		wnode.supplyCap = wnode.supplyCap + (w and w.prodMax or 0)
	end
	for _, sid in ipairs(consumers) do
		local w = stationNodes[sid] and stationNodes[sid].wares[ware]
		wnode.demandKnown = wnode.demandKnown and w ~= nil and SCV_Graph.rateKnown(w, true)
		wnode.demandCap = wnode.demandCap + (w and w.consMax or 0)
	end
	wnode.netKnown = wnode.supplyKnown and wnode.demandKnown
	wnode.netRate = wnode.netKnown and (wnode.supplyCap - wnode.demandCap) or nil
	wnode.storage = SCV_Graph.storageTotals(stationNodes, ware, producers, consumers)
end

-- Capture all source roles, including boundary wares and nodes hidden by the budget.
-- This baseline is immutable until the user rebuilds the view.
function SCV_Graph.captureStructure(stations)
	local structure = {}
	for _, st in ipairs(stations) do
		local roles = {}
		for ware, w in pairs(st.wares or {}) do
			roles[ware] = { input = not not w.input, output = not not w.output }
		end
		structure[st.id] = roles
	end
	return structure
end

local function sameRole(w, role)
	return w and (not not w.input == role.input) and (not not w.output == role.output)
end

local function unknownWare(w)
	return { name = w.name, transport = w.transport, input = w.input, output = w.output,
		stock = 0, limit = 0, capacityUnits = 0, prodMax = 0, consMax = 0,
		production = 0, consumption = 0, workforce = 0, incoming = 0, outgoing = 0,
		stockKnown = false, limitKnown = false, prodKnown = false,
		consKnown = false, reservationsKnown = false }
end

-- Publish a whole sweep without touching topology or any widget/layout references.
-- Ware tables remain stable too: an expanded panel may already reference them.
function SCV_Graph.refreshMetrics(graph, stations)
	local current = {}
	for _, st in ipairs(stations) do current[st.id] = st end
	local changed, failed, locked = false, false, 0
	for id, roles in pairs(graph.sourceStructure) do
		local st = current[id]
		local available = st and not st.failed and not st.missing
		failed = failed or not st or (st.failed == true)
		if not st or st.missing then changed = true end
		if st and st.locked then locked = locked + 1 end
		if available then
			for ware, role in pairs(roles) do
				if not sameRole(st.wares[ware], role) then changed = true end
			end
			for ware in pairs(st.wares) do
				if not roles[ware] then changed = true end
			end
		end
		local node = graph.metricStations[id]
		if node then
			for ware, w in pairs(node.wares) do
				local fresh = available and st.wares[ware]
				if not sameRole(fresh, roles[ware]) then fresh = unknownWare(w) end
				-- Preserve the displayed names, transport and role; only values change.
				local name, transport, input, output = w.name, w.transport, w.input, w.output
				if fresh ~= w then
					for key in pairs(w) do w[key] = nil end
					for key, value in pairs(fresh) do w[key] = value end
				end
				w.name, w.transport, w.input, w.output = name, transport, input, output
			end
			SCV_Graph.updateStationMetrics(node)
		end
	end
	for _, node in pairs(graph.wareNodes) do SCV_Graph.updateWareMetrics(node, graph.metricStations) end
	graph.structureChanged, graph.refreshFailed, graph.lockedCount = changed, failed, locked
end

function SCV_Graph.build(stations, options)
	options = options or {}

	if (not stations) or (#stations == 0) then
		return nil, "empty"
	end

	local nodes        = {}
	local stationNodes = {}
	local wareNodes    = {}

	-- Station nodes first, so node order is stable and the diagram does not reshuffle
	-- between refreshes. Helper's layout iterates originalnodes in order (getNextTier does
	-- this explicitly rather than iterating the faster hash, to avoid random results), so a
	-- stable input order is what buys a stable picture.
	for _, st in ipairs(stations) do
		local node = {
			scvkind   = "station",
			scvid     = st.id,
			name      = st.name,
			type      = "container",
			wares     = st.wares or {},
			severity  = "ok",
			healthKnown = true,
			worstWare = nil,
			unmet     = {},    -- an input here, supplied by nobody in the chain
			unsold    = {},    -- an output here, taken by nobody in the chain
			collapsed = {},    -- common wares folded into a badge by applyBudget
		}
		SCV_Graph.updateStationMetrics(node)
		nodes[#nodes + 1] = node
		stationNodes[st.id] = node
	end

	local producersOf, consumersOf = {}, {}
	for _, st in ipairs(stations) do
		for ware, w in pairs(st.wares or {}) do
			if w.output then
				producersOf[ware] = producersOf[ware] or {}
				producersOf[ware][#producersOf[ware] + 1] = st.id
			end
			if w.input then
				consumersOf[ware] = consumersOf[ware] or {}
				consumersOf[ware][#consumersOf[ware] + 1] = st.id
			end
		end
	end

	-- Record the boundary before discarding non-crossing wares. "Nobody here supplies this"
	-- and "nobody here takes this" are frequently the actually-useful finding.
	for _, st in ipairs(stations) do
		local node = stationNodes[st.id]
		for ware, w in pairs(st.wares or {}) do
			if w.input and (not producersOf[ware]) then
				node.unmet[#node.unmet + 1] = ware
			end
			if w.output and (not consumersOf[ware]) then
				node.unsold[#node.unsold + 1] = ware
			end
		end
		table.sort(node.unmet)
		table.sort(node.unsold)
	end

	local edges = {}
	for ware, producers in pairs(producersOf) do
		local consumers = consumersOf[ware]
		if consumers then
			local sample
			for _, sid in ipairs(producers) do
				sample = stationNodes[sid].wares[ware]
				if sample then break end
			end

			local wnode = {
				scvkind   = "ware",
				scvware   = ware,
				name      = (sample and sample.name) or ware,
				type      = (sample and sample.transport) or "container",
				producers   = producers,
				consumers   = consumers,

			}

			SCV_Graph.updateWareMetrics(wnode, stationNodes)

			nodes[#nodes + 1] = wnode
			wareNodes[ware] = wnode

			local rank = SCV_Graph.slotRank(wnode.type)
			for _, sid in ipairs(producers) do
				edges[#edges + 1] = { from = stationNodes[sid], to = wnode, rank = rank, ware = ware }
			end
			for _, sid in ipairs(consumers) do
				edges[#edges + 1] = { from = wnode, to = stationNodes[sid], rank = rank, ware = ware }
			end
		end
	end

	local graph = {
		sourceStructure = SCV_Graph.captureStructure(stations),
		nodes           = nodes,
		stationNodes    = stationNodes,
		wareNodes       = wareNodes,
		edges           = edges,
		droppedEdges    = {},
		collapsedWares  = {},
		droppedStations = {},
	}

	-- Budgeting removes visible nodes, but totals were calculated over every source
	-- endpoint. Keep that same metric domain on refresh, including hidden stations.
	graph.metricStations = {}
	for id, node in pairs(stationNodes) do graph.metricStations[id] = node end
	graph.lockedCount = 0
	for _, st in ipairs(stations) do
		if st.locked then graph.lockedCount = graph.lockedCount + 1 end
	end
	SCV_Graph.breakCycles(graph)
	SCV_Graph.applyBudget(graph, options)
	SCV_Graph.materializePredecessors(graph)

	graph.counts = { nodes = #graph.nodes, edges = #graph.edges }
	return graph
end

-- ---------------------------------------------------------------------------------
-- Cycle breaking
-- ---------------------------------------------------------------------------------

-- Helper.setupDAGLayout DOES survive cycles - buildTiers detects a stalled tier and calls
-- removeCyclicEdge in a loop until the graph is acyclic. But it logs
--   "setupDAGLayoutHelper: Cyclic dependencies detected. Removing dependencies..."
-- to debug.txt and drops an ARBITRARY edge to recover.
--
-- Two player stations that supply each other is an ordinary X4 topology, not an error, so
-- leaving it to the engine means routine debug.txt spam plus a diagram that loses a
-- different edge depending on hash order. Breaking cycles here means we choose the edge,
-- we can render the fact, and the log stays clean enough that a real error stands out.
function SCV_Graph.breakCycles(graph)
	local succ = {}
	for _, e in ipairs(graph.edges) do
		succ[e.from] = succ[e.from] or {}
		local s = succ[e.from]
		s[#s + 1] = e
	end

	local WHITE, GREY, BLACK = 0, 1, 2
	local colour = {}
	for _, n in ipairs(graph.nodes) do
		colour[n] = WHITE
	end

	local dropped = {}

	-- Iterative DFS. Recursion would be fine at these sizes, but a stack overflow inside a
	-- UI callback takes the whole menu down, and the iterative form costs little.
	local function visit(root)
		local stack = { { node = root, idx = 1 } }
		colour[root] = GREY
		while #stack > 0 do
			local top  = stack[#stack]
			local outs = succ[top.node]
			if outs and (top.idx <= #outs) then
				local e = outs[top.idx]
				top.idx = top.idx + 1
				if not e.dropped then
					local c = colour[e.to]
					if c == GREY then
						e.dropped = true          -- back edge: closes a cycle
						dropped[#dropped + 1] = e
					elseif c == WHITE then
						colour[e.to] = GREY
						stack[#stack + 1] = { node = e.to, idx = 1 }
					end
				end
			else
				colour[top.node] = BLACK
				stack[#stack] = nil
			end
		end
	end

	for _, n in ipairs(graph.nodes) do
		if colour[n] == WHITE then
			visit(n)
		end
	end

	if #dropped > 0 then
		local kept = {}
		for _, e in ipairs(graph.edges) do
			if not e.dropped then
				kept[#kept + 1] = e
			end
		end
		graph.edges = kept
		graph.droppedEdges = dropped
	end
end

-- ---------------------------------------------------------------------------------
-- Budget
-- ---------------------------------------------------------------------------------

-- Degrade in two stages, cheapest loss first, and report everything given up. Never
-- silently truncate: a diagram quietly missing a station is worse than no diagram, because
-- it looks complete.
function SCV_Graph.applyBudget(graph, options)
	local limits = options.limits or SCV_Graph.LIMITS

	local function overBudget()
		return (#graph.nodes > limits.maxNodes) or (#graph.edges > limits.maxEdges)
	end

	if not overBudget() then
		return
	end

	-- Stage 1: collapse common wares into per-station badges, highest degree first, since
	-- that is where the edges actually are.
	local candidates = {}
	for ware, wnode in pairs(graph.wareNodes) do
		if SCV_Graph.COMMON_WARES[ware] then
			candidates[#candidates + 1] = { ware = ware, node = wnode,
				degree = #wnode.producers + #wnode.consumers }
		end
	end
	table.sort(candidates, function (a, b)
		if a.degree ~= b.degree then return a.degree > b.degree end
		return a.ware < b.ware      -- deterministic tie-break
	end)

	for _, c in ipairs(candidates) do
		if not overBudget() then break end
		SCV_Graph.removeNode(graph, c.node)
		graph.wareNodes[c.ware] = nil
		graph.collapsedWares[#graph.collapsedWares + 1] = c.ware
		for _, sid in ipairs(c.node.producers) do
			local sn = graph.stationNodes[sid]
			if sn then sn.collapsed[#sn.collapsed + 1] = c.ware end
		end
		for _, sid in ipairs(c.node.consumers) do
			local sn = graph.stationNodes[sid]
			if sn then sn.collapsed[#sn.collapsed + 1] = c.ware end
		end
	end

	-- Stage 2: drop whole stations, least-connected first - the least-connected station
	-- contributes least to the chain's shape, so the core survives.
	while overBudget() do
		local victim, victimDegree
		for _, n in ipairs(graph.nodes) do
			if n.scvkind == "station" then
				local d = 0
				for _, e in ipairs(graph.edges) do
					if (e.from == n) or (e.to == n) then d = d + 1 end
				end
				if (not victim) or (d < victimDegree) or ((d == victimDegree) and (n.scvid < victim.scvid)) then
					victim, victimDegree = n, d
				end
			end
		end
		if not victim then
			break    -- nothing left to drop; the ware nodes alone exceed the limit
		end
		SCV_Graph.removeNode(graph, victim)
		graph.stationNodes[victim.scvid] = nil
		graph.droppedStations[#graph.droppedStations + 1] = { id = victim.scvid, name = victim.name }
		SCV_Graph.pruneOrphanWares(graph)
	end
end

function SCV_Graph.removeNode(graph, node)
	for i = #graph.nodes, 1, -1 do
		if graph.nodes[i] == node then
			table.remove(graph.nodes, i)
			break
		end
	end
	for i = #graph.edges, 1, -1 do
		local e = graph.edges[i]
		if (e.from == node) or (e.to == node) then
			table.remove(graph.edges, i)
		end
	end
end

function SCV_Graph.pruneOrphanWares(graph)
	local changed = true
	while changed do
		changed = false
		for _, n in ipairs(graph.nodes) do
			if n.scvkind == "ware" then
				local hasIn, hasOut = false, false
				for _, e in ipairs(graph.edges) do
					if e.to == n then hasIn = true end
					if e.from == n then hasOut = true end
				end
				if not (hasIn and hasOut) then
					SCV_Graph.removeNode(graph, n)
					graph.wareNodes[n.scvware] = nil
					changed = true
					break
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------------
-- Hand-off to the layout
-- ---------------------------------------------------------------------------------

-- Helper.setupDAGLayout reads node.predecessors[predecessornode] = slotrank. We keep an
-- explicit edge list until this point because cycle detection and budgeting are far easier
-- over a list than over a hash keyed by table identity.
function SCV_Graph.materializePredecessors(graph)
	for _, n in ipairs(graph.nodes) do
		n.predecessors = nil
	end
	for _, e in ipairs(graph.edges) do
		e.to.predecessors = e.to.predecessors or {}
		e.to.predecessors[e.from] = e.rank
	end
end

local function init()
	SCV_Graph.version = 2
end

init()

return SCV_Graph
