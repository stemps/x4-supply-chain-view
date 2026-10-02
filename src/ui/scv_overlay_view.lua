-- Depends: scv_overlay.lua
-- Adapt cached SCV logistics rows to owned native visuals. No station reads.
local P = SCV_Overlay
local C = require("ffi").C
function P.newView()
    local view = { backend=P.connect(), cache={}, widths={} }
    function view:hide()
        if self.hover and self.owner then SetMouseOverOverride(self.owner,nil,true) end
        self.hover,self.owner,self.rendered=nil,nil,nil
        self.backend:hide()
    end
    function view:reset()
        self:hide(); self.cache={}; self.widths={}
    end
    function view:update(stations,viewport,obstacles,owner,font,size,scale)
        local key=font..":"..size..":"..scale
        if key~=self.style then self:reset(); self.style=key end
        if self.owner and self.owner~=owner then self:hide() end
        self.owner=owner
        local seen,visuals,hits={},{},{}
        local function measure(text)
            if self.widths[text]==nil then self.widths[text]=tonumber(C.GetTextWidth(text,font,size)) end
            return self.widths[text]
        end
        for _,station in ipairs(stations) do
            seen[station.key]=true
            local cached=self.cache[station.key]
            if not cached or cached.line~=station.line or cached.layout~=station.layout or cached.x~=station.x or cached.y~=station.y then
                cached={line=station.line,layout=station.layout,x=station.x,y=station.y,entries={}}
                local x=station.x
                for i,entry in ipairs(station.line.entries) do
                    local width=station.layout.widths[i]
                    if entry.text~="" then
                        cached.entries[#cached.entries+1]={x=x,y=station.y,width=width,height=station.layout.height,
                            text=entry.text:gsub("\27#[%x]+#",""):gsub("\27X",""),
                            color=entry.color or Color.text_normal,tip=entry.tip,groupStart=entry.groupStart,
                            font=font,fontsize=size}
                    end
                    x=x+width+(Helper.borderSize or 1)
                end
                self.cache[station.key]=cached
            end
            local selected,keys={},{}
            for i,m in ipairs(cached.entries) do
                local visible=P.inside(m,viewport)
                for _,panel in ipairs(obstacles) do if P.intersects(m,panel) then visible=false; break end end
                if visible then selected[#selected+1]=m; keys[#keys+1]=i; hits[#hits+1]=m end
            end
            local clip=table.concat(keys,",")
            if clip~=cached.clip then
                cached.clip=clip
                if #selected>0 then
                    local ok,groups=pcall(P.batch,selected,measure)
                    -- Unsafe grouped typography retains every metric individually.
                    cached.visuals=ok and groups or selected
                    if not ok and not self.warned then DebugError("SCV: individual logistics visuals: "..tostring(groups)); self.warned=true end
                else cached.visuals={} end
            end
            for _,m in ipairs(cached.visuals) do visuals[#visuals+1]=m end
        end
        for id in pairs(self.cache) do if not seen[id] then self.cache[id]=nil end end
        local old=self.rendered
        local changed=not old or #old~=#visuals or self.vw~=Helper.viewWidth or self.vh~=Helper.viewHeight
        if not changed then for i,m in ipairs(visuals) do if old[i]~=m then changed=true; break end end end
        if changed then
            self.backend:draw(visuals,Helper.viewWidth,Helper.viewHeight)
            self.rendered=visuals; self.vw=Helper.viewWidth; self.vh=Helper.viewHeight
        end
        local mx,my=GetLocalMousePosition()
        local hit=mx and my and P.hit(hits,mx+Helper.viewWidth/2,Helper.viewHeight/2-my)
        local tip=hit and hit.tip or nil
        if tip~=self.hover then SetMouseOverOverride(owner,tip,not tip); self.hover=tip end
    end
    P.active=view
    return view
end
