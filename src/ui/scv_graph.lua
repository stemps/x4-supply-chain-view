-- Depends: scv_metrics.lua
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

-- Share the metrics threshold table; callers may tune its fields.
SCV_Graph.THRESHOLDS = SCV_Metrics.THRESHOLDS

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

-- Public compatibility API. Resolve implementations at call time.
function SCV_Graph.severityFor(...)
	return SCV_Metrics.severityFor(...)
end

function SCV_Graph.severityRank(...)
	return SCV_Metrics.severityRank(...)
end

function SCV_Graph.wareHealth(...)
	return SCV_Metrics.wareHealth(...)
end

function SCV_Graph.validRate(...)
	return SCV_Metrics.validRate(...)
end

function SCV_Graph.effectiveCapacity(...)
	return SCV_Metrics.effectiveCapacity(...)
end

function SCV_Graph.storageTotals(...)
	return SCV_Metrics.storageTotals(...)
end

function SCV_Graph.rateKnown(...)
	return SCV_Metrics.rateKnown(...)
end

function SCV_Graph.moduleRates(...)
	return SCV_Metrics.moduleRates(...)
end

function SCV_Graph.reservationBar(...)
	return SCV_Metrics.reservationBar(...)
end

function SCV_Graph.detailMetrics(...)
	return SCV_Metrics.detailMetrics(...)
end

function SCV_Graph.logisticsTotals(...)
	return SCV_Metrics.logisticsTotals(...)
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
-- Roles use configured products/resources and explicit trade settings, not live offers.
-- Internal production/build consumption excludes outputs; workforce consumption does not.
--
-- Bipartite by construction: station -> ware -> station. Every output earns a shared
-- ware node, including terminal outputs with no consumers. Unsupplied inputs remain
-- station boundary information; they do not create source ware nodes.
-- Recalculate only metrics. Node identity, roles and predecessors belong to the layout.
function SCV_Graph.updateStationMetrics(node)
	node.severity, node.healthKnown, node.worstWare = "ok", true, nil
	local rows = {}
	for ware, w in pairs(node.wares) do
		rows[#rows + 1] = ware .. ":" .. tostring(SCV_Graph.metricInput(w)) .. ":" .. tostring(SCV_Graph.metricOutput(w)) .. ":" .. tostring(w.export ~= nil)
		if node.warningPolicy then w.warningIgnored = node.warningPolicy(node.code, ware) end
		local h = SCV_Graph.wareHealth(w)
		w.health = h
		node.healthKnown = node.healthKnown and h.known
		if SCV_Graph.severityRank(h.severity) > SCV_Graph.severityRank(node.severity) then
			node.severity  = h.severity
			node.worstWare = ware
		end
	end
	table.sort(rows)
	node.contributorSignature = table.concat(rows, "|")
end

function SCV_Graph.updateWareMetrics(wnode, stationNodes)
	local ware = wnode.scvware
	local producers, consumers = {}, {}
	for sid, node in pairs(stationNodes) do
		local w = node.wares[ware]
		if w then
			if SCV_Graph.metricOutput(w) then producers[#producers + 1] = sid end
			if SCV_Graph.metricInput(w) then consumers[#consumers + 1] = sid end
		end
	end
	table.sort(producers); table.sort(consumers)
	wnode.metricProducers, wnode.metricConsumers = producers, consumers
	wnode.contributorSignature = table.concat(producers, "|") .. ":" .. table.concat(consumers, "|")
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

function SCV_Graph.metricOutput(w)
	if w.metricOutput ~= nil then return w.metricOutput end
	return not not w.output
end

function SCV_Graph.metricInput(w)
	if w.metricInput ~= nil then return w.metricInput end
	return not not w.input
end

-- Capture all source roles, including boundary wares and nodes hidden by the budget.
-- This baseline is immutable until the user rebuilds the view.
function SCV_Graph.captureStructure(stations)
	local structure = {}
	for _, st in ipairs(stations) do
		local roles = {}
		for ware, w in pairs(st.wares or {}) do
			roles[ware] = { input = not not w.input, output = not not w.output,
				metricOutput = SCV_Graph.metricOutput(w), inputProvenance = w.inputProvenance,
				exportState = w.export and w.export.state }
		end
		structure[st.id] = roles
	end
	return structure
end

local function sameRole(w, role)
	return w and (not not w.input == role.input) and (not not w.output == role.output)
		and w.inputProvenance == role.inputProvenance and (w.export and w.export.state) == role.exportState
end

local function unknownWare(w)
	return { name = w.name, transport = w.transport, input = w.input, output = w.output,
		metricOutput = SCV_Graph.metricOutput(w), metricInput = SCV_Graph.metricInput(w),
		inputProvenance = w.inputProvenance, export = w.export and { state = "unknown" } or nil,
		rateBasis = w.rateBasis,
		stock = 0, limit = 0, capacityUnits = 0, prodMax = 0, consMax = 0,
		production = 0, consumption = 0, workforce = 0, incoming = 0, outgoing = 0,
		stockKnown = false, limitKnown = false, capacityUnitsKnown = false, prodKnown = false,
		consKnown = false, workforceKnown = false, reservationsKnown = false }
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
			node.logistics = available and st.logistics or nil
			for ware, w in pairs(node.wares) do
				local fresh = available and st.wares[ware]
				-- Export visibility may change while accounting remains readable.
				if not fresh or SCV_Graph.metricOutput(fresh) ~= roles[ware].metricOutput then fresh = unknownWare(w) end
				-- Preserve the displayed names, transport and role; only values change.
				local name, transport, input, output = w.name, w.transport, w.input, w.output
				local provenance = w.inputProvenance
				local keepDemand = SCV_Graph.metricInput(w) and not fresh.consKnown
				if fresh ~= w then
					for key in pairs(w) do w[key] = nil end
					for key, value in pairs(fresh) do w[key] = value end
				end
				w.name, w.transport, w.input, w.output = name, transport, input, output
				w.inputProvenance = provenance
				if keepDemand then w.metricInput = true end
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
			code      = st.code,
			warningPolicy = options.isWarningIgnored,
			name      = st.name,
			type      = "container",
			wares     = st.wares or {},
			logistics = st.logistics,
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

	local producersOf, consumersOf, metricProducersOf, metricConsumersOf = {}, {}, {}, {}
	for _, st in ipairs(stations) do
		for ware, w in pairs(st.wares or {}) do
			if SCV_Graph.metricOutput(w) then
				metricProducersOf[ware] = metricProducersOf[ware] or {}
				metricProducersOf[ware][#metricProducersOf[ware] + 1] = st.id
			end
			if SCV_Graph.metricInput(w) then
				metricConsumersOf[ware] = metricConsumersOf[ware] or {}
				metricConsumersOf[ware][#metricConsumersOf[ware] + 1] = st.id
			end
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

	-- Record the boundary even when an output has its own node. "Nobody here supplies this"
	-- and "nobody here takes this" are frequently the actually-useful finding.
	for _, st in ipairs(stations) do
		local node = stationNodes[st.id]
		for ware, w in pairs(st.wares or {}) do
			if w.input and (not metricProducersOf[ware]) then
				node.unmet[#node.unmet + 1] = ware
			end
			if w.output and (not metricConsumersOf[ware]) then
				node.unsold[#node.unsold + 1] = ware
			end
		end
		table.sort(node.unmet)
		table.sort(node.unsold)
	end

	local edges = {}
	local visibleWares = {}
	for ware in pairs(metricProducersOf) do
		if producersOf[ware] or consumersOf[ware] then visibleWares[#visibleWares + 1] = ware end
	end
	table.sort(visibleWares)
	for _, ware in ipairs(visibleWares) do
		local producers = producersOf[ware] or {}
		local consumers = consumersOf[ware] or {}
		do
			local sample
			for _, sid in ipairs(metricProducersOf[ware]) do
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
				edges[#edges + 1] = { from = wnode, to = stationNodes[sid], rank = rank, ware = ware,
					inputProvenance = stationNodes[sid].wares[ware].inputProvenance }
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
	if not options.deferBudget then SCV_Graph.applyBudget(graph, options) end
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
	local outgoing, incoming = {}, {}
	for _, node in ipairs(graph.nodes) do outgoing[node], incoming[node] = {}, {} end
	for _, edge in ipairs(graph.edges) do
		table.insert(outgoing[edge.from], edge)
		table.insert(incoming[edge.to], edge)
	end
	-- Iterative Kosaraju: recompute components after each individual cut.
	local function components()
		local visited, order, component, sizes = {}, {}, {}, {}
		for _, root in ipairs(graph.nodes) do
			if not visited[root] then
				visited[root] = true
				local stack = { { node = root, index = 1 } }
				while #stack > 0 do
					local top = stack[#stack]
					local edge = outgoing[top.node][top.index]
					if edge then
						top.index = top.index + 1
						if not edge.dropped and not visited[edge.to] then
							visited[edge.to] = true
							stack[#stack + 1] = { node = edge.to, index = 1 }
						end
					else
						order[#order + 1], stack[#stack] = top.node, nil
					end
				end
			end
		end
		for i = #order, 1, -1 do
			local root = order[i]
			if not component[root] then
				local id, stack = #sizes + 1, { root }
				component[root], sizes[id] = id, 0
				while #stack > 0 do
					local node = table.remove(stack)
					sizes[id] = sizes[id] + 1
					for _, edge in ipairs(incoming[node]) do
						if not edge.dropped and not component[edge.from] then
							component[edge.from] = id
							stack[#stack + 1] = edge.from
						end
					end
				end
			end
		end
		return component, sizes
	end
	local function less(a, b)
		local ar, br = a.inputProvenance == "workforce" and 0 or 1, b.inputProvenance == "workforce" and 0 or 1
		if ar ~= br then return ar < br end
		if a.ware ~= b.ware then return a.ware < b.ware end
		local ac = a.to.code and a.to.code ~= "" and a.to.code or tostring(a.to.scvid)
		local bc = b.to.code and b.to.code ~= "" and b.to.code or tostring(b.to.scvid)
		if ac ~= bc then return ac < bc end
		return tostring(a.to.scvid) < tostring(b.to.scvid)
	end
	local removed = {}
	while true do
		local component, sizes = components()
		local candidate
		for _, edge in ipairs(graph.edges) do
			if not edge.dropped and edge.from.scvkind == "ware" and edge.to.scvkind == "station"
				and component[edge.from] == component[edge.to]
				and (sizes[component[edge.from]] > 1 or edge.from == edge.to)
				and (not candidate or less(edge, candidate)) then candidate = edge end
		end
		if not candidate then break end
		candidate.dropped = true
		removed[#removed + 1] = candidate
	end
	local function reaches(start, target)
		local seen, stack = { [start] = true }, { start }
		while #stack > 0 do
			local node = table.remove(stack)
			if node == target then return true end
			for _, edge in ipairs(outgoing[node]) do
				if not edge.dropped and not seen[edge.to] then
					seen[edge.to] = true
					stack[#stack + 1] = edge.to
				end
			end
		end
		return false
	end
	for i = #removed, 1, -1 do
		local edge = removed[i]
		if not reaches(edge.to, edge.from) then edge.dropped = nil end
	end
	local kept, dropped = {}, {}
	for _, edge in ipairs(graph.edges) do
		if not edge.dropped then kept[#kept + 1] = edge end
	end
	for _, edge in ipairs(removed) do
		if edge.dropped then dropped[#dropped + 1] = edge end
	end
	graph.edges, graph.droppedEdges = kept, dropped
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

-- The injected native layout mutates predecessor maps. Rebuild them from logical
-- edges for EVERY trial; never feed its old junctions into another layout pass.
function SCV_Graph.fitLayout(graph, layout, limits)
	limits = limits or SCV_Graph.LIMITS
	local sourceEdges, hidden, removed = graph.edges, {}, {}
	local function endpoints()
		local present = {}
		for _, node in ipairs(graph.nodes) do present[node] = true end
		return present
	end
	local function measure()
		local present, edges = endpoints(), {}
		for _, edge in ipairs(sourceEdges) do
			if present[edge.from] and present[edge.to] and not hidden[edge] then edges[#edges + 1] = edge end
		end
		graph.edges = edges
		SCV_Graph.materializePredecessors(graph)
		local rows, cols, junctions = layout(graph.nodes)
		local result = { rows = rows, cols = cols, junctions = junctions,
			postNodes = #graph.nodes + #junctions, postEdges = 0, positions = {} }
		for _, node in ipairs(graph.nodes) do
			result.positions[node] = { row = node.row, col = node.col, predecessors = node.predecessors }
			for _ in pairs(node.predecessors or {}) do result.postEdges = result.postEdges + 1 end
		end
		for _, node in ipairs(junctions) do
			for _ in pairs(node.predecessors or {}) do result.postEdges = result.postEdges + 1 end
		end
		result.fits = cols <= limits.maxCols and result.postNodes <= limits.maxNodes and result.postEdges <= limits.maxEdges
		return result
	end
	local result = measure()
	local initial = { nodes = result.postNodes, edges = result.postEdges, cols = result.cols }
	while not result.fits do
		local present, candidates = endpoints(), {}
		-- Follow only routing junctions backwards; stop at other real nodes.
		local function segments(edge)
			local stack = { { node = edge.to, distance = 0 } }
			local seen = {}
			while #stack > 0 do
				local item = table.remove(stack)
				if item.node == edge.from then return item.distance end
				if not seen[item.node] and (item.node == edge.to or not present[item.node]) then
					seen[item.node] = true
					for pred in pairs(item.node.predecessors or {}) do
						stack[#stack + 1] = { node = pred, distance = item.distance + 1 }
					end
				end
			end
			return 1
		end
		for _, edge in ipairs(graph.edges) do
			if edge.from.scvkind == "ware" and edge.to.scvkind == "station" then
				candidates[#candidates + 1] = { edge = edge, segments = segments(edge) }
			end
		end
		table.sort(candidates, function (a, b)
			local x, y = a.edge, b.edge
			local xp, yp = x.inputProvenance == "workforce" and 0 or 1, y.inputProvenance == "workforce" and 0 or 1
			if xp ~= yp then return xp < yp end
			if a.segments ~= b.segments then return a.segments > b.segments end
			if x.ware ~= y.ware then return x.ware < y.ware end
			local xc = x.to.code and x.to.code ~= "" and x.to.code or tostring(x.to.scvid)
			local yc = y.to.code and y.to.code ~= "" and y.to.code or tostring(y.to.scvid)
			if xc ~= yc then return xc < yc end
			return tostring(x.to.scvid) < tostring(y.to.scvid)
		end)
		if candidates[1] then
			local edge = candidates[1].edge
			hidden[edge] = true
			removed[#removed + 1] = edge
		else
			-- Inputs alone could not fit. Reuse the existing common-ware/station
			-- fallback, reducing at least one real node before measuring again.
			local count = #graph.nodes
			SCV_Graph.applyBudget(graph, { limits = { maxNodes = count - 1, maxEdges = #graph.edges } })
			if #graph.nodes >= count then break end
		end
		result = measure()
	end
	local present = endpoints()
	if result.fits then
		for i = #removed, 1, -1 do
			local edge = removed[i]
			if present[edge.from] and present[edge.to] then
				hidden[edge] = nil
				local trial = measure()
				if trial.fits then
					result = trial
				else
					hidden[edge] = true
				end
			end
		end
	end
	-- Restore the last accepted native result after rejected restoration trials.
	-- Keeping its maps avoids an unnecessary (potentially different) final layout.
	for node, position in pairs(result.positions) do
		node.row, node.col, node.predecessors = position.row, position.col, position.predecessors
	end
	graph.edges, graph.budgetDroppedEdges = {}, {}
	for _, edge in ipairs(sourceEdges) do
		if present[edge.from] and present[edge.to] and not hidden[edge] then graph.edges[#graph.edges + 1] = edge end
	end
	for _, edge in ipairs(removed) do
		if hidden[edge] and present[edge.from] and present[edge.to] then
			graph.budgetDroppedEdges[#graph.budgetDroppedEdges + 1] = edge
		end
	end
	graph.counts = { nodes = #graph.nodes, edges = #graph.edges }
	result.initial, result.positions = initial, nil
	return result
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
				local hasIn = false
				for _, e in ipairs(graph.edges) do
					if e.to == n then hasIn = true end
				end
				-- Hidden local suppliers can back an input-only shared ware node.
				local hiddenSupply, hasOut = false, false
				for _, sid in ipairs(n.metricProducers or {}) do
					local st = (graph.metricStations or graph.stationNodes)[sid]
					local w = st and st.wares[n.scvware]
					if w and not w.output then hiddenSupply = true end
				end
				for _, e in ipairs(graph.edges) do if e.from == n then hasOut = true end end
				-- A producer-backed terminal output is valid without outgoing edges.
				if not hasIn and not (hiddenSupply and hasOut) then
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
