-- Supply Chain View — cancellable complete-sweep refresh session.
-- Depends: scv_support.lua
local warnOnce = SCV_Support.warnOnce
SCV_Refresh = {}
SCV_Refresh.__index = SCV_Refresh

-- The menu owns this short-lived state. Dropping it cancels the sweep, with no
-- partial writes to the displayed records or shared cache. Keep a separate cursor:
-- scanGroup(force=true) would repeatedly read the first SCAN_CHUNK members.
function SCV_Refresh.new(members, now, deps)
	local copy = {}
	for _, st in ipairs(members) do
		copy[#copy + 1] = { id = st.id, id64 = st.id64, name = st.name, code = st.code }
	end
	return setmetatable({ members = copy, nextStart = now + deps.getInterval(), deps = deps }, SCV_Refresh)
end

function SCV_Refresh:step(now)
	if #self.members == 0 then return nil end
	if not self.pending then
		if now < self.nextStart then return nil end
		self.pending, self.cursor = {}, 1
		self.nextStart = now + self.deps.getInterval()
	end
	local st = self.members[self.cursor]
	local ok, result = pcall(function ()
		local live = self.deps.describe(st.id64 or st.id)
		if not live or (st.code and live.code ~= st.code) then
			return { id = st.id, name = st.name, wares = {}, missing = true }
		end
		return self.deps.readStation(st)
	end)
	if not ok or not result then
		warnOnce("refresh:" .. st.id, "refresh failed for station " .. tostring(st.name) .. ": " .. tostring(result))
		result = { id = st.id, name = st.name, wares = {}, failed = true }
	end
	self.pending[#self.pending + 1] = result
	self.cursor = self.cursor + 1
	if self.cursor > #self.members then
		local snapshot = self.pending
		self.pending, self.cursor = nil, nil
		return snapshot
	end
	return nil
end


return SCV_Refresh
