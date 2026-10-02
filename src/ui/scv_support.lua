-- Shared engine-read diagnostics; warning lifetime matches the addon environment.
SCV_Support = {}

function SCV_Support.log(msg)
	DebugError("SCV: " .. tostring(msg))
end

-- pcall wrapper for engine reads.
--
-- IT MUST COMPLAIN. An earlier version returned the fallback in silence, and that hid a
-- real bug for a whole test cycle: GetContainerWareConsumption is FFI-ONLY (declared in
-- helper.lua:322, always called as C.GetContainerWareConsumption). Calling it as a bare
-- global made `fn` nil, pcall failed, and every station reported zero consumption.
-- Messages are de-duplicated, so a per-frame call cannot spam debug.txt.
local warned = {}
function SCV_Support.warnOnce(key, msg)
	if not warned[key] then
		warned[key] = true
		SCV_Support.log(msg)
	end
end

function SCV_Support.safe(fallback, fn, ...)
	if type(fn) ~= "function" then
		SCV_Support.warnOnce("notafunction", "an engine API name is wrong (got " .. type(fn)
			.. " instead of a function) - check C.X vs global X")
		return fallback
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		SCV_Support.warnOnce(tostring(result), "engine call failed: " .. tostring(result))
		return fallback
	end
	if result == nil then
		return fallback
	end
	return result
end

return SCV_Support
