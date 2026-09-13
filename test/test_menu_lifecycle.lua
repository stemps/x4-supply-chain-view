-- Helper.clearFrame unregisters global layer views, not just this menu's frame.
-- Model a synchronous destination opening so post-open cleanup destroys its UI.
local clearFrame, openMenu, closeMenu = Helper.clearFrame, Helper.closeMenuAndOpenNewMenu, Helper.closeMenu
local closed = menu.closed
local opened, clears, destinationFrames
function Helper.clearFrame(_, layer)
	assert(not opened, "SCV cleared a shared layer after another menu opened")
	clears = clears + 1
end
function Helper.closeMenuAndOpenNewMenu(_, name, params)
	assert(menu.graph == nil and menu.refreshState == nil and menu.closed)
	assert(clears == 2, "clear status and management before opening; toolbar shares main frame")
	opened = name
	destinationFrames = { [1] = "new management", [3] = "new status", [4] = "new toolbar" }
	assert(params[3] == "station")
end
local function prepare()
	opened, clears = nil, 0
	menu.closed = false
	menu.statusFrame, menu.managementFrame = {}, {}
	menu.graph, menu.refreshState = {}, {}
	menu.managementMode = "stations"
	menu.expandedNode, menu.expandedMenuFrame = nil, nil
end
for _, name in ipairs({ "StationOverviewMenu", "StationConfigurationMenu", "MapMenu" }) do
	prepare()
	menu.openMenu(name, { 0, 0, "station" })
	assert(opened == name and destinationFrames[4] == "new toolbar")
	-- A queued old update must not rebuild SCV or touch destination widgets.
	local display = menu.display
	menu.display = function () error("closed menu redrew itself") end
	menu.onUpdate()
	menu.display = display
end
prepare()
menu.managementMode = nil
function Helper.closeMenu()
	assert(clears == 2 and menu.closed, "clean up before returning to another menu")
	opened = "previous menu"
end
menu.onCloseElement("back", 5)
assert(opened == "previous menu")
Helper.clearFrame, Helper.closeMenuAndOpenNewMenu, Helper.closeMenu = clearFrame, openMenu, closeMenu
menu.closed = closed
