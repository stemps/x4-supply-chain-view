-- Supply Chain View: pure metric calculations over plain data records.
-- No engine or UI dependencies.
SCV_Metrics = {}

-- Hours of headroom below which a ware is flagged.
SCV_Metrics.THRESHOLDS = {
	criticalHours = 0.25,
	warningHours  = 0.5,
}

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

function SCV_Metrics.severityFor(hours)
	if hours < SCV_Metrics.THRESHOLDS.criticalHours then
		return "critical"
	elseif hours < SCV_Metrics.THRESHOLDS.warningHours then
		return "warning"
	end
	return "ok"
end

local SEVERITY_RANK = { ok = 0, warning = 1, critical = 2 }

function SCV_Metrics.severityRank(severity)
	return SEVERITY_RANK[severity] or 0
end

-- Only input coverage determines warning severity.
function SCV_Metrics.wareHealth(w)
	local cover = w.input and w.stockKnown ~= false and SCV_Metrics.rateKnown(w, true)
		and hoursOfCover(w.stock, w.consMax) or nil
	local severity, hours, reason = "ok", nil, nil
	if cover then
		severity, hours, reason = SCV_Metrics.severityFor(cover), cover, "starved"
	end
	if w.warningIgnored then severity, reason = "ok", nil end

	local role = "idle"
	if w.output and w.input then
		role = "both"
	elseif w.output then
		role = "output"
	elseif w.input then
		role = "input"
	end

	local known = w.stockKnown ~= false
		and (not w.input or SCV_Metrics.rateKnown(w, true))
		and (not w.output or (SCV_Metrics.rateKnown(w, false) and (w.limit or 0) > 0))
	return { role = role, severity = severity, hours = hours, reason = reason, known = known,
	         cover = cover }
end

function SCV_Metrics.validRate(value)
	local n = tonumber(value)
	return n ~= nil and n == n and n >= 0 and n < math.huge
end

-- Zero fallback capacity requires an explicit successful read. Older records can
-- establish positive capacity without a flag, but cannot establish known zero.
function SCV_Metrics.effectiveCapacity(w)
	local limit = tonumber(w.limit)
	if SCV_Metrics.validRate(limit) and limit > 0 then return limit, true, false end
	local capacity = tonumber(w.capacityUnits)
	local known = SCV_Metrics.validRate(capacity) and w.capacityUnitsKnown ~= false
		and (capacity > 0 or w.capacityUnitsKnown == true)
	return known and capacity or 0, known, known and capacity > 0
end

-- Storage is a union of participating stations, never one copy per edge/role.
function SCV_Metrics.storageTotals(stations, ware, producers, consumers)
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
					local cap, known, estimated = SCV_Metrics.effectiveCapacity(w)
					total.estimated = total.estimated or estimated
					if known then total.capacity = total.capacity + cap else total.capacityKnown = false end
				else total.stockKnown = false; total.capacityKnown = false end
			end
		end
	end
	return total
end

function SCV_Metrics.rateKnown(w, isInput)
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
function SCV_Metrics.moduleRates(products)
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
function SCV_Metrics.reservationBar(w)
	local stock    = tonumber(w.stock) or 0
	local incoming = tonumber(w.incoming) or 0
	local outgoing = tonumber(w.outgoing) or 0
	local future   = stock + incoming - outgoing
	if future < 0 then
		future = 0
	end

	local capacity, capacityKnown, estimated = SCV_Metrics.effectiveCapacity(w)
	local drawable = capacityKnown and capacity > 0
	local maxv = drawable and capacity or 1
	local stockKnown = w.stockKnown ~= false
	local reservationsKnown = w.reservationsKnown ~= false

	return {
		start     = stock,
		current   = future,
		max       = maxv,
		capacity  = capacity,
		capacityKnown = capacityKnown,
		incoming  = incoming,
		outgoing  = outgoing,
		estimated = estimated,
		unknown   = not capacityKnown or not stockKnown,
		stockKnown = stockKnown,
		reservationsKnown = reservationsKnown,
		percent = drawable and stockKnown and stock / capacity * 100 or nil,
		futurePercent = drawable and stockKnown and reservationsKnown and future / capacity * 100 or nil,
		drawStart = drawable and stockKnown and math.min(stock, capacity) or 0,
		drawCurrent = drawable and stockKnown and math.min(reservationsKnown and future or stock, capacity) or 0,
	}
end

-- The shared popup contract. Both entry points supply the same ware record and role.
function SCV_Metrics.detailMetrics(w, isInput)
	local bar = SCV_Metrics.reservationBar(w)
	local rate = isInput and w.consMax or w.prodMax
	local known = SCV_Metrics.rateKnown(w, isInput)
	local measurable = known and (rate or 0) > 0
	local positiveCapacity = bar.capacityKnown and bar.capacity > 0
	return {
		bar = bar,
		rate = rate,
		rateKnown = known,
		stockHours = measurable and bar.stockKnown and bar.start / rate or nil,
		fillHours = not isInput and measurable and bar.stockKnown and positiveCapacity
			and hoursToFull(bar.start, bar.capacity, rate) or nil,
		capacityHours = measurable and positiveCapacity and bar.capacity / rate or nil,
		sign = isInput and "-" or "+",
		severity = w.health and w.health.severity or "ok",
	}
end

function SCV_Metrics.logisticsTotals(logistics)
	local data = logistics or {}
	local result = { traders = 0, miners = 0, idle = 0,
		shipsKnown = data.shipsKnown == true, idleKnown = data.shipsKnown == true and data.idleKnown == true }
	for _, role in ipairs({ "traders", "miners" }) do
		for _, bucket in pairs(data[role] or {}) do
			result[role] = result[role] + bucket.total
			result.idle = result.idle + bucket.idle
		end
	end
	result.total = result.traders + result.miners
	result.severity = "ok"
	-- Compare integers, never a rounded display percentage. No ships is not an error.
	if result.idleKnown and result.total > 0 then
		if result.idle * 4 >= result.total * 3 then result.severity = "critical"
		elseif result.idle * 2 >= result.total then result.severity = "warning" end
	end
	return result
end

return SCV_Metrics
