-- Supply Chain View — the chain registry.
--
-- One job: own the list of supply chains and persist it. Both the context menu
-- (scv_interact) and the screen (scv_menu) read and mutate it, so it lives in its own file
-- loaded before either of them. It makes no game calls of its own: where it needs the game
-- (re-finding stations after a load) the caller passes the lookups in, which is also what
-- lets the test suite exercise it against a fake world.
--
-- ---------------------------------------------------------------------------------
-- A MEMBER IS AN ID *AND* A STATION CODE
-- ---------------------------------------------------------------------------------
-- Runtime component ids are NOT stable across a savegame load. Proven from a real save:
-- every stored id pointed at exactly the right station when the game was saved
-- (506813 = [0x7bbbd] = HEA-485, "1 - Mining Hub - Asteroid Belt - Hydrogen"), yet after
-- loading that same save none of them resolved. The ids in a save file wire components to
-- each other inside the file; the engine hands out fresh runtime ids on load. /reloadui
-- passed because it does not rebuild the world.
--
-- The station CODE (the "HEA-485" shown in game) is persisted with the station and
-- survives the load. So each member stores both:
--     id    the fast path within one session - no lookup needed
--     code  the durable identity, used to verify the id and to re-find the station
-- and reconcile() re-links members whose id has gone stale, then saves the fresh ids.
--
-- ---------------------------------------------------------------------------------
-- THE STORAGE SHAPE IS FLAT ON PURPOSE
-- ---------------------------------------------------------------------------------
-- The obvious nested shape - groups = { { name = "...", members = { ... } } } - lost its
-- members on /reloadui while the names beside them survived. The persisted form is two
-- parallel depth-1 arrays of strings, the shape vanilla itself persists for
-- __CORE_DETAILMONITOR_MAPFILTER_SAVE["searchsectors"] (menu_map.lua:29243):
--
--   __SCV_GROUPS = {
--     version  = 5,
--     selected = 1,
--     names    = { "Ore Chain", "Shipyard Feed" },
--     members  = { "506813|HEA-485,501323|CXG-006", "422158|PHM-325" },
--     ignoredWarnings = { "HEA-485|ore" },
--   }
--
-- Confirmed in game: this shape survives both /reloadui and a real save + load.

SCV_Store = {}

local CURRENT_VERSION = 5
local SEP_MEMBER = ","
local SEP_FIELD  = "|"

local function log(msg)
	DebugError("SCV: " .. tostring(msg))
end

-- In-memory working copy:
--   { { name = "...", members = { { id = "506813", code = "HEA-485" }, ... } }, ... }
-- Rebuilt from __SCV_GROUPS once per Lua environment, then kept live.
local chains = nil
local selectedIdx = 1
local ignoredWarnings = {}

local function warningKey(code, ware)
	if type(code) ~= "string" or code == "" or code:find("[|,]")
		or type(ware) ~= "string" or ware == "" or ware:find("[|,]") then return nil end
	return code .. "|" .. ware
end

-- Canonical id form. Accepts a string, a number, or an ffi id and always returns the same
-- string for the same station.
function SCV_Store.normalizeId(v)
	if v == nil then
		return nil
	end
	local t = type(v)
	if (t ~= "string") and (t ~= "number") and (t ~= "cdata") then
		return nil
	end
	local s = tostring(v)
	if (s == "") or (s == "0") then
		return nil
	end
	return s
end

local function normalizeCode(c)
	if type(c) ~= "string" then
		return nil
	end
	-- the separators must never appear inside a stored field
	c = string.gsub(c, "[" .. SEP_MEMBER .. SEP_FIELD .. "]", "")
	if c == "" then
		return nil
	end
	return c
end

-- Accept the forms callers hand in: a bare id (older callers, or a legacy stored value)
-- or a record { id = ..., code = ... }.
local function toRecord(entry)
	if type(entry) == "table" then
		local id = SCV_Store.normalizeId(entry.id)
		if not id then
			return nil
		end
		return { id = id, code = normalizeCode(entry.code) }
	end
	local id = SCV_Store.normalizeId(entry)
	if not id then
		return nil
	end
	return { id = id, code = nil }
end

-- Identity for de-duplication: the code when known (it is the durable identity), else the
-- id. Two records for the same station with different ids - one stale, one fresh - share
-- a code and so collapse into one.
local function identity(rec)
	return rec.code or ("#" .. rec.id)
end

local function encodeMembers(members)
	local parts = {}
	for _, m in ipairs(members) do
		parts[#parts + 1] = m.id .. SEP_FIELD .. (m.code or "")
	end
	return table.concat(parts, SEP_MEMBER)
end

local function decodeMembers(str)
	local out, seen = {}, {}
	local function push(rec)
		if rec and (not seen[identity(rec)]) then
			seen[identity(rec)] = true
			out[#out + 1] = rec
		end
	end
	if type(str) == "table" then
		-- the v1/v2 nested form, during migration
		for _, id in ipairs(str) do
			push(toRecord(id))
		end
		return out
	end
	if type(str) ~= "string" then
		return out
	end
	for piece in string.gmatch(str, "([^" .. SEP_MEMBER .. "]+)") do
		local id, code = string.match(piece, "^([^" .. SEP_FIELD .. "]*)" .. "%" .. SEP_FIELD .. "(.*)$")
		if id then
			push(toRecord({ id = id, code = code }))
		else
			-- v3 stored bare ids with no code; those members carry no durable identity
			push(toRecord(piece))
		end
	end
	return out
end

-- Write the in-memory chains out in the flat persisted shape. Called by every mutator: a
-- change that is not written is a change that vanishes on the next reload.
function SCV_Store.save()
	local names, members = {}, {}
	local ignored = {}
	for key in pairs(ignoredWarnings) do ignored[#ignored + 1] = key end
	table.sort(ignored)
	for i, chain in ipairs(chains or {}) do
		names[i] = tostring(chain.name or "?")
		members[i] = encodeMembers(chain.members or {})
	end
	__SCV_GROUPS = {
		version  = CURRENT_VERSION,
		selected = selectedIdx,
		names    = names,
		members  = members,
		ignoredWarnings = ignored,
	}
end

local function rebuildFromStorage()
	chains = {}
	selectedIdx = 1
	ignoredWarnings = {}

	if type(__SCV_GROUPS) ~= "table" then
		SCV_Store.save()
		return
	end

	if type(__SCV_GROUPS.ignoredWarnings) == "table" then
		for _, key in ipairs(__SCV_GROUPS.ignoredWarnings) do
			if type(key) == "string" then
				local code, ware = key:match("^([^|]+)|([^|]+)$")
				if warningKey(code, ware) then ignoredWarnings[key] = true end
			end
		end
	end
	local legacy = 0
	if type(__SCV_GROUPS.names) == "table" then
		-- v3 and v4 share this shape; v3 member strings simply have no codes
		local storedMembers = (type(__SCV_GROUPS.members) == "table") and __SCV_GROUPS.members or {}
		for i, name in ipairs(__SCV_GROUPS.names) do
			local members = decodeMembers(storedMembers[i])
			for _, m in ipairs(members) do
				if not m.code then
					legacy = legacy + 1
				end
			end
			chains[#chains + 1] = { name = tostring(name), members = members }
		end
	elseif type(__SCV_GROUPS.groups) == "table" then
		-- v1/v2 nested form
		for _, g in ipairs(__SCV_GROUPS.groups) do
			if type(g) == "table" then
				local members = decodeMembers(g.members)
				legacy = legacy + #members
				chains[#chains + 1] = { name = tostring(g.name or "?"), members = members }
			end
		end
		log("migrated " .. #chains .. " supply chain(s) from the old storage format")
	end

	if type(__SCV_GROUPS.selected) == "number" then
		selectedIdx = __SCV_GROUPS.selected
	end
	if selectedIdx > #chains then
		selectedIdx = math.max(1, #chains)
	end

	local total = 0
	for _, c in ipairs(chains) do
		total = total + #c.members
	end
	log(string.format("loaded %d chain(s), %d member(s) from storage (%d without a station code)",
		#chains, total, legacy))

	SCV_Store.save()
end

-- Load once per Lua environment. A /reloadui re-runs this file, which resets `chains` to
-- nil and so re-reads from the savedvariable.
function SCV_Store.load()
	if chains == nil then
		rebuildFromStorage()
	end
	return chains
end

function SCV_Store.chains()
	return SCV_Store.load()
end

function SCV_Store.isWarningIgnored(stationCode, wareId)
	SCV_Store.load()
	local key = warningKey(stationCode, wareId)
	return key ~= nil and ignoredWarnings[key] == true
end

function SCV_Store.setWarningIgnored(stationCode, wareId, ignored)
	SCV_Store.load()
	local key = warningKey(stationCode, wareId)
	if not key then return false end
	ignoredWarnings[key] = ignored and true or nil
	SCV_Store.save()
	return true
end

function SCV_Store.get(index)
	return SCV_Store.load()[index]
end

function SCV_Store.count()
	return #SCV_Store.load()
end

function SCV_Store.selected()
	local list = SCV_Store.load()
	return list[selectedIdx], selectedIdx
end

function SCV_Store.select(index)
	local list = SCV_Store.load()
	if list[index] then
		selectedIdx = index
		SCV_Store.save()
	end
end

-- Returns the new chain's index. `entries` are records { id, code } (or bare ids).
function SCV_Store.create(name, entries)
	local list = SCV_Store.load()
	list[#list + 1] = { name = tostring(name or "?"), members = {} }
	selectedIdx = #list
	SCV_Store.addStations(selectedIdx, entries)   -- saves
	return selectedIdx
end

-- Add stations to a chain, skipping any already in it. Returns how many were actually
-- added, so the caller can tell "added 3" from "they were all already in there".
--
-- "Already in it" is judged by CODE as well as id: after a load the stored id is stale
-- until the screen re-links it, so a right-click on the same station would otherwise
-- look new and add it a second time.
function SCV_Store.addStations(index, entries)
	local chain = SCV_Store.get(index)
	if (not chain) or (type(entries) ~= "table") then
		return 0
	end
	local present = {}
	for _, m in ipairs(chain.members) do
		present["#" .. m.id] = true
		if m.code then
			present[m.code] = true
		end
	end
	local added = 0
	for _, entry in ipairs(entries) do
		local rec = toRecord(entry)
		if rec and (not present["#" .. rec.id]) and not (rec.code and present[rec.code]) then
			present["#" .. rec.id] = true
			if rec.code then
				present[rec.code] = true
			end
			chain.members[#chain.members + 1] = rec
			added = added + 1
		end
	end
	SCV_Store.save()
	return added
end

function SCV_Store.removeStation(index, stationId)
	local chain = SCV_Store.get(index)
	local key = SCV_Store.normalizeId(stationId)
	if (not chain) or (not key) then
		return false
	end
	for i = #chain.members, 1, -1 do
		if chain.members[i].id == key then
			table.remove(chain.members, i)
			SCV_Store.save()
			return true
		end
	end
	return false
end

function SCV_Store.rename(index, name)
	local chain = SCV_Store.get(index)
	if (not chain) or (type(name) ~= "string") then return false end
	name = name:match("^%s*(.-)%s*$")
	if name == "" then return false end
	chain.name = name
	SCV_Store.save()
	return true
end

function SCV_Store.delete(index)
	local list = SCV_Store.load()
	if not list[index] then
		return
	end
	table.remove(list, index)
	if selectedIdx > #list then
		selectedIdx = math.max(1, #list)
	end
	SCV_Store.save()
end

-- A chain a station already belongs to should not offer "add" again in the context menu.
-- `entry` is a record { id, code } or a bare id; a code match counts, for the same reason
-- as in addStations.
function SCV_Store.contains(index, entry)
	local chain = SCV_Store.get(index)
	local rec = toRecord(entry)
	if (not chain) or (not rec) then
		return false
	end
	for _, m in ipairs(chain.members) do
		if (m.id == rec.id) or (rec.code and (m.code == rec.code)) then
			return true
		end
	end
	return false
end

-- Re-link a chain's members to the live world and return the stations that resolved.
--
--   describe(id)     -> { id = <current id>, code = <station code>, ... } or nil
--   lookupCode(code) -> current id of the station with that code, or nil
--
-- Per member:
--   1. FAST PATH: describe the stored id. Accept it only if the station found there has
--      the SAME CODE. After a load an old id may belong to a DIFFERENT station now, and
--      trusting it would silently put the wrong station in the chain.
--   2. Otherwise look the code up and describe the station found, again requiring the
--      code to match.
--   3. A member stored without a code (written by v3, before codes existed) cannot be
--      verified. It is accepted if its id still resolves, and upgraded with that
--      station's code - which is right within the session it was created in and may be
--      wrong after a load. That exposure ends once every member carries a code.
--
-- Members that do not resolve are KEPT, not deleted: a lookup can miss for reasons that
-- are not the station being gone, and silently shrinking a chain is the failure the
-- "no longer exist" notice exists to prevent. Duplicates (a stale and a fresh record for
-- the same station) collapse to one. Any change is saved, so the next session starts from
-- the fresh ids.
--
-- Returns: live (array of describe() results, chain order), missing (count)
function SCV_Store.reconcile(index, describe, lookupCode)
	local chain = SCV_Store.get(index)
	if not chain then
		return {}, 0
	end

	local live, kept, seen = {}, {}, {}
	local missing, changed = 0, false

	for _, m in ipairs(chain.members) do
		local d = describe(m.id)
		local ok = d and ((not m.code) or (d.code == m.code))

		if (not ok) and m.code and lookupCode then
			local newid = lookupCode(m.code)
			if newid then
				d = describe(newid)
				ok = d and (d.code == m.code)
			end
		end

		if ok then
			local freshId = SCV_Store.normalizeId(d.id) or m.id
			local freshCode = normalizeCode(d.code) or m.code
			if (freshId ~= m.id) or (freshCode ~= m.code) then
				m.id, m.code = freshId, freshCode
				changed = true
			end
			if seen[identity(m)] then
				changed = true              -- a duplicate of a member already kept
			else
				seen[identity(m)] = true
				kept[#kept + 1] = m
				live[#live + 1] = d
			end
		else
			missing = missing + 1
			kept[#kept + 1] = m
		end
	end

	chain.members = kept
	if changed then
		SCV_Store.save()
	end
	return live, missing
end

-- Handoff from the context menu to the screen. Both live in the same Lua environment, so
-- this is simply a shared table - nothing here has to survive a save.
SCV_Store.pending = nil

function SCV_Store.setPending(p)
	SCV_Store.pending = p
end

function SCV_Store.takePending()
	local p = SCV_Store.pending
	SCV_Store.pending = nil
	return p
end

local function init()
	SCV_Store.version = CURRENT_VERSION
end

init()

return SCV_Store
