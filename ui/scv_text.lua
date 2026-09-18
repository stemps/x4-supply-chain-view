-- Shared SCV localization. No translation cache: later successful reads recover.
SCV_Text = {}

-- Diagnostics are shared by all consumers for this addon load, keyed by page/id.
local warned = {}

function SCV_Text.forPage(page)
	return function (id, ...)
		local ok, text = pcall(ReadText, page, id)
		local unresolved = not ok or type(text) ~= "string" or text == ""
			or string.sub(text, 1, 9) == "=ReadText"
		if unresolved then
			local pageWarnings = warned[page]
			if not pageWarnings then pageWarnings = {}; warned[page] = pageWarnings end
			if not pageWarnings[id] then
				pageWarnings[id] = true
				DebugError("SCV: text page " .. tostring(page) .. " id " .. tostring(id)
					.. " unresolved - restart the game if it was just added (/reloadui does not reload t/ files)")
			end
			-- Never return nil to a native text widget. Values are data, not formats.
			local label = "SCV#" .. tostring(id)
			if select("#", ...) > 0 then
				local parts = {}
				for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
				return label .. ": " .. table.concat(parts, " ")
			end
			return label
		end
		if select("#", ...) > 0 then
			local formatted, result = pcall(string.format, text, ...)
			if formatted then return result end
		end
		-- Preserve the original template if its format and arguments do not match.
		return text
	end
end

return SCV_Text
