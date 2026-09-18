"""Presentation contracts independent of the registered menu and engine readers."""
from pathlib import Path
from addon_loader import load_modules
from lupa import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime

root = Path(__file__).resolve().parents[1]

for runtime in (LuaRuntime, LuaJITRuntime):
    lua = runtime(unpack_returned_tuples=True)
    lua.execute('''
        logs = {}
        function DebugError(s) logs[#logs+1] = s end
        texts = { [5003]='%s/h', [5002]='unknown', [5001]='%s min', [5000]='%s h',
            [3173]='%s / %s — %s', [3155]='Supply %s', [3156]='Demand %s',
            [3157]='%s (partial)', [3159]='%s / %s', [3035]='Demand: %s',
            [3088]='Incomplete', [3041]='Stock %s / %s', [3152]='Stock unknown',
            [3046]='Capacity unknown', [3064]='Reservations unknown' }
        function ReadText(page, id) return texts[id] or '=ReadText90210-' .. id .. '=' end
        Color = setmetatable({}, {__index=function(_, key) return key end})
        Helper = { standardFont='test', uiScale=1,
            scaleFont=function(_, size) return size end,
            convertColorToText=function(color) return '<' .. tostring(color) .. '>' end }
        C = {GetTextWidth=function(text) return #text end,
            GetTextHeight=function() return 20 end}
        package.loaded.ffi = { C=C }
        SCV_Graph = { THRESHOLDS={criticalHours=1,warningHours=2},
            logisticsTotals=function(data) return data end }
    ''')
    load_modules(lua, 'scv_presentation.lua', provided=('scv_graph.lua',))
    lua.execute('''
        local dispatch = {}
        local p = SCV_Presentation.new({textPage=90210, logisticsFontSize=8,
            consumptionColor='consumption'}, dispatch)
        assert(p.formatAmount(12400)=='12.4k')
        assert(p.formatAmount(-2500000)=='-2.5M')
        assert(p.formatRate(0)=='0/h')
        assert(p.formatSigned(nil)=='? /h')
        assert(p.formatSigned(100)=='+100/h')
        assert(p.formatPartial(0,false)=='?')
        assert(p.formatPartial(20,false)=='20 + ?')
        assert(p.formatPartial(20,false,true)=='20/h + ?')
        assert(p.formatPartial(0,true)=='0')
        assert(p.formatHours(nil)=='unknown')
        assert(p.formatHours(0)=='1 min')
        assert(p.formatHours(1.5)=='1.5 h')
        local text,color = p.aggregateStatus({netKnown=true,netRate=-10,demandCap=20})
        assert(text=='-10/h (-50%)' and color=='consumption')
        text,color = p.aggregateStatus({supplyKnown=true,supplyCap=100,demandCap=0})
        assert(text=='Supply 100/h (partial)' and color=='text_positive')
        assert(p.aggregateRateLine(20,false,true)=='Demand: 20/h + ?\\nIncomplete')
        assert(p.stockTooltip('Ore', {}, {stockKnown=false,capacityKnown=false,
            incoming=0,outgoing=0,reservationsKnown=false}) ==
            'Ore\\n\\nStock ? / ?\\nStock unknown\\nCapacity unknown\\nReservations unknown')
        assert(p.warningReason('Ore',{severity='ok'})==nil)
        assert(p.hasContinuousDemand({stationNodes={s={wares={ore={rateBasis='continuousProcessing'}}}}},
            {consumers={'s'},scvware='ore'}))

        assert(p.T(9999)=='SCV#9999')
        assert(p.T(9999,12,'value')=='SCV#9999: 12 value')
        assert(#logs==1)
        texts[9999]='Recovered %s'
        assert(p.T(9999,'value')=='Recovered value')
        texts[9999]='Bad %d'
        assert(p.T(9999,'value')=='Bad %d')
        local other=SCV_Presentation.new({textPage=90210})
        texts[9999]=nil
        assert(other.T(9999)=='SCV#9999' and #logs==1)

        assert(p.idleText({idleKnown=true,shipsKnown=true,idle=1,total=3})=='1 / 3 - 33.3%')
        dispatch.idleText=function() return 'live override' end
        local entries=p.logisticsEntries({shipsKnown=true,idleKnown=true,idle=1,total=3,severity='ok'})
        assert(entries[#entries].tip:find('live override',1,true))
        dispatch.logisticsEntries=function() return {{text='ICON 42',tip='tip'}} end
        local rows=p.logisticsRows({})
        assert(rows[1].entries[1].text=='ICON\\n42')
        assert(rows[1].entries[1].width==8 and rows[1].height==20)
        C.GetTextWidth=function() error('unavailable') end
        rows=p.logisticsRows({})
        assert(rows[1].entries[1].width==44)
    ''')
    print(f'Presentation contracts passed: {runtime.__module__}')
