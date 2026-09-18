"""Detail components retain live data and isolate screen revision caches."""
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime
from addon_loader import load_modules


for runtime in (LuaRuntime, LuaJITRuntime):
    lua = runtime(unpack_returned_tuples=True)
    load_modules(lua, "scv_details.lua")
    lua.execute("""
        Color = { text_positive = {}, row_background_unselectable = {} }
        Helper = {standardTextHeight=12, headerRow1Properties={}}
        local function tableMock()
            local t = {properties={}, rows={}}
            function t:setColWidthPercent() end
            function t:setColWidth() end
            function t:addRow(key)
                local row = {key=key}
                for i=1,4 do
                    local cell = {}
                    function cell:setColSpan() return self end
                    function cell:setBackgroundColSpan() return self end
                    function cell:createText(value, properties)
                        self.value, self.properties = value, properties
                        return self
                    end
                    row[i] = cell
                end
                self.rows[#self.rows+1] = row
                return row
            end
            return t
        end
        local count = 0
        local presentation = {
            T = function(id, first, second)
                if id == 3060 then return first .. '/' .. second end
                return tostring(id)
            end,
            formatPartial = function(amount) return tostring(amount) end,
            aggregateStockTooltip = function(_, storage)
                count = count + 1
                return tostring(storage.stock)
            end,
            hasContinuousDemand = function() return false end,
            aggregateRateLine = function() return 'rate' end,
            rateAssumptions = function() return 'assumptions' end,
        }
        local node = {name='Ore', storage={stock=4, capacity=10, stockKnown=true,
            capacityKnown=true}, supplyCap=2, demandCap=1, supplyKnown=true,
            demandKnown=true, producers={}, consumers={}}
        local first, second = {metricRevision=0}, {metricRevision=0}
        local a = SCV_Details.new(first, {}, presentation)
        local b = SCV_Details.new(second, {}, presentation)
        local ta, tb = tableMock(), tableMock()
        a.expandWare(nil, {properties={height=200}}, ta, node)
        b.expandWare(nil, {properties={height=300}}, tb, node)
        assert(ta.properties.maxVisibleHeight == 200)
        assert(tb.properties.maxVisibleHeight == 300)
        local ca, cb = ta.rows[2][1], tb.rows[2][1]
        assert(ca.value() == '4/10' and ca.properties.mouseOverText() == '4')
        assert(count == 1, 'fields of one row share a revision cache')
        assert(cb.value() == '4/10' and count == 2)
        node.storage.stock = 8
        assert(ca.value() == '4/10' and cb.value() == '4/10')
        first.metricRevision = 1
        assert(ca.value() == '8/10' and cb.value() == '4/10')
        assert(count == 3, 'only the publishing screen invalidates its cache')
        node.storage = {stock=9, capacity=12, stockKnown=true, capacityKnown=true}
        second.metricRevision = 1
        assert(cb.value() == '9/12', 'callback reads the current storage record')
        assert(ca.value() == '8/10')
    """)
    print(f"PASS details instance ownership and live fields ({runtime.__module__})")
