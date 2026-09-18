-- Metric sizing and alignment, independent of rendering widgets.
local scale=1
Helper.standardFont="Zekton"
Helper.scaleX=function(v) return v*scale end
Helper.scaleY=Helper.scaleX
Helper.scaleFont=function(_,v) return math.ceil(v*scale) end
-- The reported examples, plus long values and unknowns, must fit both lines.
for _, example in ipairs({
	{ s = { free=20,total=20 }, m={free=6,total=8}, l={free=8,total=9}, drones=60 },
	{ s = { free=30,total=30 }, m={free=12,total=12}, l={free=15,total=20}, drones=143 },
	{ s = { free=1234,total=12345 }, m={free=0,total=100}, l={free=0,total=0}, drones=999 },
	{},
}) do
	for _, uiScale in ipairs({1, 1.25, 1.5, 2}) do
		scale = uiScale
		local data = {docks=example, drones=example.drones, shipsKnown=true, categories={}}
		local rows = menu.logisticsRows(data)
		assert(#rows == 1 and #rows[1].entries == 7, "zero ship categories occupy no metric columns")
		for _, entry in ipairs(rows[1].entries) do
			if entry.text ~= "" then
				local header, count = entry.text:match("^(.-)\n(.*)$")
				assert(header and count)
				for _, line in ipairs({header,count}) do
					assert(C.GetTextWidth(line, Helper.standardFont, Helper.scaleFont(nil, 8)) + 4*scale <= entry.width)
				end
				assert(C.GetTextHeight(entry.text, Helper.standardFont, Helper.scaleFont(nil, 8), 0) <= rows[1].height)
			end
		end
	end
end
scale = 1
local snapshot = SCV_Data.readLogistics("A")
local function node(id, col)
	return { scvkind = "station", col = col, logistics = snapshot,
		logisticsRows = menu.logisticsRows(snapshot), [1] = { properties = {}, node = { id = id } } }
end
-- Stations with fewer categories keep their final ship cell at the right edge.
local short = node("short",1)
short.logisticsRows = menu.logisticsRows({shipsKnown=true,drones=3,categories={}})
local long = node("long",1)
local alignmentGraph = {nodes={short,long}}
menu.prepareLogisticsColumns(alignmentGraph)
local sharedCount = #long.logisticsRows[1].entries
assert(#short.logisticsRows[1].entries == sharedCount)
assert(short.logisticsRows[1].entries[sharedCount].text:find("ships_idling_01",1,true))
assert(short.logisticsRows[1].entries[sharedCount-1].text:find("ship_xs_drone_trade_01",1,true))
assert(short.logisticsRows[1].entries[sharedCount].tip:find("\n\n",1,true))
assert(not short.logisticsRows[1].entries[sharedCount].tip:find("—",1,true))
menu.prepareLogisticsColumns(alignmentGraph)
assert(#short.logisticsRows[1].entries == sharedCount, "alignment padding must not accumulate")

print("PASS logistics metric sizing: two lines, scaled counts, shared widths and alignment")
