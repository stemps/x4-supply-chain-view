-- Optional Native Hotkey API consumer. The API owns key assignment and persistence.
-- Register on each readiness event: its registry and Lua callbacks reset on reload.
local ffi = require("ffi")
-- IsStartmenu is declared by the required vanilla detailmonitor helper.
local C = ffi.C
local event = "HotkeyApi.Register_Request"
local menuName = "SCVSupplyChainMenu"

-- Re-executing this file in a reused environment must replace the old listener.
if SCV_Hotkey and SCV_Hotkey.onReady then
    UnregisterEvent(event, SCV_Hotkey.onReady)
end
SCV_Hotkey = {}
local hotkey = SCV_Hotkey
local lastOpen = -math.huge

function hotkey.open()
    if C.IsStartmenu() then return end
    local map
    for _, current in ipairs(Menus or {}) do
        if current.shown then
            -- Includes SCV itself, dialogs, options and chat. Only the map may
            -- be replaced; with no shown menu the API supplies pilot/fps gating.
            if current.name ~= "MapMenu" then return end
            map = current
        end
    end
    -- Vanilla MapMenu.onEditBoxActivated sets noupdate while editing. Avoid
    -- interrupting its popup interactions as well (including search suggestions).
    if map and (map.noupdate or map.contextMenuMode) then return end
    local now = getElapsedTime()
    if now >= lastOpen and now - lastOpen < 0.5 then return end
    lastOpen = now
    if map then
        Helper.closeMenuAndOpenNewMenu(map, menuName, { 0, 0 })
    else
        OpenMenu(menuName, { 0, 0 }, nil)
    end
end

function hotkey.onReady()
    if type(HotkeyApi) ~= "table" or type(HotkeyApi.RegisterAction) ~= "function" then
        return
    end
    HotkeyApi.RegisterAction({
        id = "scv_open_supply_chain",
        name = ReadText(90210, 1001),
        area = "map;pilot;fps",
        isObjectRequired = false,
        actionLua = hotkey.open,
    })
end

RegisterEvent(event, hotkey.onReady)
return hotkey
