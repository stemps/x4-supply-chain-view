-- Exercise the real scheduler -> logistics reader -> MD mailbox -> graph ->
-- displayed-text path. Only native reads, rendering and time are simulated.
local oldRead, oldDescribe = SCV_Data.readStation, SCV_Data.describe
local oldDisplay, oldStatus, oldStrip = menu.display, menu.updateStatusStrip, menu.updateLogisticsStrip
local members, initial, reads = {}, {}, {}
local count, cycle = 30, 0
for i = 1, count do
	local id, ship = "coverage" .. i, "coverageShip" .. i
	world[id] = { code = "COV-" .. i, owned = true, children = { ship }, drones = i }
	world[ship] = { purpose = "trade", size = "m", orders = 0, children = {} }
	members[i] = { id = id, id64 = id, code = world[id].code, name = id }
	initial[i] = { id = id, name = id, wares = {} }
end
SCV_Data.describe = function (id) return { id = id, id64 = id, code = world[id].code } end
SCV_Data.readStation = function (st)
	reads[st.id] = (reads[st.id] or 0) + 1
	return { id = st.id, name = st.name, wares = {}, logistics = SCV_Data.readLogistics(st.id64) }
end
menu.display = function () error("refresh coverage must not redraw the chart") end
menu.updateStatusStrip, menu.updateLogisticsStrip = function () end, function () end
menu.frame, menu.expandedMenuFrame, menu.expandedNode = nil, nil, nil
menu.closed, menu.mode, menu.scanDone, menu.refresh = false, "chain", true, nil
menu.graph = SCV_Graph.build(initial)
local graph = menu.graph
menu.refreshState = SCV_Data.newRefresh(members, now)
SCV_Data.startLogistics(menu.onDockMetrics)
local received = {}
local function reply(request, i)
	local total = cycle * 100 + i
	deliver({ [request[2]] = { world[request[1]].code, i, total, i, total + 1, i, total + 2 } })
	received[request[1]] = (received[request[1]] or 0) + 1
end
for sweep = 1, 3 do
	cycle = sweep
	local start = math.max(now + 0.2, menu.refreshState.nextStart)
	local batch = {}
	for i, st in ipairs(members) do
		world[st.id].drones = cycle * 1000 + i
		world["coverageShip" .. i].orders = cycle % 2
		now = start + (i - 1) * 0.2
		local before = #requests
		menu.onUpdate()
		assert(#requests == before + 1 and requests[#requests][1] == st.id,
			"scheduler skipped or duplicated station " .. st.id)
		batch[#batch + 1] = { request = requests[#requests], index = i }
		-- Coalesce replies in reverse order, leaving the final batch pending
		-- until AFTER the complete metrics snapshot becomes visible.
		if i % 5 == 0 and i < count then
			for j = #batch, 1, -1 do reply(batch[j].request, batch[j].index) end
			batch = {}
		end
	end
	assert(menu.refreshState.pending == nil and menu.graph == graph)
	local last = graph.stationNodes[members[count].id].logistics
	if cycle == 1 then
		assert(next(last.docks) == nil, "first sample is unknown until its reply arrives")
	else
		assert(last.docks.s.total == (cycle - 1) * 100 + count, "pending refresh retains the previous count")
	end
	for j = #batch, 1, -1 do reply(batch[j].request, batch[j].index) end
	for i, st in ipairs(members) do
		local node = assert(graph.stationNodes[st.id])
		local data = node.logistics
		assert(reads[st.id] == cycle and received[st.id] == cycle, "incomplete station coverage: " .. st.id)
		assert(SCV_Data.cache[st.id].logistics == data, "cache/graph detached: " .. st.id)
		assert(data.docks.s.total == cycle * 100 + i and data.drones == cycle * 1000 + i)
		local expectedIdle = cycle % 2 == 0 and 1 or 0
		assert(data.traders.m.idle == expectedIdle)
		local dockText, droneText, idleText
		for _, entry in ipairs(node.logisticsRows[1].entries) do
			if entry.text:find("S\n", 1, true) then dockText = entry.text end
			if entry.text:find("ship_xs_drone_trade_01", 1, true) then droneText = entry.text end
			if entry.text:find("ships_idling_01", 1, true) then idleText = entry.text end
		end
		assert(dockText and dockText:find(i .. "/" .. (cycle * 100 + i), 1, true), "dock text stale: " .. st.id)
		assert(droneText and droneText:find(tostring(cycle * 1000 + i), 1, true), "drone text stale: " .. st.id)
		assert(idleText and idleText:find("\n" .. expectedIdle, 1, true), "idle text stale: " .. st.id)

	end
end
-- Trace instrumentation is gone; coverage is checked directly above.
SCV_Data.stopLogistics()
SCV_Data.readStation, SCV_Data.describe = oldRead, oldDescribe
menu.display, menu.updateStatusStrip, menu.updateLogisticsStrip = oldDisplay, oldStatus, oldStrip
menu.graph, menu.refreshState = nil, nil
for i = 1, count do world["coverage" .. i], world["coverageShip" .. i] = nil, nil end
print("PASS refresh coverage: 30/30 stations, 3 cycles, 90 reads/replies, per-station dock/drone/idle text")
