-- Supply Chain View chain management and dialog components.
-- Depends: scv_presentation.lua, scv_store.lua, scv_data.lua

SCV_Management = {}

function SCV_Management.new(menu, config, presentation)
	local component = {}
	local T = presentation.T
	local severityColor = presentation.severityColor
	local warningReason = presentation.warningReason
	-- How tall a table may grow before it must scroll instead.
	--
	-- maxVisibleHeight defaults to 0, which the widget system reads as "no maximum" - and a
	-- table with no maximum that does not fit is NOT clipped or scrolled, it is REFUSED:
	--   "Vertical space left (N) doesn't suffice to display the requested table ...
	--    Table will not be displayed."
	-- Nothing renders and nothing complains, so the screen just appears not to react.
	local function availableHeight(y)
		return math.max(Helper.scaleY(120), Helper.viewHeight - y - Helper.frameBorder)
	end
	function component.displayNameEntry(frame, x, y, width)
		local entry = { focusPending = true }
		menu.nameEntry = entry
		local ftable = frame:addTable(2, { tabOrder = 1, width = math.min(width, Helper.scaleX(700)),
			x = x, y = y, maxVisibleHeight = availableHeight(y) })
		ftable:setColWidth(2, Helper.scaleX(140), false)

		local row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(2):createText(menu.renameIndex and ReadText(1001, 1114) or T(2000), Helper.headerRowCenteredProperties)

		if not menu.renameIndex then
			local count = #(menu.pendingStations or {})
			row = ftable:addRow(false, { fixed = true })
			row[1]:setColSpan(2):createText(T(2010, tostring(count), string.lower(ReadText(1001, count == 1 and 3 or 4))),
				{ wordwrap = true })
		end

		row = ftable:addRow(true, { fixed = true })
		-- Let the cell supply its width; an explicit scaled width is scaled again by Helper.
		entry.widget = row[1]:createEditBox({ description = menu.renameIndex and ReadText(1001, 1114) or T(2000),
			selectTextOnActivation = true })
			:setText(menu.nameText or "", { halign = "left", x = Helper.standardTextOffsetx })
		-- Vanilla's rename dialog captures every edit before either confirmation path.
		row[1].handlers.onTextChanged = function (_, text)
			if menu.nameEntry == entry then menu.nameText = text end
		end
		row[1].handlers.onEditBoxDeactivated = function (_, text, _, isconfirmed)
			if menu.nameEntry == entry and isconfirmed then
				if text ~= nil then menu.nameText = text end
				menu.confirmName(entry)
			end
		end
		row[2]:createButton():setText(menu.renameIndex and ReadText(1001, 1114) or T(1010), { halign = "center" })
		row[2].handlers.onClick = function () menu.confirmName(entry) end

		row = ftable:addRow(true, { fixed = true })
		row[1]:setColSpan(2):createButton():setText(T(1011), { halign = "center" })
		row[1].handlers.onClick = function ()
			if menu.nameEntry ~= entry then return end
			menu.nameEntry = nil
			if menu.managementMode == "rename" then menu.closeManagement(); return end
			menu.mode = "chain"
			menu.pendingStations = nil
			menu.renameIndex = nil
			menu.nameText = nil
			menu.refresh = getElapsedTime() + 0.05
		end

		-- Which stations are about to become the chain, so the name is chosen with the
		-- membership visible rather than from memory.
		if menu.pendingStations and (#menu.pendingStations > 0) then
			row = ftable:addRow(false, { fixed = true })
			row[1]:setColSpan(2):createText(T(2005), Helper.headerRow1Properties)
			for _, entry in ipairs(menu.pendingStations) do
				local id = (type(entry) == "table") and entry.id or entry
				local d = SCV_Data.describe(id)
				row = ftable:addRow(false, { fixed = false })
				row[1]:createText(d and d.name or tostring(id))
				row[2]:createText(d and d.sectorname or "", { color = Color["text_inactive"], halign = "right" })
			end
		end
	end

	function component.confirmName(entry)
		if not entry or menu.nameEntry ~= entry then return end
		local name = menu.nameText and menu.nameText:match("^%s*(.-)%s*$")
		if menu.renameIndex then
			if not SCV_Store.rename(menu.renameIndex, name) then return end
			menu.nameEntry = nil
			if menu.managementMode == "rename" then
				menu.closeManagement()
				menu.display(true)
				return
			end
			menu.renameIndex = nil
			menu.nameText = nil
			menu.mode = "chain"
			menu.refresh = getElapsedTime() + 0.05
			return
		end
		if (not name) or (name == "") then
			name = T(1014, tostring(SCV_Store.count() + 1))
		end
		menu.nameEntry = nil
		SCV_Store.create(name, menu.pendingStations or {})
		menu.pendingStations = nil
		menu.nameText = nil
		menu.mode = "chain"
		menu.markDirty()
	end

	-- Left column: the chains, and the members of the selected one.
	local function setCenteredButtonIcon(button, icon)
		-- Widget dimensions are already scaled pixels. Helper adds the button border
		-- inset itself; fit a square to the whole button and center before that inset.
		local width, height = button:getWidth(), button:getHeight(true)
		local size = math.min(width, height)
		button:setIcon(icon, { scaling = false, width = size, height = size,
			x = (width - size) / 2, y = (height - size) / 2 })
	end

	-- All toolbar/overlay updates are isolated from the native graph frame.
	function component.closeManagement()
		if menu.managementMode == "rename" then menu.nameEntry = nil end
		if menu.managementFrame then Helper.clearFrame(menu, config.managementFrameLayer) end
		if menu.managementMode == "rename" then
			menu.renameIndex = nil
			menu.nameText = nil
		end
		menu.managementFrame = nil
		menu.managementMode = nil
		menu.managementChain = nil
		menu.managementStatus = nil
	end

	function component.selectChain(index)
		local _, current = SCV_Store.selected()
		if not index or not SCV_Store.get(index) then return end
		menu.closeManagement()
		if index == current then return end
		SCV_Store.select(index)
		menu.notice = nil
		menu.noticeUntil = nil
		menu.markDirty()
	end

	function component.displayToolbar(frame)
		local geo = menu.toolbarGeometry
		if not geo then return end
		-- UIX's Logical Overview selector leaves 25% margins on both sides.
		-- Keep this local to the toolbar: the graph still uses the entire content width.
		local toolbarWidth = geo.width * 0.5
		local toolbarX = geo.x + (geo.width - toolbarWidth) / 2
		-- Like vanilla LSO's title table, share the graph's main frame so expanded
		-- nodes on layer 4 cover these controls without changing native node depth.
		local ftable = frame:addTable(6, { tabOrder = 1, width = toolbarWidth, x = toolbarX, y = geo.y })
		local buttonWidth = Helper.scaleX(Helper.standardButtonHeight)
		local stationsWidth = math.min(Helper.scaleX(180), toolbarWidth * 0.28)
		for _, col in ipairs({ 1, 3, 5, 6 }) do ftable:setColWidth(col, buttonWidth, false) end
		ftable:setColWidth(4, stationsWidth, false)
		local chain, index = SCV_Store.selected()
		local chains, options = SCV_Store.chains(), {}
		for i, entry in ipairs(chains) do
			options[#options + 1] = { id = tostring(i), text = entry.name, icon = "", displayremoveoption = false }
		end
		if #options == 0 then options[1] = { id = "0", text = T(1004), icon = "", displayremoveoption = false } end
		local row = ftable:addRow(true, { fixed = true })
		row[1]:createButton({ active = chain ~= nil and #chains > 1 }):setText("<", { halign = "center" })
		row[1].handlers.onClick = function ()
			if chain and #chains > 1 then menu.selectChain(index > 1 and index - 1 or #chains) end
		end
		row[2]:createDropDown(options, { active = chain ~= nil, startOption = chain and tostring(index) or "0",
			mouseOverText = chain and chain.name or T(1004) }):setTextProperties({ halign = "left" })
		row[2].handlers.onDropDownConfirmed = function (_, id) menu.selectChain(tonumber(id)) end
		row[3]:createButton({ active = chain ~= nil and #chains > 1 }):setText(">", { halign = "center" })
		row[3].handlers.onClick = function ()
			if chain and #chains > 1 then menu.selectChain(index < #chains and index + 1 or 1) end
		end
		row[4]:createButton({ active = chain ~= nil, mouseOverText = T(2005) })
			:setText(T(2005) .. " (" .. tostring(chain and #chain.members or 0) .. ")", { halign = "center" })
		row[4].handlers.onClick = function () menu.toggleManagement("stations") end
		row[5]:createButton({ mouseOverText = T(3185) })
		setCenteredButtonIcon(row[5], "menu_options")
		row[5].handlers.onClick = function () menu.toggleManagement("settings") end
		row[6]:createButton({ active = chain ~= nil, mouseOverText = ReadText(1001, 7865) }):setText("...", { halign = "center" })
		row[6].handlers.onClick = function () menu.toggleManagement("actions") end
		-- Store the station button's left edge in screen pixels, including table borders.
		geo.anchorX = toolbarX + toolbarWidth - stationsWidth - 2 * buttonWidth - 2 * Helper.borderSize
		geo.settingsX = toolbarX + toolbarWidth - 2 * buttonWidth - Helper.borderSize
		geo.overlayY = geo.y + Helper.scaleY(Helper.standardButtonHeight) + Helper.borderSize
	end

	function component.toggleManagement(mode)
		if menu.managementMode == mode then menu.closeManagement() else menu.openManagement(mode) end
	end

	function component.setShowLogistics(enabled)
		if not SCV_Store.setShowLogistics(enabled) then return end
		menu.closeManagement()
		-- Recreate widgets with compact node spacing, retaining topology and scan cursors.
		menu.display(true)
		menu.openManagement("settings")
	end

	function component.confirmDelete()
		local chain, index = SCV_Store.selected()
		if menu.managementMode ~= "delete" or chain ~= menu.managementChain then return end
		menu.closeManagement()
		SCV_Store.delete(index)
		menu.notice = nil
		menu.noticeUntil = nil
		menu.markDirty()
	end

	-- Shared title and close control for management overlays.
	function component.displayManagementHeader(ftable, columns, title)
		local row = ftable:addRow(true, { fixed = true })
		row[1]:setColSpan(columns - 1):createText(title, { wordwrap = true })
		row[columns]:createButton({ mouseOverText = ReadText(1001, 2670) }):setText("x", { halign = "center" })
		row[columns].handlers.onClick = menu.closeManagement
		return row
	end

	function component.openManagement(mode)
		if menu.nativeLogistics then menu.nativeLogistics:hide() end
		local chain, index = SCV_Store.selected()
		if (not chain and mode ~= "settings") or not menu.toolbarGeometry then return end
		menu.closeManagement()
		if menu.expandedNode then menu.expandedNode:collapse() end
		menu.expandedNode = nil
		menu.expandedMenuFrame = nil
		menu.managementMode = mode
		menu.managementChain = chain
		local geo, border = menu.toolbarGeometry, Helper.frameBorder
		local width = math.min(Helper.scaleX(mode == "actions" and 240 or mode == "settings" and 400 or 600), Helper.viewWidth - 2 * border)
		local x = math.max(border, math.min(mode == "settings" and geo.settingsX or geo.anchorX, Helper.viewWidth - width - border))
		local y = math.min(geo.overlayY + (menu.statusHeight or 0), Helper.viewHeight - Helper.scaleY(160) - border)
		y = math.max(border, y)
		local height = Helper.viewHeight - y - border
		local frame = Helper.createFrameHandle(menu, { layer = config.managementFrameLayer,
			standardButtons = {}, -- Management supplies its own Close/Cancel controls.
			x = x, y = y, width = width, height = height, closeOnUnhandledClick = mode == "settings" })
		menu.managementFrame = frame
		frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })
		if mode == "settings" then
			local ftable = frame:addTable(3, { tabOrder = 1, x = border, y = border,
				width = width - 2 * border, maxVisibleHeight = height - 2 * border })
			ftable:setColWidth(1, Helper.scaleX(Helper.standardTextHeight), false)
			ftable:setColWidth(3, Helper.scaleX(30), false)
			menu.displayManagementHeader(ftable, 3, T(3185))
			local row = ftable:addRow(true, { fixed = true })
			row[1]:createCheckBox(SCV_Store.getShowLogistics(), { width = Helper.standardTextHeight, height = Helper.standardTextHeight })
			row[1].handlers.onClick = function (_, checked) menu.setShowLogistics(checked) end
			row[2]:setColSpan(2):createText(T(3186), { wordwrap = true })
			frame.properties.height = math.min(height, ftable:getVisibleHeight() + 2 * border)
		elseif mode == "rename" then
			menu.renameIndex, menu.nameText = index, chain.name
			menu.displayNameEntry(frame, border, border, width - 2 * border)
			frame.properties.height = math.min(height, frame:getUsedHeight() + 2 * border)
		else
			local columns = mode == "stations" and 4 or 3
			local ftable = frame:addTable(columns, { tabOrder = 1, x = border, y = border,
				width = width - 2 * border, maxVisibleHeight = height - 2 * border })
			for column = 2, columns do ftable:setColWidth(column, Helper.scaleX(30), false) end
			local row = menu.displayManagementHeader(ftable, columns, chain.name)
			if mode == "stations" then
				menu.displayStations(ftable, chain, index)
			elseif mode == "actions" then
				for _, action in ipairs({ { "rename", 1114 }, { "delete", 8931 } }) do
					local target = action[1]
					row = ftable:addRow(true, { fixed = false })
					row[1]:setColSpan(3):createButton():setText(ReadText(1001, action[2]))
					row[1].handlers.onClick = function () menu.openManagement(target) end
				end
			elseif mode == "delete" then
				row = ftable:addRow(false, { fixed = false })
				row[1]:setColSpan(3):createText(T(2020, chain.name), { wordwrap = true })
				row = ftable:addRow(true, { fixed = false })
				row[1]:setColSpan(3):createButton():setText(ReadText(1001, 8931))
				row[1].handlers.onClick = menu.confirmDelete
				row = ftable:addRow(true, { fixed = false })
				row[1]:setColSpan(3):createButton():setText(T(1011))
				row[1].handlers.onClick = menu.closeManagement
			end
			-- Match vanilla: grow the frame only as far as its bounded table content.
			frame.properties.height = math.min(height, ftable:getVisibleHeight() + 2 * border)
		end
		frame:display()
	end

	function component.displayStations(ftable, chain, index)
		local members = menu.currentMembers()
		-- Match the map's ascending name order, with station code breaking name ties.
		-- Reconciliation returns a fresh display list, separate from saved membership.
		for _, st in ipairs(members) do st.objectid = st.code or "" end
		table.sort(members, Helper.sortNameAndObjectID)
		local row = ftable:addRow(false, { fixed = false })
		row[1]:setColSpan(4):createText(T(2005) .. " (" .. #chain.members .. ")", Helper.headerRow1Properties)
		if #members == 0 then
			row = ftable:addRow(false, { fixed = false })
			row[1]:setColSpan(4):createText(T(1005), { wordwrap = true })
		end
		for _, st in ipairs(members) do
			local function stationStyle()
				local sn = menu.graph and menu.graph.stationNodes[st.id]
				local w = sn and sn.worstWare and sn.wares[sn.worstWare]
				return severityColor(sn and sn.severity or "ok") or Color["text_normal"],
					w and warningReason(w.name or sn.worstWare, w.health)
			end
			row = ftable:addRow(true, { fixed = false })
			row[1]:createButton({ bgColor = Color["button_background_hidden"], mouseOverText = function ()
				local _, reason = stationStyle()
				return st.name .. "\n" .. (reason and (reason .. "\n") or "") .. T(1013)
			end }):setText(st.name, { halign = "left", color = function () local color = stationStyle(); return color end })
			row[1].handlers.onClick = function ()
				menu.openMenu("MapMenu", { 0, 0, true, st.id64 })
			end
			row[2]:createButton({ mouseOverText = T(3030) })
			setCenteredButtonIcon(row[2], "stationbuildst_lsov")
			row[2].handlers.onClick = function ()
				menu.openMenu("StationOverviewMenu", { 0, 0, st.id64 })
			end
			row[3]:createButton({ mouseOverText = T(3103), active = GetComponentData(st.id64, "isplayerowned") })
			setCenteredButtonIcon(row[3], "mapst_plotmanagement")
			row[3].handlers.onClick = function ()
				if not GetComponentData(st.id64, "isplayerowned") then return end
				menu.openMenu("StationConfigurationMenu", { 0, 0, st.id64 })
			end
			row[4]:createButton({ mouseOverText = T(1016) }):setText("-", { halign = "center" })
			row[4].handlers.onClick = function ()
				local selected = SCV_Store.selected()
				if selected ~= chain then return end
				SCV_Store.removeStation(index, st.id)
				menu.markDirty()
			end
		end
	end



	return component
end
