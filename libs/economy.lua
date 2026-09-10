--[[
* synthex - synth profit / material-cost bookkeeping
*
* Prices are a shared master list, one gil figure per item for every character
* on the account - so Imperial Cermet costs the same whether your WAR alt or
* your main is looking at the recipe. Stored as 'item name:gil' lines (same
* idea as floos' item_index) in config/addons/synthex/prices.txt, which lives
* alongside the per-character settings folders but is not one of them - so it
* is untouched by Ashita's per-character settings load/merge/save. That also
* keeps it human-editable and portable on its own.
]]--

require('common')

local M = {}

local price_lines = T{}        -- the master list: 'item name:gil' strings
local price_map = {}           -- ['lowercased name'] = gil, rebuilt from price_lines
local seen = {}                -- [itemId] = true  (crystals, ingredients, products, losses)

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local name_cache = {}

local function item_name(id)
    if id == nil or id == 0 then return nil end
    local cached = name_cache[id]
    if cached ~= nil then return cached end
    local res = AshitaCore:GetResourceManager()
    local it = res and res:GetItemById(id)
    if it ~= nil and it.Name ~= nil and it.Name[1] ~= nil and it.Name[1] ~= '' then
        name_cache[id] = it.Name[1]  -- only cache real names; retry misses later
        return it.Name[1]
    end
    return nil
end
M.item_name = item_name

local function trim(s)
    return (tostring(s):match('^%s*(.-)%s*$'))
end

function M.split(str, sep)
    sep = sep or '\n'
    local out = T{}
    for piece in tostring(str):gmatch('([^' .. sep .. ']+)') do
        out[#out + 1] = piece
    end
    return out
end

--- Pretty gil with thousands separators and a trailing 'g'. Keeps the sign.
function M.gil(n)
    n = math.floor((tonumber(n) or 0) + 0.5)
    local sign = ''
    if n < 0 then sign = '-'; n = -n end
    local s = tostring(n)
    while true do
        local rep
        s, rep = s:gsub('^(%d+)(%d%d%d)', '%1,%2')
        if rep == 0 then break end
    end
    return sign .. s .. 'g'
end

--------------------------------------------------------------------------------
-- price store
--------------------------------------------------------------------------------

--- config/addons/synthex, where the master price file and a bare import/export
--- filename resolve. Same for every character - it sits beside the
--- per-character settings folders, not inside one of them.
function M.dir()
    local ok, p = pcall(function() return AshitaCore:GetInstallPath() end)
    if ok and p ~= nil and p ~= '' then
        return (tostring(p):gsub('[/\\]+$', '')) .. '/config/addons/synthex'
    end
    return '.'
end

local function master_path()
    return M.dir() .. '/prices.txt'
end

function M.rebuild()
    price_map = {}
    for _, line in ipairs(price_lines) do
        local name, price = tostring(line):match('^%s*(.-)%s*:%s*(-?%d+)%s*$')
        if name ~= nil and name ~= '' then
            price_map[name:lower()] = tonumber(price) or 0
        end
    end
end

--- Load the master price list from disk into memory. Call once at startup;
--- there is nothing to bind to since this is no longer tied to any one
--- character's settings table.
function M.load_master()
    local lines = T{}
    local f = io.open(master_path(), 'r')
    if f ~= nil then
        for line in f:lines() do
            if line:match('%S') then lines[#lines + 1] = line end
        end
        f:close()
    end
    price_lines = lines
    M.rebuild()
end

--- Write the in-memory master list back to disk.
function M.save_master()
    local f = io.open(master_path(), 'w')
    if f == nil then return false end
    f:write(table.concat(price_lines, '\n'))
    f:close()
    return true
end

--- The live master list (a T{} of 'name:gil' strings) - read-only for callers;
--- go through set_price/merge_lines/set_lines to change it so it stays saved.
function M.get_lines()
    return price_lines
end

--- Replace the whole master list (used by the "full list" text box). Saves
--- immediately.
function M.set_lines(lines)
    local next_lines = T{}
    for _, l in ipairs(lines or {}) do
        if tostring(l):match('%S') then next_lines[#next_lines + 1] = l end
    end
    price_lines = next_lines
    M.rebuild()
    M.save_master()
end

--- Counts for /synthex prices: list lines, entries in the lookup map, bad lines.
function M.debug_summary()
    local n_list, n_bad = 0, 0
    for _, line in ipairs(price_lines) do
        n_list = n_list + 1
        if not tostring(line):match('^%s*(.-)%s*:%s*(-?%d+)%s*$') then
            n_bad = n_bad + 1
        end
    end
    local n_map = 0
    for _ in pairs(price_map) do n_map = n_map + 1 end
    return n_list, n_map, n_bad
end

--- gil, found. found is false when the item has no (non-zero) price on file.
function M.price_of(id)
    local name = item_name(id)
    if name == nil then return 0, false end
    local p = price_map[name:lower()]
    if p == nil or p == 0 then
        return p or 0, false
    end
    return p, true
end

--- Update the price for an item id in place (or append a new line), and save
--- the master file immediately.
function M.set_price(id, gil)
    local name = item_name(id)
    if name == nil then return false end
    gil = math.max(0, math.floor((tonumber(gil) or 0) + 0.5))

    local key = name:lower()
    for i, line in ipairs(price_lines) do
        local n = tostring(line):match('^%s*(.-)%s*:')
        if n ~= nil and n:lower() == key then
            price_lines[i] = name .. ':' .. gil
            M.rebuild()
            M.save_master()
            return true
        end
    end
    price_lines[#price_lines + 1] = name .. ':' .. gil
    M.rebuild()
    M.save_master()
    return true
end

--- Merge 'name:gil' lines into the master list: existing names updated in
--- place, new ones appended, junk skipped and counted. Saves immediately if
--- anything changed. Returns updated, added, skipped.
function M.merge_lines(lines)
    local index = {}
    for i, line in ipairs(price_lines) do
        local n = tostring(line):match('^%s*(.-)%s*:')
        if n ~= nil then index[n:lower()] = i end
    end

    local updated, added, skipped = 0, 0, 0
    for _, raw in ipairs(lines) do
        local line = tostring(raw or ''):gsub('[\r\n]', '')
        local name, price = line:match('^%s*(.-)%s*:%s*(-?%d+)%s*$')
        if name ~= nil and name ~= '' and tonumber(price) ~= nil and tonumber(price) >= 0 then
            local key = name:lower()
            local entry = trim(name) .. ':' .. price
            if index[key] ~= nil then
                price_lines[index[key]] = entry
                updated = updated + 1
            else
                price_lines[#price_lines + 1] = entry
                index[key] = #price_lines
                added = added + 1
            end
        elseif line:match('%S') then
            skipped = skipped + 1
        end
    end

    M.rebuild()
    if updated > 0 or added > 0 then
        M.save_master()
    end
    return updated, added, skipped
end

--------------------------------------------------------------------------------
-- seen-item tracking (drives the per-item price grid)
--------------------------------------------------------------------------------

function M.see(id)
    if type(id) == 'number' and id > 0 and id ~= 65535 then
        seen[id] = true
    end
end

--- Walk finished synth rows and register every item they touched.
function M.seed_from_history(history)
    if history == nil then return end
    for _, row in pairs(history) do
        M.see(row.crystal)
        M.see(row.item)
        for _, id in pairs(row.ingredients or {}) do M.see(id) end
        for _, id in pairs(row.lost or {}) do M.see(id) end
    end
end

--- Seen ids, sorted by item name for a stable grid order.
function M.seen_ids()
    local ids = {}
    for id in pairs(seen) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        local na, nb = item_name(a) or tostring(a), item_name(b) or tostring(b)
        return na:lower() < nb:lower()
    end)
    return ids
end

--- Turn a chat-log item phrase ('12 pieces of willow lumber', 'a bronze ingot')
--- into an item id. Matches items we've actually crafted with, on all three
--- name forms (short / log singular / log plural), then falls back to a direct
--- name lookup. Returns id or nil.
function M.resolve_item(phrase)
    if phrase == nil then return nil end
    phrase = tostring(phrase):lower():gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')

    -- peel leading articles / stack counts in any order: "the 12 ", "12 ", "a "
    local prev
    repeat
        prev = phrase
        phrase = phrase:gsub('^the%s+', '')
        phrase = phrase:gsub('^an?%s+', '')
        phrase = phrase:gsub('^%d+%s+', '')
    until phrase == prev
    if phrase == '' then return nil end

    -- alternate forms to try:
    --  * naive singular: "pieces of x" -> "piece of x", trailing "s" dropped
    --  * measure word dropped: "block of animal glue" -> "animal glue"
    local singular = phrase:gsub('s$', ''):gsub('^pieces of ', 'piece of ')
    local base = phrase:match('^%a+ of (.+)$') or singular:match('^%a+ of (.+)$')
    local variants = { [phrase] = true, [singular] = true }
    if base then variants[base] = true end

    local res = AshitaCore:GetResourceManager()
    if res == nil then return nil end

    for _, id in ipairs(M.seen_ids()) do
        local it = res:GetItemById(id)
        if it ~= nil then
            for _, field in ipairs({ it.Name, it.LogNameSingular, it.LogNamePlural }) do
                local n = field and field[1]
                if n ~= nil and n ~= '' and variants[n:lower()] then
                    return id
                end
            end
        end
    end

    for _, cand in ipairs({ phrase, singular, base }) do
        if cand ~= nil then
            for _, lang in ipairs({ 2, 1, 0 }) do
                local ok, it = pcall(function() return res:GetItemByName(cand, lang) end)
                if ok and it ~= nil and it.Id ~= nil and it.Id > 0 then
                    return it.Id
                end
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- economics
--------------------------------------------------------------------------------

--- Cost / revenue / net for one finished synth row.
--- net, cost, revenue, priced. priced is false if any needed price was missing,
--- so callers can show the number as provisional.
function M.synth(row)
    local missing = false
    local function p(id)
        local v, found = M.price_of(id)
        if not found then missing = true end
        return v
    end

    local cost = p(row.crystal)

    -- result 1 == failure: you keep the returned mats, you are only out the
    -- crystal plus whatever landed in `lost`.
    if row.result == 1 then
        for _, id in pairs(row.lost or {}) do cost = cost + p(id) end
        return -cost, cost, 0, not missing
    end

    for _, id in pairs(row.ingredients or {}) do cost = cost + p(id) end
    local revenue = p(row.item) * (row.count or 1)
    return revenue - cost, cost, revenue, not missing
end

--- Projected economics for a recipe (from a data/recipesBySkill entry).
--- Returns a table so the cost half is usable on its own:
---   cost           sum of the inputs that DO have a price (partial if some are missing)
---   cost_priced    every input has a price on file
---   unpriced       how many inputs have no price
---   revenue        result price * yield
---   revenue_priced the result has a price on file
function M.recipe(recipe)
    local cost, unpriced = 0, 0
    local function p(id)
        local v, found = M.price_of(id)
        if found then
            cost = cost + v
        else
            unpriced = unpriced + 1
        end
    end

    p(recipe.crystal)
    for _, id in ipairs(recipe.ingredients or {}) do p(id) end

    local rev, rev_found = M.price_of(recipe.result)

    return {
        cost = cost,
        cost_priced = (unpriced == 0),
        unpriced = unpriced,
        revenue = rev * (recipe.count or 1),
        revenue_priced = rev_found,
    }
end

--- Stable key for a recipe / synth: "<crystal>|<sorted,ingredient,ids>".
--- Matches the key layout of data/recipesByIngredients.
function M.recipe_key(crystal, ingredients)
    local ing = {}
    for _, id in ipairs(ingredients or {}) do ing[#ing + 1] = id end
    table.sort(ing)
    return tostring(crystal) .. '|' .. table.concat(ing, ',')
end

--- True per-unit cost of an item from your own synth history: total material
--- gil spent on this exact recipe divided by total units it actually produced
--- (failures add cost, zero units). Handles Horizon's variable yields.
--- Returns { synths, priced_synths, units, spent, unit_cost }  (unit_cost nil
--- until there is at least one fully-priced successful synth).
function M.observed_cost(key, history)
    local r = { synths = 0, priced_synths = 0, units = 0, spent = 0, unit_cost = nil }
    if history == nil then return r end

    for _, row in pairs(history) do
        if M.recipe_key(row.crystal, row.ingredients) == key then
            r.synths = r.synths + 1
            local _, cost, _, priced = M.synth(row)
            if priced then
                r.priced_synths = r.priced_synths + 1
                r.spent = r.spent + cost
                if row.result ~= 1 then
                    r.units = r.units + (row.count or 0)
                end
            end
        end
    end

    if r.units > 0 and r.priced_synths > 0 then
        r.unit_cost = r.spent / r.units
    end
    return r
end

--- How many times this recipe can be made from what is in `inv`
--- (a { [itemId] = count } map, e.g. from GetInventoryTotals). One crystal is
--- assumed per synth; duplicate ingredients count as that many needed per synth.
function M.makeable(recipe, inv)
    inv = inv or {}

    local need = {}
    for _, id in ipairs(recipe.ingredients or {}) do
        need[id] = (need[id] or 0) + 1
    end

    local possible = inv[recipe.crystal] or 0   -- floor(have / 1 crystal)
    for id, per in pairs(need) do
        local n = math.floor((inv[id] or 0) / per)
        if n < possible then possible = n end
    end

    if possible < 0 then return 0 end
    return possible
end

--- Roll up a history list into a session summary.
function M.totals(history)
    local t = { synths = 0, priced = 0, net = 0, hq = 0, success = 0, gph = 0 }
    if history == nil or #history == 0 then return t end

    local newest, oldest = nil, nil
    for _, row in pairs(history) do
        t.synths = t.synths + 1
        if row.result ~= nil and row.result ~= 1 then t.success = t.success + 1 end
        if type(row.result) == 'number' and row.result >= 2 then t.hq = t.hq + 1 end

        local net, _, _, priced = M.synth(row)
        if priced then
            t.priced = t.priced + 1
            t.net = t.net + net
        end

        local ts = tonumber(row.startTime)
        if ts ~= nil and ts > 0 then
            if newest == nil or ts > newest then newest = ts end
            if oldest == nil or ts < oldest then oldest = ts end
        end
    end

    if newest ~= nil and oldest ~= nil and newest > oldest then
        t.gph = t.net / (newest - oldest) * 3600
    end
    return t
end

return M
