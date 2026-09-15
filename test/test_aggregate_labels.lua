-- Public reader/graph/menu path: amounts are subtotals, not inferred net rates.
local cases = {
	{ 14400, true, 12000, true, "+2.4k/h (+20%)", "text_positive" },
	{ 50, true, 80, true, "-30/h (-38%)", "negative" },
	{ 80, true, 80, true, "0/h (+0%)", "text_inactive" },
	{ 0, true, 0, true, "0/h", "text_inactive" },
	{ 80, true, 0, true, "+80/h", "text_positive" },
	{ 0, false, 12000, true, "-12.0k/h*" },
	{ 8000, true, 0, false, "+8.0k/h*" },
	{ 8000, false, 5000, false, "+8.0k / -5.0k*" },
	{ 8000, false, 8000, false, "+8.0k / -8.0k*" },
	{ 8000, false, 0, false, "+8.0k/h*" },
	{ 0, false, 5000, false, "-5.0k/h*" },
	{ 0, false, 0, false, "? /h" },
	{ 8000, true, 5000, false, "+8.0k/h*" },
	{ 8000, false, 5000, true, "-5.0k/h*" },
	{ 0, true, 5000, false, "-5.0k/h*" },
	{ 8000, false, 0, true, "+8.0k/h*" },
	{ 0, true, 0, false, "+0/h*" },
	{ 0, false, 0, true, "-0/h*" },
	{ 2467890, false, 12449, false, "+2.5M / -12.4k*" },
	{ 0, false, 999, true, "-999/h*" },
}
local previousGraph = menu.graph
for index, case in ipairs(cases) do
	local graph = SCV_Graph.build({
		{ id = "label-supplier", name = "Supplier", wares = { ore = {
			name = "Ore", output = true, stock = 100, limit = 200,
			prodMax = case[1], prodKnown = case[2] } } },
		{ id = "label-consumer", name = "Consumer", wares = { ore = {
			name = "Ore", input = true, stock = 50, limit = 300,
			consMax = case[3], consKnown = case[4] } } },
	})
	local ware = graph.wareNodes.ore
	menu.decorateNodes(graph)
	local display, complete = ware[1], case[2] and case[4]
	assert(plainStatus(display.statusText) == case[5], index .. ": " .. display.statusText)
	assert(display.properties.width == 300 and display.properties.value == 150 and display.properties.max == 500)
	assert(display.properties.slider1 == -1 and display.properties.slider2 == -1)
	assert(ware.supplyCap == case[1] and ware.demandCap == case[3])
	assert(ware.netKnown == complete)
	if complete then
		assert(ware.netRate == case[1] - case[3])
		if case[6] == "negative" then assert(display.statuscolor.r == 255 and display.statuscolor.g == 150)
		else assert(display.statuscolor == case[6]) end
		assert(not string.find(display.properties.mouseOverText, "incomplete", 1, true))
	else
		assert(ware.netRate == nil)
		if case[5]:find("^%+[^ ]+/h%*$") then
			assert(display.statuscolor == "text_positive")
		elseif case[5]:find("^%-[^ ]+/h%*$") then
			assert(display.statuscolor.r == 255 and display.statuscolor.g == 150 and display.statuscolor.b == 150)
		else
			assert(display.statuscolor == "text_inactive")
		end
		if case[5]:find(" / ") then
			assert(display.statusText:find("\27#ff00ff00#", 1, true))
			assert(display.statusText:find("\27#ffff9696#", 1, true))
			local _, resets = display.statusText:gsub("\27X", "")
			assert(resets == 2, "each amount must reset before the unit and uncertainty marker")
		else
			assert(not display.statusText:find("\27", 1, true))
		end
		assert(not string.find(display.statusText, "%", 1, true))
		local tooltip = display.properties.mouseOverText
		assert(string.find(tooltip, "Balance unavailable: supply or demand is incomplete.", 1, true))
		assert(not string.find(tooltip, "Balance: ?", 1, true))
		local side = case[2] and "Demand is incomplete." or (case[4] and "Supply is incomplete." or "Supply and demand are incomplete.")
		assert(string.find(tooltip, side, 1, true))
		local legend = "* Known contributions only; net balance unavailable. Rates are per hour."
		if case[5] ~= "? /h" then
			assert(string.find(tooltip, legend, 1, true))
			assert(plainStatus(display.statusText):sub(-1) == "*")
		else
			assert(not string.find(tooltip, legend, 1, true))
		end
		assert(not string.find(tooltip, "A trailing +", 1, true))
		assert(not string.find(tooltip, "S = supply", 1, true))
	end
end

-- Expanded totals retain their independent directional colours and partial values.
local graph = SCV_Graph.build({
	{ id = "a", wares = { ore = { name = "Ore", output = true, prodMax = 8000, prodKnown = false } } },
	{ id = "b", wares = { ore = { name = "Ore", input = true, consMax = 5000, consKnown = false } } },
})
menu.graph = graph
local panel = tableMock()
menu.expandWare(nil, { properties = { height = 400 } }, panel, graph.wareNodes.ore)
assert(panel.rows[3][2].text == "+8.0k/h + ?" and panel.rows[3][2].props.color == "text_positive")
assert(panel.rows[4][2].text == "-5.0k/h + ?" and panel.rows[4][2].props.color.g == 150)
-- Exercise translated templates through the same formatter, not English fallbacks.
local readText = ReadText
ReadText = function(_, id) return germanTexts[id] end
local ware = graph.wareNodes.ore
menu.decorateNodes(graph)
assert(plainStatus(ware[1].statusText) == "+8.0k / -5.0k*")
assert(string.find(ware[1].properties.mouseOverText, "* Nur bekannte Beiträge; Nettobilanz nicht verfügbar. Raten pro Stunde.", 1, true))
ware.supplyKnown = true
menu.decorateNodes(graph)
assert(ware[1].statusText == "+8.0k/h*")
ware.supplyKnown, ware.demandKnown = false, true
menu.decorateNodes(graph)
assert(ware[1].statusText == "-5.0k/h*")
ReadText = readText
menu.graph = previousGraph
print("PASS partial aggregate labels, zero/unknown distinctions and German templates")

-- Wrapped legend stays below short charts and outside tall charts' scroll area.
local previousChart, border, frameBorder = menu.flowchart, Helper.borderSize, Helper.frameBorder
Helper.borderSize, Helper.frameBorder = 2, 8
for _, height in ipairs({100, 1000}) do
	for _, footerHeight in ipairs({20, 60}) do
		local footer = { properties = {} }
		function footer:getFullHeight() return footerHeight end
		function footer:addRow(selectable, props)
			assert(selectable == false and props.fixed)
			return { { createText = function(_, text, textProps)
				assert(text == "* exact balance unknown due producers/consumers with unknown or variable volume (e.g. miners or shipyards)")
				assert(textProps.wordwrap)
			end } }
		end
		local frame = { getAvailableHeight = function() return 600 end }
		function frame:addTable(columns, props)
			assert(columns == 1 and props.width == 500 and props.x == 8)
			footer.properties = props
			return footer
		end
		menu.flowchart = { properties = {} }
		function menu.flowchart:getVisibleHeight()
			return math.min(height, self.properties.maxVisibleHeight)
		end
		menu.drawChainLegend(frame, 8, 160, 500)
		assert(menu.flowchart.properties.maxVisibleHeight == 600 - 160 - footerHeight - 2 - 8)
		assert(footer.properties.y == 160 + menu.flowchart:getVisibleHeight() + 2)
		assert(footer.properties.y + footerHeight <= 592)
	end
end
menu.flowchart, Helper.borderSize, Helper.frameBorder = previousChart, border, frameBorder
assert(germanTexts[3166]:find("Bergbauschiffen oder Werften", 1, true))
print("PASS wrapped diagram legend layout")
