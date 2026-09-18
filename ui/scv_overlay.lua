-- Owned native logistics visuals; no copied game implementation or native pool edits.
-- Evidence: helper.lua scaleFont; widget_fullscreen.lua initializeMasterElements,
-- initializeTableRowElements, updateFontString and moveAnarkElementFrameLayer.
-- A clone of the visual template is NOT a CreateTable/FontString widget.
if SCV_Overlay and SCV_Overlay.active then pcall(function () SCV_Overlay.active:hide() end) end
SCV_Overlay = {}
local P = SCV_Overlay
function P.intersects(a, b)
    return b and a.x < b.x+b.width and a.x+a.width > b.x
        and a.y < b.y+b.height and a.y+a.height > b.y
end
function P.inside(a, b)
    return a.x >= b.x and a.y >= b.y and a.x+a.width <= b.x+b.width and a.y+a.height <= b.y+b.height
end
function P.hit(metrics, x, y)
    for _, m in ipairs(metrics) do
        if x >= m.x and x < m.x+m.width and y >= m.y and y < m.y+m.height then return m end
    end
end

function P.connect()
    assert(type(getfenv)=="function", "getfenv unavailable")
    local env = getfenv(GetWidgetSystemSize)
    for _, name in ipairs({"getElement","clone","getAttribute","setAttribute","goToSlide"}) do
        assert(type(env[name])=="function", "native access missing: "..name)
    end
    local cfg = assert(env.config, "widget config unavailable")
    assert(cfg.nativePresentationWidth and cfg.frame.layerOffset, "unrecognized widget geometry")
    local scene = assert(env.getElement("Scene"), "scene unavailable")
    local anchor = assert(env.getElement("Layer.ui_anchor", scene), "anchor unavailable")
    local root = assert(env.getElement("widgetsystem", anchor), "widget root unavailable")
    local master = assert(env.getElement("table_cell", root), "text template unavailable")
    -- Keep owned clones across addon reloads in the same native scene, so reload
    -- cannot accumulate an unbounded second pool. No native functions are wrapped.
    local state = env.__scvLogisticsOverlay
    if state then assert(state.root == root, "scene changed without resetting native environment") end
    state = state or {root=root, cells={}}
    env.__scvLogisticsOverlay = state
    local backend = {state=state, env=env, config=cfg, master=master}
    function backend:hide()
        for _, cell in ipairs(state.cells) do
            if cell.shown then env.goToSlide(cell.root, "inactive"); cell.shown=false end
        end
    end
    function backend:draw(metrics, viewWidth, viewHeight)
        assert(#metrics <= 2048, "logistics visual budget exceeded")
        for i,m in ipairs(metrics) do
            local cell=state.cells[i]
            if not cell then
                local element=assert(env.clone(master, "scv_logistics_overlay_"..i), "clone failed")
                -- Track partial allocations before any later operation can fail.
                cell={root=element}; state.cells[i]=cell
                env.goToSlide(element,"inactive")
                cell.text=assert(env.getElement("Text",element), "text child missing")
                cell.z=env.getAttribute(element,"position.z")
            end
            assert(cell.text and cell.z, "partial clone from failed initialization")
            local c=m.color
            do
                -- Own scalar copies: callers may mutate metrics/colors in place.
                -- Existing clones from the prior revision intentionally initialize
                -- this cache afresh after UI reload.
                cell.attributes=cell.attributes or {}
                local function set(e,k,v)
                    local key=(e==cell.root and "root:" or "text:")..k
                    if cell.attributes[key]~=v then
                        env.setAttribute(e,k,v); cell.attributes[key]=v
                    end
                end
                -- Match native frame layer 5. Detail panels use layer 4 and therefore
                -- draw in front. We additionally mask their finalized rectangle.
                set(cell.root,"position.z",cell.z+4*cfg.frame.layerOffset)
                set(cell.root,"position.x",math.floor(m.x+((m.halign or 1)==0 and 0 or m.width/2))-viewWidth/2)
                set(cell.root,"position.y",viewHeight/2-m.y)
                set(cell.text,"position.x",0); set(cell.text,"position.y",0)
                set(cell.text,"horzalign",m.halign or 1); set(cell.text,"wordwrap",false)
                set(cell.text,"textstring",m.text); set(cell.text,"font",m.font)
                set(cell.text,"size",m.fontsize); set(cell.text,"boxwidth",m.width/cfg.nativePresentationWidth)
                set(cell.text,"textcolor.r",c.r); set(cell.text,"textcolor.g",c.g); set(cell.text,"textcolor.b",c.b)
                set(cell.text,"opacity",c.a or 100); set(cell.text,"glowfactor",c.glow or 0)
                -- Text-only slide. No RegisterMouseInteractions, cell backgrounds,
                -- table pick rectangles, or native widget associations are created.
            end
            if not cell.shown then env.goToSlide(cell.root,"text"); cell.shown=true end
        end
        for i=#metrics+1,#state.cells do
            local cell=state.cells[i]
            if cell.shown then env.goToSlide(cell.root,"inactive"); cell.shown=false end
        end
    end
    backend:hide()
    return backend
end

-- Native inline colour syntax: helper.lua:8844 convertColorToText.
-- Measured space advance: monitors.lua:3129. No new scene API is required.
-- Keep original metric rectangles for input; batch only the rendered text.
function P.batch(entries,measure)
    local space=measure(" ")
    assert(space>0,"grouped renderer requires a measurable space glyph")
    local result,ranges={},{}
    local start=1
    for i=2,#entries do
        if entries[i].groupStart or (entries[i].color.glow or 0)~=(entries[i-1].color.glow or 0) then
            ranges[#ranges+1]={start,i-1}; start=i
        end
    end
    ranges[#ranges+1]={start,#entries}
    for _,range in ipairs(ranges) do
        local first,last=entries[range[1]],entries[range[2]]
        local lines={}
        local maxError=0
        for line=1,2 do
            local parts,cursor={},0
            for i=range[1],range[2] do
                local m=entries[i]
                local header,count=m.text:match("^(.-)\n(.*)$")
                assert(header and count,"expected two metric lines")
                local text=line==1 and header or count
                local width=measure(text)
                local target=m.x-first.x+(m.width-width)/2
                local spaces=math.max(0,math.floor((target-cursor)/space+0.5))
                cursor=cursor+spaces*space
                maxError=math.max(maxError,math.abs(cursor-target))
                assert(cursor>=m.x-first.x-0.01 and cursor+width<=m.x-first.x+m.width+0.01,
                    "grouped glyph exceeds its metric hover rectangle")
                local c=m.color
                assert((c.glow or 0)==(first.color.glow or 0),"group has incompatible glow factors")
                local color=string.format("\27#%02x%02x%02x%02x#",math.floor((c.a or 100)*255/100+0.5),c.r,c.g,c.b)
                parts[#parts+1]=string.rep(" ",spaces)..color..text.."\27X"
                cursor=cursor+width
            end
            lines[line]=table.concat(parts)
        end
        assert(maxError<=space/2+0.01,"grouped alignment exceeds half a space")
        result[#result+1]={x=first.x,y=first.y,width=last.x+last.width-first.x,height=first.height,
            text=table.concat(lines,"\n"),font=first.font,fontsize=first.fontsize,halign=0,
            color={r=255,g=255,b=255,a=100,glow=first.color.glow or 0},alignmentError=maxError}
    end
    return result
end


