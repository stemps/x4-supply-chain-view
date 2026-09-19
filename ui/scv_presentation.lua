-- Supply Chain View presentation: text generation and native text measurement.
-- Depends: scv_graph.lua, scv_text.lua

SCV_Presentation = {}

-- dispatch preserves the menu facade as the override point for UI integrations.
function SCV_Presentation.new(config, dispatch)
	local ffi = require("ffi")
	local C = ffi.C
	local presentation = {}
	local menu = dispatch or presentation

	local T = SCV_Text.forPage(config.textPage)

	-- Stable markers shared by captions, tooltips and the footer. Markers live in
	-- one registry rather than being embedded in translated sentences.
	local footnotes = {
		{ key = "partial", marker = "*", legend = 3166, tooltip = 3164 },
		{ key = "cycle", marker = "[1]", legend = 3195 },
		{ key = "budget", marker = "[2]", legend = 3196 },
	}
	local function footnote(key)
		for _, entry in ipairs(footnotes) do if entry.key == key then return entry end end
		error("unknown footnote: " .. tostring(key))
	end
	local function markFootnote(text, key)
		return T(3157, text, footnote(key).marker)
	end
	local function footnoteLine(key, tooltip)
		local entry = footnote(key)
		return entry.marker .. " " .. T(tooltip and entry.tooltip or entry.legend)
	end
	local function footnoteMarkers(keys)
		local markers = {}
		for _, entry in ipairs(footnotes) do
			if keys[entry.key] then markers[#markers + 1] = entry.marker end
		end
		return #markers > 0 and (" " .. table.concat(markers)) or ""
	end
	presentation.footnotes = footnotes
	presentation.markFootnote = markFootnote
	presentation.footnoteLine = footnoteLine
	presentation.footnoteMarkers = footnoteMarkers

	local function logisticsTint(text, severity)
		local color = severity == "critical" and "text_error" or severity == "warning" and "text_warning" or nil
		return color and (Helper.convertColorToText(Color[color]) .. text .. "\27X") or text
	end

	local function logisticsCount(value, known)
		return known and tostring(value) or "?"
	end

	local function logisticsIdleLabel(idle, total, percent)
		-- Also handle translations cached before /reloadui; native font lacks this dash.
		return (T(3173, idle, total, percent):gsub("—", "-"):gsub("–", "-"))
	end

	local function dockLabel(logistics, size, includeSize)
		local dock = logistics and logistics.docks and logistics.docks[size]
		local text = (includeSize and string.upper(size) .. " " or "") .. (dock and (dock.free .. "/" .. dock.total) or "?/?")
		return logisticsTint(text, dock and dock.total > 0 and dock.free == 0 and "warning" or "ok")
	end

	function presentation.idleText(logistics)
		local totals = SCV_Graph.logisticsTotals(logistics)
		-- Never round a sub-threshold ratio up to a displayed 50% or 75%.
		local percent = totals.idleKnown and (totals.total > 0 and string.format("%.1f%%", math.floor(1000 * totals.idle / totals.total) / 10) or "0.0%") or "?"
		return logisticsIdleLabel(logisticsCount(totals.idle, totals.idleKnown), logisticsCount(totals.total, totals.shipsKnown), percent)
	end

	-- Each icon/count pair is a separate native text widget with its own mouseover.
	-- Size/purpose rank and icon preference match the map's property-owned list.
	function presentation.logisticsEntries(logistics)
		local data, entries = logistics or {}, {}
		entries[1] = { text = "\27[stationbuildst_dock]", header = "\27[stationbuildst_dock]", count = "",
			tip = T(3180) .. "\n\n" .. T(3171) .. "\n\n" .. T(3179) .. "\n\n" .. T(3172) }
		for _, size in ipairs({ "s", "m", "l" }) do
			local dock = data.docks and data.docks[size]
			entries[#entries + 1] = {
				text = dockLabel(data, size, true),
				color = dock and dock.total > 0 and dock.free == 0 and Color.text_warning or nil,
				tip = T(3180) .. " " .. string.upper(size) .. ": " .. dockLabel(data, size, false)
					.. "\n\n" .. T(3171) .. "\n\n" .. T(3179) .. "\n\n" .. T(3172) .. (not data.shipsKnown and ("\n\n" .. T(3181)) or ""),
			}
		end
		entries[#entries + 1] = { text = "\27[ship_xs_drone_trade_01] " .. logisticsCount(data.drones, data.drones ~= nil), color = data.factionColor,
			groupStart = true,
			tip = T(3178) .. ": " .. logisticsCount(data.drones, data.drones ~= nil) }
		local categories = {}
		if data.shipsKnown then
			for _, bucket in pairs(data.categories or {}) do
				if bucket.total > 0 then categories[#categories + 1] = bucket end
			end
		end
		table.sort(categories, function (a, b) return a.rank > b.rank end)
		for _, bucket in ipairs(categories) do
			local name = bucket.name or (string.upper(bucket.size) .. " " .. bucket.purpose)
			local percent = not bucket.idleUnknown and string.format("%.1f%%", math.floor(1000 * bucket.idle / bucket.total) / 10) or "?"
			entries[#entries + 1] = { text = "\27[" .. (bucket.icon or "ship_m_transporter_01") .. "] " .. bucket.total,
				color = data.factionColor,
				tip = string.upper(bucket.size) .. ": " .. name .. ": " .. bucket.total .. "\n\n"
					.. logisticsIdleLabel(logisticsCount(bucket.idle, not bucket.idleUnknown), tostring(bucket.total), percent) .. "\n\n" .. T(3174) }
		end
		if not data.shipsKnown then
			entries[#entries + 1] = { text = "\27[ship_m_transporter_01] ?", color = data.factionColor, tip = T(3181) }
		end
		local totals = SCV_Graph.logisticsTotals(data)
		entries[#entries + 1] = { text = logisticsTint("\27[ships_idling_01] " .. logisticsCount(totals.idle, totals.idleKnown), totals.severity),
			color = totals.severity == "critical" and Color.text_error or totals.severity == "warning" and Color.text_warning or nil,
			tip = T(3176) .. " + " .. T(3177) .. "\n\n" .. menu.idleText(data) .. "\n\n" .. T(3174) .. "\n\n" .. T(3175) }
		return entries
	end

	function presentation.logisticsRows(logistics)
		local entries = {}
		local scale = Helper.uiScale or (Helper.scaleY(1000) / 1000)
		local fontsize = Helper.scaleFont and Helper.scaleFont(Helper.standardFont, config.logisticsFontSize) or math.ceil(config.logisticsFontSize * scale)
		local height = 2 * fontsize + 4 * scale
		for _, entry in ipairs(menu.logisticsEntries(logistics)) do
			if entry.groupStart then entries[#entries + 1] = { text = "", tip = "", width = 10 * scale } end
			-- Keep colour escapes on both lines, including a trailing native reset.
			local header, count = entry.text:match("^(.*) ([^ ]+)$")
			header, count = entry.header or header, entry.count or count
			entry.text = header .. "\n" .. count
			local ok, w = pcall(function ()
				return math.max(C.GetTextWidth(header, Helper.standardFont, fontsize), C.GetTextWidth(count, Helper.standardFont, fontsize))
			end)
			entry.width = math.ceil((ok and w or 40 * scale) + 4 * scale)
			local hok, h = pcall(function () return C.GetTextHeight(entry.text, Helper.standardFont, fontsize, 0) end)
			if hok then height = math.max(height, math.ceil(h)) end
			entries[#entries + 1] = entry
		end
		return { { entries = entries, height = height } }
	end

	local function severityColor(severity)
		if severity == "critical" then
			return Color["icon_error"]
		elseif severity == "warning" then
			return Color["icon_warning"]
		end
		return nil
	end

	-- Compact amounts: a chain deals in tens of thousands, and "12400" in a node status is
	-- noise where "12.4k" is a number you can read at a glance.
	local function formatAmount(n)
		n = tonumber(n) or 0
		local a = math.abs(n)
		if a >= 1000000 then
			return string.format("%.1fM", n / 1000000)
		elseif a >= 1000 then
			return string.format("%.1fk", n / 1000)
		end
		return string.format("%.0f", n)
	end

	local function formatRate(n)
		return T(5003, formatAmount(n))
	end

	local function formatSigned(n)
		if n == nil then return T(5003, "? ") end
		return (n > 0 and "+" or "") .. formatRate(n)
	end

	local function formatPartial(n, known, rate)
		local value = rate and formatRate(n) or formatAmount(n)
		if known then return value end
		return (n or 0) > 0 and (value .. " + ?") or (rate and T(5003, "? ") or "?")
	end

	-- Compact partial notation is confined to collapsed ware labels.
	local function aggregateStatus(node)
		local color = Color["text_inactive"]
		if node.netKnown then
			if node.netRate > 0 then color = Color["text_positive"]
			elseif node.netRate < 0 then color = config.consumptionColor end
			local text = formatSigned(node.netRate)
			if node.demandCap > 0 then
				text = text .. string.format(" (%+.0f%%)", node.netRate / node.demandCap * 100)
			end
			return text, color
		end
		-- Incomplete sides are subtotals, never a basis for a signed net balance.
		local supply, demand = node.supplyCap or 0, node.demandCap or 0
		local function side(value, isInput)
			return markFootnote(T(isInput and 3156 or 3155, formatRate(value)), "partial"), isInput and config.consumptionColor or Color["text_positive"]
		end
		if node.supplyKnown and supply > 0 then return side(supply, false) end
		if node.demandKnown and demand > 0 then return side(demand, true) end
		if not node.supplyKnown and not node.demandKnown and supply > 0 and demand > 0 then
			local supplyText = Helper.convertColorToText(Color["text_positive"]) .. T(3155, formatAmount(supply)) .. "\27X"
			local demandText = Helper.convertColorToText(config.consumptionColor) .. T(3156, formatAmount(demand)) .. "\27X"
			return markFootnote(T(3159, supplyText, demandText), "partial"), color
		end
		if supply > 0 then return side(supply, false) end
		if demand > 0 then return side(demand, true) end
		if node.supplyKnown then return side(0, false) end
		if node.demandKnown then return side(0, true) end
		return formatSigned(nil), color
	end

	-- Hours as something readable. Below an hour, minutes are what you act on.
	local function formatHours(hours)
		if not hours then
			return T(5002)
		end
		if hours < 1 then
			return T(5001, tostring(math.max(1, math.floor(hours * 60))))
		end
		return T(5000, string.format("%.1f", hours))
	end

	-- Native mouseovers use explicit newlines. Keep qualifications beside the metric
	-- they qualify, with operating assumptions in a separate final block.
	local function rateAssumptions(isInput, continuous)
		local lines = { T(3140), T(3141) }
		if continuous then lines[#lines + 1] = T(3127) end
		lines[#lines + 1] = T(isInput and 3142 or 3143)
		return table.concat(lines, "\n")
	end

	local function stockTooltip(subject, w, b)
		local capacityKnown = b.capacityKnown
		local capacity = capacityKnown and ((b.estimated and "~" or "") .. formatAmount(b.capacity)) or "?"
		local lines = { subject, "", T(3041, b.stockKnown and formatAmount(b.start) or "?", capacity) }
		if not b.stockKnown then lines[#lines + 1] = T(3152) end
		if not capacityKnown then
			lines[#lines + 1] = T(3046)
		elseif b.estimated then
			lines[#lines + 1] = T(3045)
			lines[#lines + 1] = T(3146)
		end
		if b.incoming > 0 then lines[#lines + 1] = T(3042, formatAmount(b.incoming)) end
		if b.outgoing > 0 then lines[#lines + 1] = T(3043, formatAmount(b.outgoing)) end
		if b.incoming > 0 or b.outgoing > 0 then
			lines[#lines + 1] = T(3044, b.stockKnown and b.reservationsKnown and formatAmount(b.current) or "?")
		end
		if not b.reservationsKnown then lines[#lines + 1] = T(3064) end
		return table.concat(lines, "\n")
	end

	local function aggregateStockTooltip(subject, storage)
		local lines = { subject, "", T(3041, formatPartial(storage.stock, storage.stockKnown),
			(storage.estimated and "~" or "") .. formatPartial(storage.capacity, storage.capacityKnown)) }
		if not storage.stockKnown or not storage.capacityKnown then
			lines[#lines + 1] = T(3082)
			lines[#lines + 1] = T(3088)
		end
		if storage.estimated then
			lines[#lines + 1] = T(3045)
			lines[#lines + 1] = T(3146)
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = T(3083)
		lines[#lines + 1] = T(3147)
		return table.concat(lines, "\n")
	end

	local function aggregateRateLine(value, known, isInput)
		local line = T(isInput and 3035 or 3036, formatPartial(value, known, true))
		if not known then line = line .. "\n" .. T(3088) end
		return line
	end

	local function hasContinuousDemand(graph, node)
		for _, sid in ipairs(node.metricConsumers or node.consumers or {}) do
			local station = graph and (graph.metricStations or graph.stationNodes)[sid]
			local ware = station and station.wares[node.scvware]
			if ware and ware.rateBasis == "continuousProcessing" then return true end
		end
		return false
	end

	local function rateTooltip(subject, w, m, isInput)
		local continuous = isInput and w.rateBasis == "continuousProcessing"
		local lines = { subject, "", T(isInput and 3035 or 3036,
			m.rateKnown and formatRate(m.rate) or T(5003, "? ")) }
		if not m.rateKnown then
			lines[#lines + 1] = T(continuous and 3126 or 3037)
			return table.concat(lines, "\n")
		end
		local parts = continuous and w.consumptionParts
		if parts then
			lines[#lines + 1] = "  " .. T(3128, formatRate(parts.processing))
			lines[#lines + 1] = "  " .. T(3129, formatRate(parts.production))
			if parts.workforce > 0 then lines[#lines + 1] = "  " .. T(3130, formatRate(parts.workforce)) end
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = rateAssumptions(isInput, continuous)
		return table.concat(lines, "\n")
	end

	local function coverageTooltip(subject, w, m, isInput, fullTime, fillTime)
		local continuous = isInput and w.rateBasis == "continuousProcessing"
		local lines = { subject, "", T(isInput and 3070 or 3071) }
		if isInput then
			lines[#lines + 1] = T(3092, m.stockHours and formatHours(m.stockHours) or "?")
			lines[#lines + 1] = T(3149, fullTime)
		else
			lines[#lines + 1] = T(3093, fillTime)
			lines[#lines + 1] = T(3150, fullTime)
		end
		if not m.rateKnown then lines[#lines + 1] = T(continuous and 3126 or 3037) end
		if not m.bar.stockKnown then lines[#lines + 1] = T(3152) end
		if not m.bar.capacityKnown then
			lines[#lines + 1] = T(3046)
		elseif m.bar.estimated then
			lines[#lines + 1] = T(3045)
			lines[#lines + 1] = T(3146)
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = rateAssumptions(isInput, continuous)
		lines[#lines + 1] = T(isInput and 3148 or 3098)
		return table.concat(lines, "\n")
	end

	local function warningReason(name, health, context)
		if not health or health.severity == "ok" then return nil end
		local threshold = health.severity == "critical" and SCV_Graph.THRESHOLDS.criticalHours
			or SCV_Graph.THRESHOLDS.warningHours
		local lines = { name, T(3090), "",
			T(3092, formatHours(health.hours)),
			T(3094, T(health.severity == "critical" and 3067 or 3068), formatHours(threshold)) }
		if context and #context > 0 then
			lines[#lines + 1] = ""
			for _, line in ipairs(context) do lines[#lines + 1] = line end
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = T(3095)
		lines[#lines + 1] = T(3097)
		return table.concat(lines, "\n")
	end

	presentation.logisticsTint = logisticsTint
	presentation.logisticsCount = logisticsCount
	presentation.logisticsIdleLabel = logisticsIdleLabel
	presentation.dockLabel = dockLabel
	presentation.T = T
	presentation.severityColor = severityColor
	presentation.formatAmount = formatAmount
	presentation.formatRate = formatRate
	presentation.formatSigned = formatSigned
	presentation.formatPartial = formatPartial
	presentation.aggregateStatus = aggregateStatus
	presentation.formatHours = formatHours
	presentation.rateAssumptions = rateAssumptions
	presentation.stockTooltip = stockTooltip
	presentation.aggregateStockTooltip = aggregateStockTooltip
	presentation.aggregateRateLine = aggregateRateLine
	presentation.hasContinuousDemand = hasContinuousDemand
	presentation.rateTooltip = rateTooltip
	presentation.coverageTooltip = coverageTooltip
	presentation.warningReason = warningReason
	return presentation
end
