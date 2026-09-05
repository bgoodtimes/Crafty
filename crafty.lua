addon.name    = 'crafty'
addon.author  = 'lin (xitools); standalone port'
addon.version = '2.3'
addon.desc    = 'A crafting skill tracker and recipe list'

require('common')
local bit = require('bit')
local chat = require('chat')
local imgui = require('imgui')
local settings = require('settings')
local ffxi = require('utils/ffxi')
local packets = require('utils/packets')
local recipesByIngredients = require('data.recipesByIngredients')
local recipesBySkill = require('data.recipesBySkill')
local theme = require('libs.theme')
local economy = require('libs.economy')
local fonts = require('libs.fonts')

local iconTimes = '\xef\x81\x97'
local iconCheck = '\xef\x81\x98'
local imguiLeafNode = bit.bor(ImGuiTreeNodeFlags_Leaf, ImGuiTreeNodeFlags_NoTreePushOnOpen)
local inProgSynth = nil

local crystalMap = {
    -- nq crystals
    [4096] = 4096,
    [4097] = 4097,
    [4098] = 4098,
    [4099] = 4099,
    [4100] = 4100,
    [4101] = 4101,
    [4102] = 4102,
    [4103] = 4103,
    -- hq crystals
    [4238] = 4096,
    [4239] = 4097,
    [4240] = 4098,
    [4241] = 4099,
    [4242] = 4100,
    [4243] = 4101,
    [4244] = 4102,
    [4245] = 4103,
    -- some other shit
    [6506] = 4096,
    [6507] = 4097,
    [6508] = 4098,
    [6509] = 4099,
    [6510] = 4100,
    [6511] = 4101,
    [6512] = 4102,
    [6513] = 4103,
}

local skillsMap = {
    [1] = 'Woodworking',
    [2] = 'Smithing',
    [3] = 'Goldsmithing',
    [4] = 'Clothcraft',
    [5] = 'Leathercraft',
    [6] = 'Bonecraft',
    [7] = 'Alchemy',
    [8] = 'Cooking',
}

local skillsAbbrMap = {
    [1] = 'CRP',
    [2] = 'BSM',
    [3] = 'GSM',
    [4] = 'WVR',
    [5] = 'LTW',
    [6] = 'BON',
    [7] = 'ALC',
    [8] = 'CUL',
}

local resultsMap = {
    [0] = 'NQ',
    [1] = 'Fail',
    [2] = 'HQ1',
    [3] = 'HQ2',
    [4] = 'HQ3',
}

-- result quality -> semantic colour, for the history table
local resultColorMap = {
    [0] = 'good',
    [1] = 'bad',
    [2] = 'info',
    [3] = 'info',
    [4] = 'info',
}

-- mutable state, forward-declared so every draw / handler below can see it
local options              -- the live settings table (swapped on relog)
local HandleText           -- defined lower; the command handler references it
local CraftyPrint          -- defined lower; chat helper
local InvalidatePriceRefs  -- defined lower; drops cached price-grid InputInt refs
local priceLog = { false } -- /crafty pricelog: dump text_in lines to a file
local recipeEditState = {} -- [recipeKey] = { open, count = {n}, name = {''} }  transient
local sellEditState = {}    -- [recipeKey] = { ref = { gil } }  inline result-price editor

-- gil-on-hand tracking. The baseline (sessionGil0) is taken a couple of seconds
-- after a character is loaded and their gil has settled, so a mid-zone-in
-- transient never becomes the start value; it resets on any login/logout and
-- on a character change.
local gilNow, gilPrev = nil, nil        -- current / previous-frame gil
local sessionGil0 = nil                 -- start-of-session gil (nil until settled)
local sessionChar = nil                 -- character the baseline belongs to
local sessionCharSince = 0              -- os.time() the current character was first seen
local gilLastSeen = 0                   -- os.time() we last saw a loaded-in player
local pendingNpc = nil                  -- { phrase, sold, base, t } awaiting a gil delta

-- debounced autosave: any edit calls MarkDirty(); FlushDirty() writes the file
-- ~1s after edits stop (and unconditionally on unload). No imgui introspection,
-- so it cannot silently no-op the way an IsItemDeactivatedAfterEdit gate can.
local saveDirty = false
local saveDirtyAt = 0
local function MarkDirty()
    saveDirty = true
    saveDirtyAt = os.clock()
end
local function FlushDirty(force)
    if not saveDirty then return end
    if not force and (os.clock() - saveDirtyAt) < 0.75 then return end
    saveDirty = false
    settings.save()
end

--------------------------------------------------------------------------------
-- small styling helpers, in the spirit of floos' DarkGold theme
--------------------------------------------------------------------------------

local childBorderFlag = ImGuiChildFlags_Borders or ImGuiChildFlags_Border or 1

local function BeginPanel(id, height)
    local size = { 0, height or 0 }
    local ok, shown = pcall(imgui.BeginChild, id, size, childBorderFlag)
    if ok then return shown end
    ok, shown = pcall(imgui.BeginChild, id, size, true)
    if ok then return shown end
    return imgui.BeginChild(id, size)
end

local function EndPanel()
    imgui.EndChild()
end

local function Header(text)
    imgui.TextColored(theme.colors.text_gold, text)
end

local function TextDim(text)
    imgui.TextColored(theme.colors.text_dim, text)
end

-- Panel opacity / rounding / border thickness, layered on top of whichever
-- theme.apply_style() just pushed. Push right after theme.apply_style(),
-- pop with theme.pop_style() (same counts shape) before popping the theme.
local function ApplyPanelOverrides()
    local o = options.ui
    local counts = { colors = 0, vars = 0 }
    if o == nil then return counts end

    local bg = { theme.bg_dark[1], theme.bg_dark[2], theme.bg_dark[3], o.panelOpacity[1] }
    if pcall(imgui.PushStyleColor, ImGuiCol_WindowBg, bg) then
        counts.colors = counts.colors + 1
    end

    local function pushvar(idx, val)
        if pcall(imgui.PushStyleVar, idx, val) then
            counts.vars = counts.vars + 1
        end
    end
    pushvar(ImGuiStyleVar_WindowRounding, o.panelRounding[1])
    pushvar(ImGuiStyleVar_ChildRounding, o.panelRounding[1])
    pushvar(ImGuiStyleVar_WindowBorderSize, o.borderThickness[1])
    pushvar(ImGuiStyleVar_ChildBorderSize, o.borderThickness[1])

    return counts
end

--------------------------------------------------------------------------------

local function GetInventoryTotals()
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    local cumInv = {}
    -- the inventory array is not guaranteed to be compact, but counting id=0 or
    -- id=65535 is fine
    for i = 1, inv:GetContainerCountMax(0) do
        local slot = inv:GetContainerItem(0, i)
        if cumInv[slot.Id] == nil then
            cumInv[slot.Id] = slot.Count
        else
            cumInv[slot.Id] = cumInv[slot.Id] + slot.Count
        end
    end

    return cumInv
end

-- Gil is inventory container 0, slot 0. Returns nil when not logged in.
local function GilOnHand()
    if GetPlayerEntity() == nil then return nil end
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    if inv == nil then return nil end
    local slot = inv:GetContainerItem(0, 0)
    return slot and slot.Count or nil
end

-- toggled by the [edit] button on the main window's skill header
local skillsEdit = { false }

local function DrawSkills(skills)
    if imgui.BeginTable('crafty.skills', 4, ImGuiTableFlags_SizingFixedFit) then
        imgui.PushStyleVar(ImGuiStyleVar_CellPadding, { 14, 3 })
        for id = 1, 8 do
            local level = skills[id][1]
            imgui.TableNextColumn()
            TextDim(skillsMap[id])
            imgui.TableNextColumn()
            local col = level > 0 and theme.colors.text_light or theme.colors.text_dim
            imgui.TextColored(col, ('%.1f'):format(level))
        end
        imgui.PopStyleVar()
        imgui.EndTable()
    end
end

-- clamp + queue a save when an InputFloat reports a change
local function EditedFloat(changed, refTable, lo, hi)
    if refTable[1] < lo then refTable[1] = lo end
    if refTable[1] > hi then refTable[1] = hi end
    if changed then MarkDirty() end
end

-- inline editor: two columns of InputFloats keyed by craft abbreviation
local function DrawSkillsEdit(skills)
    imgui.PushItemWidth(70)
    for id = 1, 8 do
        if id % 2 == 0 then
            imgui.SameLine(0, 14)
        end
        local ch = imgui.InputFloat(skillsAbbrMap[id] .. '##crafty.skilledit' .. id, skills[id], 0.1, 1.0, '%.1f')
        EditedFloat(ch, skills[id], 0, 200)
    end
    imgui.PopItemWidth()
end

-- re-baseline the session gil tracker to the current gil-on-hand
local function ResetGil()
    local g = GilOnHand()
    if g == nil then return end
    sessionGil0 = g
    CraftyPrint(('gil tracker reset - start %s'):format(economy.gil(g)))
end

-- session gil: start, now, and profit. No time / rate.
local function DrawGil()
    if gilNow == nil or sessionGil0 == nil then return end
    local sp = gilNow - sessionGil0
    imgui.TextColored(theme.state_color(sp >= 0 and 'good' or 'bad'),
        ('session %s%s'):format(sp > 0 and '+' or '', economy.gil(sp)))
    imgui.SameLine()
    if imgui.SmallButton('reset##crafty.gilreset') then
        ResetGil()
    end
    TextDim(('%s  ->  %s'):format(economy.gil(sessionGil0), economy.gil(gilNow)))
end

-- Stable id for a recipe ("<crystal>|<sorted,ingredient,ids>"), shared with the
-- override system and the live synth speculation in HandlePacketOut.
local RecipeKey = economy.recipe_key

-- lazy key -> full recipesBySkill entry index, built on first favourites use
local recipeByKey = nil
local function RecipeByKey(key)
    if recipeByKey == nil then
        recipeByKey = {}
        for _, chunk in ipairs(recipesBySkill) do
            for _, r in ipairs(chunk) do
                recipeByKey[RecipeKey(r.crystal, r.ingredients)] = r
            end
        end
    end
    return recipeByKey[key]
end

-- lazy result-item-id -> recipe(s) that produce it, built on first drill-down.
-- Keyed by the base data's own result (not any output override) - overrides
-- don't change what's craftable, only what a specific recipe is speculated to
-- yield.
local recipesByResult = nil
local function RecipesForItem(itemId)
    if recipesByResult == nil then
        recipesByResult = {}
        for _, chunk in ipairs(recipesBySkill) do
            for _, r in ipairs(chunk) do
                local list = recipesByResult[r.result]
                if list == nil then
                    list = {}
                    recipesByResult[r.result] = list
                end
                list[#list + 1] = r
            end
        end
    end
    return recipesByResult[itemId]
end

-- price suffix: shows an item's entered price, or flags it as missing
local function priceTag(id)
    local price, priced = economy.price_of(id)
    if priced then return '   ' .. economy.gil(price) end
    return '   (no price)'
end

-- forward-declared: DrawIngredientLine and DrawRecipe recurse into each other
-- (an ingredient line drills into that item's own recipe, which has its own
-- ingredient lines, ...)
local DrawRecipe

local MAX_DRILLDOWN_DEPTH = 5 -- backstop against a pathological/cyclic recipe chain

local FAVORITES_MAX = 15

local function IsFavorite(key)
    for _, k in ipairs(options.favorites or {}) do
        if k == key then return true end
    end
    return false
end

local function ToggleFavorite(key)
    if options.favorites == nil then options.favorites = T{} end
    for i, k in ipairs(options.favorites) do
        if k == key then
            table.remove(options.favorites, i)
            MarkDirty()
            return
        end
    end
    if #options.favorites >= FAVORITES_MAX then
        CraftyPrint(('favorites full (%d) - remove one first'):format(FAVORITES_MAX))
        return
    end
    options.favorites:append(key)
    MarkDirty()
end

-- original result item id for a key, looked up in the bundled recipe data
-- (used to label imported overrides that carry no src of their own)
local function OverrideSrc(key)
    local crystalStr, hash = tostring(key):match('^(%d+)|(.*)$')
    local c = tonumber(crystalStr)
    local byCrystal = c and recipesByIngredients[c]
    local entry = byCrystal and byCrystal[hash]
    return entry and entry.itemId or 0
end

-- effective output for a recipesBySkill entry: result id, yield, overridden?
local function EffectiveOutput(recipe)
    local ov = options.recipeOverrides and options.recipeOverrides[RecipeKey(recipe.crystal, recipe.ingredients)]
    if ov == nil then
        return recipe.result, recipe.count, false
    end
    local result = (ov.result ~= nil and ov.result ~= 0) and ov.result or recipe.result
    local count = (ov.count ~= nil and ov.count > 0) and ov.count or recipe.count
    return result, count, true
end

-- the "output: X xN [edit]" row and its inline editor
local function DrawOutputEditor(recipe, res)
    local key = RecipeKey(recipe.crystal, recipe.ingredients)
    local eResult, eCount, edited = EffectiveOutput(recipe)
    local outName = res:GetItemById(eResult).LogNameSingular[1] or tostring(eResult)

    imgui.PushStyleColor(ImGuiCol_Text, edited and theme.colors.text_gold or theme.colors.text_dim)
    imgui.TreeNodeEx(('output: %s x%i%s'):format(outName, eCount, edited and '  (edited)' or ''), imguiLeafNode)
    imgui.PopStyleColor()
    imgui.SameLine()

    local st = recipeEditState[key]
    if imgui.SmallButton((st and 'close' or 'edit') .. '##ovtoggle') then
        if st then
            recipeEditState[key] = nil
        else
            recipeEditState[key] = { count = { eCount }, name = { '' } }
        end
        st = recipeEditState[key]
    end

    if st == nil then return end

    imgui.Indent()
    imgui.PushItemWidth(80)
    imgui.InputInt('yield (result count)##ov', st.count)
    if st.count[1] < 1 then st.count[1] = 1 end
    imgui.PopItemWidth()

    imgui.PushItemWidth(180)
    imgui.InputText('result item (blank = keep)##ov', st.name, 64)
    imgui.PopItemWidth()

    local newId = nil
    if st.name[1] ~= '' then
        newId = economy.resolve_item(st.name[1])
        imgui.SameLine()
        if newId then
            imgui.TextColored(theme.state_color('good'), economy.item_name(newId) or ('#' .. newId))
        else
            imgui.TextColored(theme.state_color('bad'), 'not found')
        end
    end

    if imgui.SmallButton('save##ov') then
        if options.recipeOverrides == nil then options.recipeOverrides = T{} end
        local prev = options.recipeOverrides[key]
        local resultId = 0
        if newId ~= nil then
            resultId = newId
        elseif prev ~= nil and prev.result then
            resultId = prev.result
        end
        options.recipeOverrides[key] = T{
            src = recipe.result,
            result = resultId,
            count = st.count[1],
        }
        settings.save()
        recipeEditState[key] = nil
    end

    if recipeEditState[key] ~= nil then
        imgui.SameLine()
        if imgui.SmallButton('reset to default##ov') then
            if options.recipeOverrides then options.recipeOverrides[key] = nil end
            settings.save()
            recipeEditState[key] = nil
        end
    end

    imgui.Unindent()
end

-- "[edit price]" toggle for the result item's per-unit sell price, shown on the
-- same line as the sell/margin figure so you don't have to open config.
-- scopeKey keeps the open-state tied to this specific recipe view.
local function DrawSellPriceEditor(scopeKey, eResult)
    local st = sellEditState[scopeKey]
    imgui.SameLine()
    if imgui.SmallButton((st and 'done##selltoggle' or 'edit price##selltoggle')) then
        if st then
            sellEditState[scopeKey] = nil
        else
            sellEditState[scopeKey] = { ref = { (economy.price_of(eResult)) } }
        end
        st = sellEditState[scopeKey]
    end
    if st == nil then return end

    imgui.Indent()
    imgui.PushItemWidth(90)
    local nm = economy.item_name(eResult) or ('#' .. eResult)
    if imgui.InputInt(nm .. ' each##sellprice', st.ref) then
        if st.ref[1] < 0 then st.ref[1] = 0 end
        economy.set_price(eResult, st.ref[1])
        InvalidatePriceRefs()
    end
    imgui.PopItemWidth()
    imgui.Unindent()
end

-- One "(count) name  price" line. If the item is itself a recipe result, it's
-- an expandable node - opening it drills straight into that item's own
-- recipe(s), right there, instead of having to search for it separately.
-- idSuffix must be unique among sibling lines in the same parent (an item id
-- can repeat within one recipe's ingredient list, e.g. 3x of the same item).
local function DrawIngredientLine(itemId, count, idSuffix, res, skills, inv, seenKeys, depth)
    local name = res:GetItemById(itemId).LogNameSingular[1] or tostring(itemId)
    local label = ('(%3i) %s%s'):format(count, name, priceTag(itemId))
    local color = count > 0 and theme.colors.text_light or theme.colors.text_dim
    local recipes = (depth < MAX_DRILLDOWN_DEPTH) and RecipesForItem(itemId) or nil

    if recipes == nil or #recipes == 0 then
        imgui.PushStyleColor(ImGuiCol_Text, color)
        imgui.TreeNodeEx(label, imguiLeafNode)
        imgui.PopStyleColor()
        return
    end

    imgui.PushID(idSuffix)
    imgui.PushStyleColor(ImGuiCol_Text, color)
    local open = imgui.TreeNode(label)
    imgui.PopStyleColor()

    if open then
        imgui.Indent()
        for i, sub in ipairs(recipes) do
            local subKey = RecipeKey(sub.crystal, sub.ingredients)
            local drawInline = function()
                if seenKeys[subKey] then
                    imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
                    imgui.TreeNodeEx('(already shown above - would loop)', imguiLeafNode)
                    imgui.PopStyleColor()
                else
                    DrawRecipe(sub, skills, inv, res, seenKeys, depth + 1)
                end
            end
            if #recipes == 1 then
                drawInline()
            else
                local eResult, eCount = EffectiveOutput(sub)
                local subName = res:GetItemById(eResult).LogNameSingular[1] or tostring(eResult)
                imgui.PushID(i)
                if imgui.TreeNode(('recipe %i: %s x%i'):format(i, subName, eCount)) then
                    drawInline()
                    imgui.TreePop()
                end
                imgui.PopID()
            end
        end
        imgui.Unindent()
        imgui.TreePop()
    end
    imgui.PopID()
end

DrawRecipe = function(recipe, skills, inv, res, seenKeys, depth)
    seenKeys = seenKeys or {}
    depth = depth or 0
    local myKey = RecipeKey(recipe.crystal, recipe.ingredients)
    seenKeys[myKey] = true

    DrawOutputEditor(recipe, res)

    -- favourite toggle
    local isFav = IsFavorite(myKey)
    imgui.PushStyleColor(ImGuiCol_Text, isFav and theme.colors.text_gold or theme.colors.text_dim)
    if imgui.SmallButton((isFav and 'remove from favorites' or 'add to favorites') .. '##fav') then
        ToggleFavorite(myKey)
    end
    imgui.PopStyleColor()

    -- first we display the skill requirements and whether the player meets them
    for skillId, skillLevel in ipairs(recipe.skills) do
        if skillLevel > 0 then
            local indicator = iconTimes
            local color = theme.state_color('bad')
            if skills[skillId][1] + 14 > skillLevel then
                indicator = iconCheck
                color = theme.state_color('good')
            end
            imgui.PushStyleColor(ImGuiCol_Text, color)
            imgui.TreeNodeEx(('%s %s %i'):format(indicator, skillsMap[skillId], skillLevel), imguiLeafNode)
            imgui.PopStyleColor()
        end
    end

    -- then we show any key item requirements
    if recipe.keyItem > 0 then
        local hasKeyItem = AshitaCore:GetMemoryManager():GetPlayer():HasKeyItem(recipe.keyItem)
        local keyItemName = res:GetString('keyitems.names', recipe.keyItem)
        local indicator = iconTimes
        local color = theme.state_color('bad')
        if hasKeyItem then
            indicator = iconCheck
            color = theme.state_color('good')
        end
        imgui.PushStyleColor(ImGuiCol_Text, color)
        imgui.TreeNodeEx(('%s %s'):format(indicator, keyItemName), imguiLeafNode)
        imgui.PopStyleColor()
    end

    -- finally the ingredient list begins with the crystal - each line drills
    -- into that item's own recipe if it has one (crystals never do). depth is
    -- NOT incremented here; DrawIngredientLine bumps it only when it actually
    -- recurses into a sub-recipe, so depth counts recipe levels, not lines.
    local crystalCount = inv[recipe.crystal] or 0
    DrawIngredientLine(recipe.crystal, crystalCount, 'crystal', res, skills, inv, seenKeys, depth)

    -- and ends with the remaining items
    for i, ingredientId in ipairs(recipe.ingredients) do
        local ingredientCount = inv[ingredientId] or 0
        DrawIngredientLine(ingredientId, ingredientCount, 'ing' .. i, res, skills, inv, seenKeys, depth)
    end

    -- apply any Horizon output override for the economics below
    local eResult, eCount = EffectiveOutput(recipe)
    local rec = recipe
    if eResult ~= recipe.result or eCount ~= recipe.count then
        rec = {
            result = eResult, count = eCount,
            crystal = recipe.crystal, keyItem = recipe.keyItem,
            ingredients = recipe.ingredients, skills = recipe.skills, id = recipe.id,
        }
    end

    -- how many of this recipe the current inventory can make
    local makeable = economy.makeable(rec, inv)
    imgui.PushStyleColor(ImGuiCol_Text, makeable > 0 and theme.colors.text_light or theme.colors.text_dim)
    imgui.TreeNodeEx(('makeable now: %i'):format(makeable), imguiLeafNode)
    imgui.PopStyleColor()

    -- projected economics from the entered prices
    local econ = economy.recipe(rec)
    if econ.cost_priced then
        local breakeven = econ.cost / math.max(1, rec.count or 1)

        -- cost only needs the input prices
        imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
        imgui.TreeNodeEx(('cost %s   break-even %s/ea'):format(
            economy.gil(econ.cost), economy.gil(breakeven)), imguiLeafNode)
        imgui.PopStyleColor()
        -- treat this as an intermediate: save the crafted unit cost as its price
        imgui.SameLine()
        if imgui.SmallButton('save##craftcost') then
            economy.set_price(eResult, breakeven)
            InvalidatePriceRefs()
            CraftyPrint(('price list: %s set to %s (crafted cost)'):format(
                economy.item_name(eResult) or ('#' .. eResult), economy.gil(breakeven)))
        end
        if makeable > 0 then
            imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
            imgui.TreeNodeEx(('make all %i: %s cost'):format(makeable, economy.gil(econ.cost * makeable)), imguiLeafNode)
            imgui.PopStyleColor()
        end

        -- margin / profit needs the result price too
        if econ.revenue_priced then
            local margin = econ.revenue - econ.cost
            imgui.PushStyleColor(ImGuiCol_Text, theme.state_color(margin >= 0 and 'good' or 'bad'))
            imgui.TreeNodeEx(('sell %s   margin %s per synth'):format(
                economy.gil(econ.revenue), economy.gil(margin)), imguiLeafNode)
            imgui.PopStyleColor()
            DrawSellPriceEditor(myKey, eResult)
            if makeable > 0 then
                local batch = margin * makeable
                imgui.PushStyleColor(ImGuiCol_Text, theme.state_color(batch >= 0 and 'good' or 'bad'))
                imgui.TreeNodeEx(('use it all (%i): %s profit   [%s sell]'):format(
                    makeable, economy.gil(batch), economy.gil(econ.revenue * makeable)), imguiLeafNode)
                imgui.PopStyleColor()
            end
        else
            imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
            imgui.TreeNodeEx('set the result price for margin', imguiLeafNode)
            imgui.PopStyleColor()
            DrawSellPriceEditor(myKey, eResult)
        end
    elseif econ.cost > 0 then
        -- partial: show what we have and how many inputs still need a price
        imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
        imgui.TreeNodeEx(('cost so far %s   (%i ingredient%s unpriced)'):format(
            economy.gil(econ.cost), econ.unpriced, econ.unpriced == 1 and '' or 's'), imguiLeafNode)
        imgui.PopStyleColor()
    else
        imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
        imgui.TreeNodeEx('set crystal + ingredient prices to see cost', imguiLeafNode)
        imgui.PopStyleColor()
    end

    -- true per-unit cost from your own synth history (handles variable yields:
    -- total gil spent on this recipe / total units it actually produced)
    local obs = economy.observed_cost(RecipeKey(recipe.crystal, recipe.ingredients), options.history)
    if obs.unit_cost ~= nil then
        imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_light)
        imgui.TreeNodeEx(('true cost %s/ea'):format(economy.gil(obs.unit_cost)), imguiLeafNode)
        imgui.PopStyleColor()
        imgui.SameLine()
        if imgui.SmallButton('save##truecost') then
            economy.set_price(eResult, obs.unit_cost)
            InvalidatePriceRefs()
            CraftyPrint(('price list: %s set to %s (true cost, %i units / %i synths)'):format(
                economy.item_name(eResult) or ('#' .. eResult), economy.gil(obs.unit_cost),
                obs.units, obs.priced_synths))
        end
        imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
        imgui.TreeNodeEx(('%i units / %i synths / %s'):format(
            obs.units, obs.priced_synths, economy.gil(obs.spent)), imguiLeafNode)
        imgui.PopStyleColor()
    elseif obs.synths > 0 then
        imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
        imgui.TreeNodeEx(('%i past synth%s of this - price the inputs for a true cost'):format(
            obs.synths, obs.synths == 1 and '' or 's'), imguiLeafNode)
        imgui.PopStyleColor()
    end

    seenKeys[myKey] = nil -- pop: only ancestors should ever be flagged, not siblings
end

local recipeFilter = { '' }
local searchResults = { [''] = { } }
local function FilterRecipes(filter)
    local res = AshitaCore:GetResourceManager()
    if searchResults[filter] == nil then
        searchResults[filter] = { }
        -- TODO: remove the "by skill" bits
        for skillId, recipeList in ipairs(recipesBySkill) do
            for _, recipe in ipairs(recipeList) do
                -- the abbreviated names are not always conducive to search, so we
                -- will test against both it and the full name
                local item = res:GetItemById(recipe.result)
                local itemName = item.Name[1]
                local fullName = item.LogNameSingular[1]
                if itemName:lower():match(filter)
                or fullName:lower():match(filter) then
                    table.insert(searchResults[filter], recipe)
                end
            end
        end
    end
end

local function DrawFilteredRecipes(skills, filteredRecipes)
    -- there are thousands of recipes in the game, and drawing all of them in
    -- imgui is going to be a huge performance hit. we could certainly limit the
    -- search to >2 characters, but i feel it's better to just truncate the list
    local res = AshitaCore:GetResourceManager()
    local inv = GetInventoryTotals()
    local displayCount = math.min(32, #filteredRecipes)

    for i=1,displayCount do
        local recipe = filteredRecipes[i]
        local eResult, eCount, edited = EffectiveOutput(recipe)
        local itemName = res:GetItemById(eResult).LogNameSingular[1] or tostring(eResult)

        imgui.PushID(('%s%i'):format(recipe.result, recipe.id))
        if imgui.TreeNode(('%s x%i%s'):format(itemName, eCount, edited and ' *' or '')) then
            DrawRecipe(recipe, skills, inv, res)
            imgui.TreePop()
        end
        imgui.PopID()
    end

    if #filteredRecipes > 32 then
        imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
        imgui.TreeNodeEx(('%i recipes found; results truncated'):format(#filteredRecipes), imguiLeafNode)
        imgui.PopStyleColor()
    end
end

local function DrawFavorites(skills)
    local favs = options.favorites
    if favs == nil or #favs == 0 then return end
    if not imgui.CollapsingHeader('Favorites') then return end

    local res = AshitaCore:GetResourceManager()
    local inv = GetInventoryTotals()
    for _, key in ipairs(favs) do
        local recipe = RecipeByKey(key)
        if recipe ~= nil then
            local eResult, eCount, edited = EffectiveOutput(recipe)
            local itemName = res:GetItemById(eResult).LogNameSingular[1] or tostring(eResult)
            imgui.PushID('fav' .. key)
            if imgui.TreeNode(('%s x%i%s'):format(itemName, eCount, edited and ' *' or '')) then
                DrawRecipe(recipe, skills, inv, res)
                imgui.TreePop()
            end
            imgui.PopID()
        else
            imgui.PushStyleColor(ImGuiCol_Text, theme.colors.text_dim)
            imgui.TreeNodeEx(('(recipe not found: %s)'):format(key), imguiLeafNode)
            imgui.PopStyleColor()
        end
    end
end

local function DrawRecipes(skills)
    if imgui.CollapsingHeader('Recipe List') then
        if imgui.InputText('search recipes', recipeFilter, 256) then
            FilterRecipes(recipeFilter[1]:lower())
        end

        DrawFilteredRecipes(skills, searchResults[recipeFilter[1]:lower()] or { })
    end
end

local function DrawHistory(options)
    if imgui.CollapsingHeader('Craft History') then
        local textBaseWidth = imgui.CalcTextSize('A')

        if imgui.SmallButton('Clear History') then
            options.history = T{}
        end

        local history = options.history

        -- session summary line
        local t = economy.totals(history)
        if t.synths > 0 then
            local pct = function(n) return math.floor((n / t.synths) * 100 + 0.5) end
            imgui.PushStyleColor(ImGuiCol_Text, theme.state_color(t.net >= 0 and 'good' or 'bad'))
            imgui.Text(('%s'):format(economy.gil(t.net)))
            imgui.PopStyleColor()
            imgui.SameLine()
            TextDim(('over %i/%i priced   ~%s/hr   HQ %i%%   ok %i%%'):format(
                t.priced, t.synths, economy.gil(t.gph), pct(t.hq), pct(t.success)))
        end

        if imgui.BeginTable('crafty.history', 4, bit.bor(ImGuiTableFlags_ScrollY, ImGuiTableFlags_RowBg), { textBaseWidth * 66, 360 }) then
            local res = AshitaCore:GetResourceManager()
            imgui.TableSetupScrollFreeze(0, 1)
            imgui.TableSetupColumn('Synth', ImGuiTableColumnFlags_NoHide, textBaseWidth * 26)
            imgui.TableSetupColumn('Result', ImGuiTableColumnFlags_NoHide, textBaseWidth * 7)
            imgui.TableSetupColumn('Skillup', ImGuiTableColumnFlags_NoHide, textBaseWidth * 16)
            imgui.TableSetupColumn('Profit', ImGuiTableColumnFlags_NoHide, textBaseWidth * 10)
            imgui.TableHeadersRow()

            for i, synth in pairs(history) do
                imgui.TableNextRow()

                imgui.TableNextColumn()
                if synth.count > 1 then
                    imgui.Text(('%s x%i'):format(res:GetItemById(synth.item).Name[1] or synth.item, synth.count))
                else
                    imgui.Text(('%s'):format(res:GetItemById(synth.item).Name[1] or synth.item))
                end

                imgui.TableNextColumn()
                imgui.TextColored(theme.state_color(resultColorMap[synth.result] or 'neutral'), resultsMap[synth.result] or 'Unknown')

                imgui.TableNextColumn()
                local skillups = T{ }
                for skillId, skillup in pairs(synth.skillup) do
                    if skillup.change ~= nil then
                        skillups:append(('%s %+.1f'):format(skillsAbbrMap[skillId] or skillId, skillup.change))
                    end
                end
                if #skillups > 0 then
                    imgui.TextColored(theme.state_color('good'), skillups:join(' '))
                else
                    TextDim('-')
                end

                imgui.TableNextColumn()
                local net, _, _, priced = economy.synth(synth)
                if priced then
                    imgui.TextColored(theme.state_color(net >= 0 and 'good' or 'bad'), economy.gil(net))
                else
                    TextDim(economy.gil(net) .. ' ?')
                end

                for _, itemId in pairs(synth.lost) do
                    imgui.TableNextRow()
                    imgui.TableNextColumn()
                    imgui.TextColored(theme.state_color('bad'), ('    lost %s'):format(res:GetItemById(itemId).Name[1] or itemId))
                end
            end
            imgui.EndTable()
        end
    end
end

--------------------------------------------------------------------------------

-- Read the configured palette name, tolerating a missing/renamed value.
local function ThemeName()
    local bt = options.background_theme
    local name = bt and bt[1] or nil
    if name ~= nil and theme.palettes[name] ~= nil then
        return name
    end
    return 'DarkGold'
end

local defaultSettings = T{
    isVisible = T{ true },
    configVisible = T{ false },
    name = 'crafty',
    size = T{ -1, -1 },
    pos = T{ 100, 100 },
    flags = ImGuiWindowFlags_AlwaysAutoResize,
    -- appearance
    background_theme = T{ 'DarkGold' },
    -- hide behaviour, ported from xitools' global toggles
    hideUnderMap = T{ true },
    hideUnderChat = T{ true },
    hideWhileLoading = T{ true },
    hideDuringEvent = T{ true },
    hideWithInterface = T{ true },
    skills = T{
        [0] = T{ 0.0 },
        [1] = T{ 0.0 },
        [2] = T{ 0.0 },
        [3] = T{ 0.0 },
        [4] = T{ 0.0 },
        [5] = T{ 0.0 },
        [6] = T{ 0.0 },
        [7] = T{ 0.0 },
        [8] = T{ 0.0 },
    },
    history = T{},
    -- watch the chat log for AH / bazaar purchase + sale lines and price from them
    learnPrices = T{ true },
    -- server-specific output fixes: [recipeKey] = { src, result, count }
    recipeOverrides = T{},
    -- quick-access recipe keys, shown in the Favorites header
    favorites = T{},
    -- appearance: font + panel feel, layered on top of the chosen theme
    ui = T{
        fontFamily = T{ 'Agave (Default)' },
        scale = T{ 1.0 },
        panelOpacity = T{ 0.95 },
        panelRounding = T{ 6 },
        borderThickness = T{ 1 },
    },
}

options = settings.load(defaultSettings)

if options.learnPrices == nil then
    options.learnPrices = T{ true }
end
if options.recipeOverrides == nil then
    options.recipeOverrides = T{}
end
if options.favorites == nil then
    options.favorites = T{}
end
if options.ui == nil then
    options.ui = defaultSettings.ui:copy(true)
end

-- Prices are a shared master list (config/addons/crafty/prices.txt), not part
-- of any one character's settings, so every character prices the same items
-- the same way. Load it, then fold in anything from this character's OLD
-- per-character price list (from before prices moved out of settings) and
-- clear that local copy so the one-time migration doesn't repeat.
economy.load_master()
economy.seed_from_history(options.history)
-- crystals are used by every craft; make them known even before the first synth
for id = 4096, 4103 do economy.see(id) end

if options.prices ~= nil and #options.prices > 0 then
    local updated, added = economy.merge_lines(options.prices)
    local n = updated + added
    print(chat.header('crafty'):append(chat.message(
        ('migrated %d price%s from this character into the shared price list'):format(
            n, n == 1 and '' or 's'))))
    options.prices = T{}
    MarkDirty()
end

local configWindow = {
    name = 'crafty##Config',
    size = T{ 460, 620 },
    pos = T{ 120, 120 },
    flags = ImGuiWindowFlags_NoCollapse,
}

local function HandleCommand(args)
    if #args == 0 then
        options.isVisible[1] = not options.isVisible[1]
        return
    end

    local verb = args[1]

    if verb == 'config' or verb == 'cfg' then
        options.configVisible[1] = not options.configVisible[1]
    elseif verb == 'cl' or verb == 'clear' then
        options.history = T{}
    elseif verb == 'pricetest' then
        -- /crafty pricetest You buy the 12 wind crystals for 700 gil.
        local line = table.concat(args, ' ', 2)
        if line == '' then
            print(chat.header('crafty'):append(chat.message('usage: /crafty pricetest <a purchase/sale line>')))
        else
            HandleText({ message = line }, true)
        end
    elseif verb == 'pricelog' then
        priceLog[1] = not priceLog[1]
        print(chat.header('crafty'):append(chat.message(priceLog[1]
            and ('logging chat lines to ' .. economy.dir() .. '/textlog.txt - buy something, then /crafty pricelog again')
            or 'chat line logging off')))
    elseif verb == 'prices' then
        economy.rebuild()
        local nl, nm, nb = economy.debug_summary()
        print(chat.header('crafty'):append(chat.message(
            ('price list: %d lines, %d in lookup, %d unreadable'):format(nl, nm, nb))))
    elseif verb == 'gil' then
        ResetGil()
    end
end

local function HandlePacketOut(e)
    -- if we've requested a synth from the server, start our in-progress
    -- tracker. speculate on the results, since "Mangled Mess" isn't a very
    -- useful item name.
    if e.id == 0x096 and inProgSynth == nil then
        local startSynth = packets.outbound.startSynth.parse(e.data)
        local crystal = crystalMap[startSynth.crystal]
        local sortedIngredients = T{}
        for i=0,startSynth.ingredientCount-1 do
            if startSynth.ingredient[i] ~= 0 then
                sortedIngredients:append(startSynth.ingredient[i])
            end
        end
        local ingredientHash = sortedIngredients:sort():join(',')
        local targetRecipe = recipesByIngredients[crystal][ingredientHash] or { itemId = 0, count = 0 }

        -- apply a saved Horizon output override to the speculation
        local specItem, specCount = targetRecipe.itemId, targetRecipe.count
        local ov = options.recipeOverrides and options.recipeOverrides[tostring(crystal) .. '|' .. ingredientHash]
        if ov ~= nil then
            if ov.result and ov.result ~= 0 then specItem = ov.result end
            if ov.count and ov.count > 0 then specCount = ov.count end
        end

        inProgSynth = {
            startTime = os.time(),
            result = nil,
            item = specItem,
            count = specCount,
            crystal = crystal,
            ingredients = sortedIngredients,
            lost = nil,
            skillup = T{ },
        }

        -- register everything consumed so it shows up in the price editor
        economy.see(crystal)
        for _, id in ipairs(sortedIngredients) do
            economy.see(id)
        end
    end
end

local function HandlePacket(e)
    -- we are immediately told what the result is via the animation the
    -- server wants us to play, and also get a more detailed value
    if e.id == 0x030 then
        local anim = packets.inbound.synthAnimation.parse(e.data)
        local player = GetPlayerEntity()
        if player ~= nil and anim.player == player.ServerId and inProgSynth ~= nil then
            inProgSynth.result = anim.param
        end
    -- sometimes the result response will come immediately (a cancel), and
    -- sometimes you have to wait 15 seconds. regardless, one SHOULD come.
    elseif e.id == 0x06F then
        local synth = packets.inbound.synthResultPlayer.parse(e.data)
        -- if the server cancels our synth, nil out the in-progress object
        if synth.result == 3 or synth.result == 4 or synth.result == 6 or synth.result == 7 then
            inProgSynth = nil
        -- otherwise, update with the real results and push it to the GUI
        elseif inProgSynth ~= nil and inProgSynth.startTime then
            -- we don't want to replace the synth name with Mangled Mess if
            -- a good item ID was found during the request
            if synth.item ~= 29695 or inProgSynth.item == 0 then
                inProgSynth.item = synth.item
                inProgSynth.count = synth.count
            end

            inProgSynth.lost = T{}
            for _, itemId in pairs(synth.lost) do
                if itemId > 0 then
                    inProgSynth.lost:append(itemId)
                    economy.see(itemId)
                end
            end
            economy.see(inProgSynth.item)

            for _, skill in pairs(synth.skill) do
                if skill.skillId > 0 then
                    inProgSynth.skillup[skill.skillId - 48] = {
                        isSkillupAllowed = skill.isSkillupAllowed,
                        change = nil,
                    }
                end
            end

            table.insert(options.history, 1, inProgSynth)
            inProgSynth = nil
        end
    -- skillups come after the results, but won't always appear. so we
    -- don't wait for them, just update the most recent completed synth
    -- with whatever skillup we get
    elseif e.id == 0x029 then
        local basic = packets.inbound.basic.parse(e.data)
        if basic.param < 48 or basic.param > 57 then return end

        local player = GetPlayerEntity()
        if basic.message == 38 and player ~= nil and basic.target == player.ServerId and basic.param > 48 and basic.param < 58 then
            local latestSynth = options.history:first()
            latestSynth.skillup[basic.param - 48].change = basic.value / 10
            options.skills[basic.param - 48][1] = options.skills[basic.param - 48][1] + (basic.value / 10)
        elseif basic.message == 310 and player ~= nil and basic.target == player.ServerId and basic.param > 48 and basic.param < 58 then
            local latestSynth = options.history:first()
            latestSynth.skillup[basic.param - 48].change = -basic.value / 10
            options.skills[basic.param - 48][1] = options.skills[basic.param - 48][1] - (basic.value / 10)
        end
    end
end

-- price editor state (config window)
local priceRefs = {}        -- [itemId] = { gil }  stable InputInt refs, seeded once
local priceBulk = { '' }    -- InputTextMultiline buffer
local priceBulkDirty = true -- re-sync the buffer from the master price list next frame
local lastBulkText = nil    -- last text we pushed into priceBulk; guards spurious writes
local priceFile = { 'prices.txt' }

-- drop cached InputInt refs so the grid re-reads from the price list next frame
InvalidatePriceRefs = function()
    for k in pairs(priceRefs) do priceRefs[k] = nil end
    priceBulkDirty = true
end

--------------------------------------------------------------------------------
-- learn prices from the chat log (AH / bazaar purchases and sales)
--------------------------------------------------------------------------------

-- { pattern -> (item phrase, total gil),  is-a-sale }
local purchasePatterns = {
    { '^you bought%s+(.-)%s+for%s+([%d,]+)%s+gil', false },
    { '^you buy%s+(.-)%s+from%s+.-%s+for%s+([%d,]+)%s+gil', false },
    { '^you buy%s+(.-)%s+for%s+([%d,]+)%s+gil', false },
    { '^you sold%s+(.-)%s+for%s+([%d,]+)%s+gil', true },
    { '^you sell%s+(.-)%s+for%s+([%d,]+)%s+gil', true },
    { '^you sell%s+(.-)%s+to%s+.-%s+for%s+([%d,]+)%s+gil', true },
}

CraftyPrint = function(text)
    print(chat.header('crafty'):append(chat.message(text)))
end

-- remembers phrases we already complained about, so a repeated non-craft
-- purchase (arrows, food, ...) is not chat spam
local learnWarned = {}

-- FFXI colour codes are a marker byte (0x1E or 0x1F) followed by a parameter
-- byte; both must go, or the parameter is left as a stray letter ("yYou buy...").
local function StripCodes(s)
    s = tostring(s)
    if type(string.strip_colors) == 'function' then
        local ok, stripped = pcall(string.strip_colors, s)
        if ok and stripped ~= nil then s = stripped end
    end
    s = s:gsub('[\30\31].', '')   -- marker + its parameter byte
    s = s:gsub('%c', ' ')         -- any other control byte (tab, CR, 0x07, ...)
    return s
end

-- verbose: report every step (used by /crafty pricetest) even when learning is off
HandleText = function(e, verbose)
    if not verbose and not options.learnPrices[1] then return end

    local msg = StripCodes(e.message or e.text or '')
        :gsub('%s+', ' ')
        :gsub('^%s+', ''):gsub('%s+$', '')
        :lower()
    if msg == '' then
        if verbose then CraftyPrint('empty line') end
        return
    end

    for _, entry in ipairs(purchasePatterns) do
        local phrase, gilStr = msg:match(entry[1])
        if phrase ~= nil and gilStr ~= nil then
            -- strip a leading article, then pull an optional stack count
            local clean = phrase:gsub('^the%s+', ''):gsub('^an?%s+', '')
            local qtyStr, rest = clean:match('^(%d+)%s+(.+)$')
            local qty = tonumber(qtyStr) or 1
            local itemPhrase = rest or clean
            local total = tonumber((gilStr:gsub(',', '')))
            local id = economy.resolve_item(itemPhrase)

            if verbose then
                CraftyPrint(('match: item="%s"  qty=%d  total=%s  id=%s'):format(
                    itemPhrase, qty, tostring(total), tostring(id)))
            end

            if id ~= nil and total ~= nil and total > 0 then
                local per = math.max(1, math.floor((total / math.max(1, qty)) + 0.5))
                economy.set_price(id, per)
                InvalidatePriceRefs()
                local name = economy.item_name(id) or ('#' .. id)
                local how = entry[2] and 'sold' or 'bought'
                local detail = qty > 1 and (' (%s / %i)'):format(economy.gil(total), qty) or ''
                CraftyPrint(('%s %s = %s%s'):format(how, name, economy.gil(per), detail))
            elseif id == nil and (verbose or not learnWarned[itemPhrase]) then
                learnWarned[itemPhrase] = true
                CraftyPrint(('no item match for "%s" - craft with it once, or add it by hand'):format(itemPhrase))
            end
            return
        end
    end

    -- NPC shop lines carry no gil amount ("You buy 3 bone arrows from the shop.",
    -- "You sell a dragon mask to the shop."). Remember the item + direction and
    -- let TickGil read the price from the gil change that follows.
    local npcSell = msg:match('^you sell%s+(.-)%s+to the shop')
    local npcBuy = msg:match('^you buy%s+(.-)%s+from the shop')
    if npcSell or npcBuy then
        if verbose then
            CraftyPrint(('npc %s line seen: "%s" (price comes from the gil change in-game)'):format(
                npcSell and 'sell' or 'buy', npcSell or npcBuy))
        elseif gilNow ~= nil then
            pendingNpc = {
                phrase = npcSell or npcBuy,
                sold = npcSell ~= nil,
                base = gilPrev or gilNow,  -- gil from before this frame's transaction
                t = os.clock(),
            }
        end
        return
    end

    -- smelled like a trade line but no pattern caught it: surface the wording once
    if verbose then
        CraftyPrint('no price pattern matched: ' .. msg)
    elseif (msg:match('^you bought ') or msg:match('^you buy ')
            or msg:match('^you sold ') or msg:match('^you sell '))
        and msg:match('[%d,]+ gil') and not learnWarned[msg] then
        learnWarned[msg] = true
        CraftyPrint('unrecognised price line (please report this wording): ' .. msg)
    end
end

local function ResolvePricePath()
    local path = priceFile[1]
    if path == nil or path == '' then path = 'prices.txt' end
    if not path:match('[/\\]') then
        path = economy.dir() .. '/' .. path
    end
    return path
end

local function DrawPrices(options)
    Header('Prices - per item')
    TextDim('Everything a synth has touched. Fill in what you buy/sell it for.')
    BeginPanel('crafty.cfg.pricegrid', 190)
    imgui.PushItemWidth(90)
    local ids = economy.seen_ids()
    if #ids == 0 then
        TextDim('Craft something (or set prices in the list below) to populate this.')
    end
    for _, id in ipairs(ids) do
        local ref = priceRefs[id]
        if ref == nil then
            ref = { (economy.price_of(id)) }
            priceRefs[id] = ref
        end
        local name = economy.item_name(id) or ('#' .. id)
        if imgui.InputInt(name .. '##crafty.price' .. id, ref) then
            if ref[1] < 0 then ref[1] = 0 end
            economy.set_price(id, ref[1])
            priceBulkDirty = true
        end
    end
    imgui.PopItemWidth()
    EndPanel()

    imgui.Spacing()
    Header('Prices - full list')
    TextDim('One "item name:gil" per line. Shared with the grid above.')
    BeginPanel('crafty.cfg.pricelist', 150)
    if priceBulkDirty then
        priceBulk[1] = table.concat(economy.get_lines(), '\n')
        lastBulkText = priceBulk[1]
        priceBulkDirty = false
    end
    imgui.InputTextMultiline('##crafty.pricebulk', priceBulk, 16384, { -1, 122 })
    -- only rewrite the price list when the text actually differs from what we
    -- loaded in - never on a spurious "changed" with identical content
    if priceBulk[1] ~= lastBulkText then
        economy.set_lines(economy.split(priceBulk[1], '\n'))
        lastBulkText = priceBulk[1]
        for k in pairs(priceRefs) do priceRefs[k] = nil end
    end
    EndPanel()

    imgui.Spacing()
    Header('Prices - learn from chat')
    BeginPanel('crafty.cfg.pricelearn', 84)
    if imgui.Checkbox('Learn from AH / bazaar / NPC-shop buy & sell lines', options.learnPrices) then MarkDirty() end
    TextDim('AH/bazaar: reads the gil from the line. NPC shop: reads it from')
    TextDim('the gil change (the line has no amount).')
    EndPanel()

    imgui.Spacing()
    Header('Prices - import / export')
    BeginPanel('crafty.cfg.pricefile', 100)
    imgui.PushItemWidth(190)
    imgui.InputText('##crafty.pricefile', priceFile, 256)
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.Button('Import') then
        local path = ResolvePricePath()
        local f = io.open(path, 'r')
        if f == nil then
            print(chat.header('crafty'):append(chat.message('could not open ' .. path)))
        else
            local lines = {}
            for line in f:lines() do lines[#lines + 1] = line end
            f:close()
            local u, a, s = economy.merge_lines(lines)
            InvalidatePriceRefs()
            print(chat.header('crafty'):append(chat.message(
                ('prices: %i updated, %i added, %i skipped'):format(u, a, s))))
        end
    end
    imgui.SameLine()
    if imgui.Button('Export') then
        local path = ResolvePricePath()
        local f = io.open(path, 'w')
        if f == nil then
            print(chat.header('crafty'):append(chat.message('could not write ' .. path)))
        else
            f:write(table.concat(economy.get_lines(), '\n'))
            f:close()
            print(chat.header('crafty'):append(chat.message('prices written to ' .. path)))
        end
    end
    TextDim('Master list lives at ' .. economy.dir() .. '/prices.txt, shared by every character.')
    TextDim('This import/export targets whatever filename is set above.')
    EndPanel()
end

local overrideFile = { 'overrides.txt' }

local function ResolveOverridePath()
    local p = overrideFile[1]
    if p == nil or p == '' then p = 'overrides.txt' end
    if not p:match('[/\\]') then p = economy.dir() .. '/' .. p end
    return p
end

local function ExportOverrides(path)
    local f = io.open(path, 'w')
    if f == nil then return false end
    for key, ov in pairs(options.recipeOverrides or {}) do
        local src = ov.src or OverrideSrc(key)
        local srcName = economy.item_name(src) or ('#' .. tostring(src))
        local resName = (ov.result and ov.result ~= 0)
            and (economy.item_name(ov.result) or ('#' .. ov.result)) or 'same'
        f:write(('%s = %d:%d  ; %s -> %s x%d\n'):format(
            key, ov.result or 0, ov.count or 0, srcName, resName, ov.count or 0))
    end
    f:close()
    return true
end

local function ImportOverrides(path)
    local f = io.open(path, 'r')
    if f == nil then return nil end
    if options.recipeOverrides == nil then options.recipeOverrides = T{} end
    local added, updated, skipped = 0, 0, 0
    for line in f:lines() do
        local body = line:gsub('[;#].*$', '')
        local key, resStr, cntStr = body:match('^%s*(.-)%s*=%s*(%d+)%s*:%s*(%d+)%s*$')
        if key ~= nil and key:match('^%d+|') then
            local existed = options.recipeOverrides[key] ~= nil
            options.recipeOverrides[key] = T{
                src = OverrideSrc(key),
                result = tonumber(resStr) or 0,
                count = tonumber(cntStr) or 0,
            }
            if existed then updated = updated + 1 else added = added + 1 end
        elseif body:match('%S') then
            skipped = skipped + 1
        end
    end
    f:close()
    return added, updated, skipped
end

local function DrawOverrides(options)
    Header('Recipe output overrides')
    TextDim('Fixes for synths Horizon changed. Edit these in the Recipe List;')
    TextDim('this is just the list of what you have changed.')
    BeginPanel('crafty.cfg.overrides', 214)
    local any = false
    if options.recipeOverrides ~= nil then
        for key, ov in pairs(options.recipeOverrides) do
            any = true
            local base = economy.item_name(ov.src) or economy.item_name(OverrideSrc(key)) or key
            local cnt = (ov.count and ov.count > 0) and tostring(ov.count) or '?'
            local label
            if ov.result ~= nil and ov.result ~= 0 then
                label = ('%s -> %s x%s'):format(base, economy.item_name(ov.result) or ('#' .. ov.result), cnt)
            else
                label = ('%s x%s'):format(base, cnt)
            end
            imgui.TextColored(theme.colors.text_light, label)
            imgui.SameLine()
            if imgui.SmallButton('reset##ovcfg' .. key) then
                options.recipeOverrides[key] = nil
                settings.save()
            end
        end
    end
    if not any then
        TextDim('None yet.')
    end

    imgui.Separator()
    imgui.PushItemWidth(180)
    imgui.InputText('##crafty.ovfile', overrideFile, 256)
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.SmallButton('Import##ov') then
        local a, u, s = ImportOverrides(ResolveOverridePath())
        if a == nil then
            CraftyPrint('could not open ' .. ResolveOverridePath())
        else
            settings.save()
            CraftyPrint(('overrides: %d added, %d updated, %d skipped'):format(a, u, s))
        end
    end
    imgui.SameLine()
    if imgui.SmallButton('Export##ov') then
        if ExportOverrides(ResolveOverridePath()) then
            CraftyPrint('overrides written to ' .. ResolveOverridePath())
        else
            CraftyPrint('could not write ' .. ResolveOverridePath())
        end
    end
    TextDim('Bare filename resolves under ' .. economy.dir())
    EndPanel()
end

local function DrawConfig()
    if not options.configVisible[1] then
        return
    end

    imgui.SetNextWindowSize(configWindow.size, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowPos(configWindow.pos, ImGuiCond_FirstUseEver)

    local styleCounts = theme.apply_style()
    local panelCounts = ApplyPanelOverrides()

    if imgui.Begin(configWindow.name, options.configVisible, configWindow.flags) then
        local fontPushed = fonts.push(options.ui.fontFamily[1])
        local scaleTag = fonts.begin_scale(options.ui.scale[1])

        Header('Appearance')
        BeginPanel('crafty.cfg.appearance', 132)
        if imgui.Checkbox('Show window', options.isVisible) then MarkDirty() end
        imgui.Spacing()
        TextDim('Window theme')
        local current = ThemeName()
        for _, entry in ipairs(theme.THEME_OPTIONS) do
            if imgui.RadioButton(entry.label, current == entry.id) then
                if options.background_theme == nil then
                    options.background_theme = T{ entry.id }
                else
                    options.background_theme[1] = entry.id
                end
                MarkDirty()
            end
        end
        EndPanel()

        imgui.Spacing()
        Header('Font')
        BeginPanel('crafty.cfg.font', 74)
        if fonts.render_combo(options.ui.fontFamily) then MarkDirty() end
        local scaleChanged = imgui.SliderFloat('Text Size', options.ui.scale, 0.75, 2.00, '%.2fx')
        if options.ui.scale[1] < 0.75 then options.ui.scale[1] = 0.75 end
        if options.ui.scale[1] > 2.00 then options.ui.scale[1] = 2.00 end
        if scaleChanged then MarkDirty() end
        EndPanel()

        imgui.Spacing()
        Header('Panel style')
        BeginPanel('crafty.cfg.panelstyle', 130)
        local opacityChanged = imgui.SliderFloat('Background Opacity', options.ui.panelOpacity, 0.10, 1.00, '%.2f')
        if opacityChanged then MarkDirty() end
        local roundingChanged = imgui.SliderInt('Corner Rounding', options.ui.panelRounding, 0, 16)
        if roundingChanged then MarkDirty() end
        local borderChanged = imgui.SliderInt('Border Thickness', options.ui.borderThickness, 0, 4)
        if borderChanged then MarkDirty() end
        if imgui.SmallButton('reset to defaults##panelstyle') then
            options.ui.scale[1] = 1.0
            options.ui.panelOpacity[1] = 0.95
            options.ui.panelRounding[1] = 6
            options.ui.borderThickness[1] = 1
            options.ui.fontFamily[1] = 'Agave (Default)'
            MarkDirty()
        end
        EndPanel()

        imgui.Spacing()
        Header('Hide window while...')
        BeginPanel('crafty.cfg.hide', 128)
        if imgui.Checkbox('the map is open', options.hideUnderMap) then MarkDirty() end
        if imgui.Checkbox('chat is expanded', options.hideUnderChat) then MarkDirty() end
        if imgui.Checkbox('zoning / loading', options.hideWhileLoading) then MarkDirty() end
        if imgui.Checkbox('an event is happening', options.hideDuringEvent) then MarkDirty() end
        if imgui.Checkbox('the game interface is hidden', options.hideWithInterface) then MarkDirty() end
        EndPanel()

        imgui.Spacing()
        Header('Crafting skills')
        BeginPanel('crafty.cfg.skills', 244)
        TextDim('Seed these to your in-game levels; skill-ups keep them current.')
        imgui.Spacing()
        for id = 1, 8 do
            local ch = imgui.InputFloat(skillsMap[id], options.skills[id], 0.1, 1.0, '%.1f')
            EditedFloat(ch, options.skills[id], 0, 200)
        end
        EndPanel()

        imgui.Spacing()
        DrawPrices(options)

        imgui.Spacing()
        DrawOverrides(options)

        imgui.Spacing()
        Header('History')
        BeginPanel('crafty.cfg.history', 56)
        if imgui.Button('Clear craft history') then
            options.history = T{}
            MarkDirty()
        end
        EndPanel()

        imgui.Spacing()
        imgui.Separator()
        TextDim(('crafty %s  -  crafting logic and recipe data from xitools by lin'):format(addon.version))

        fonts.end_scale(scaleTag)
        fonts.pop(fontPushed)
    end
    imgui.End()

    theme.pop_style(panelCounts)
    theme.pop_style(styleCounts)
end

local function DrawMain()
    if not options.isVisible[1] then
        return
    end

    imgui.SetNextWindowSize(options.size, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowPos(options.pos, ImGuiCond_FirstUseEver)

    local styleCounts = theme.apply_style()
    local panelCounts = ApplyPanelOverrides()

    if imgui.Begin(options.name, options.isVisible, options.flags) then
        local fontPushed = fonts.push(options.ui.fontFamily[1])
        local scaleTag = fonts.begin_scale(options.ui.scale[1])

        Header('Crafting Skills')
        imgui.SameLine()
        if imgui.SmallButton(skillsEdit[1] and 'done##crafty.skilltoggle' or 'edit##crafty.skilltoggle') then
            skillsEdit[1] = not skillsEdit[1]
        end
        if skillsEdit[1] then
            DrawSkillsEdit(options.skills)
        else
            DrawSkills(options.skills)
        end
        imgui.Spacing()
        DrawGil()
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        DrawFavorites(options.skills)
        DrawRecipes(options.skills)
        DrawHistory(options)

        local x, y = imgui.GetWindowPos()
        options.pos[1] = x
        options.pos[2] = y

        fonts.end_scale(scaleTag)
        fonts.pop(fontPushed)
    end
    imgui.End()

    theme.pop_style(panelCounts)
    theme.pop_style(styleCounts)
end

--------------------------------------------------------------------------------

settings.register('settings', 'settings_update', function(s)
    if s ~= nil then
        options = s
    end
    if options.learnPrices == nil then
        options.learnPrices = T{ true }
    end
    if options.recipeOverrides == nil then
        options.recipeOverrides = T{}
    end
    if options.favorites == nil then
        options.favorites = T{}
    end
    if options.ui == nil then
        options.ui = defaultSettings.ui:copy(true)
    end
    economy.seed_from_history(options.history)
    settings.save()

    -- this character may still have an old per-character price list from
    -- before prices became a shared master list - fold it in once
    if options.prices ~= nil and #options.prices > 0 then
        local updated, added = economy.merge_lines(options.prices)
        local n = updated + added
        CraftyPrint(('migrated %d price%s from this character into the shared price list'):format(
            n, n == 1 and '' or 's'))
        options.prices = T{}
        MarkDirty()
    end

    -- gil session tracking resets itself in TickGil (on a character change or a
    -- long gone-stretch), so nothing to do here
end)

ashita.events.register('load', 'load_handler', function()
    -- loads bundled-name font faces once, up front - never mid-frame, per
    -- libs/fonts.lua (mutating the ImGui font atlas mid-frame can crash Ashita)
    fonts.prewarm()
end)

ashita.events.register('unload', 'unload_handler', function()
    settings.save()
end)

-- poll gil once per frame; resolve any pending NPC transaction once gil settles
local function TickGil()
    local g = GilOnHand()
    local e = GetPlayerEntity()
    local name = e and e.Name or nil
    if g == nil or name == nil or name == '' then
        return -- not loaded in; gilLastSeen freezes so the gap keeps growing
    end

    local now = os.time()
    local gap = now - gilLastSeen
    gilLastSeen = now

    -- start a fresh session on: a different character, OR coming back after a
    -- long gone-stretch (logout / char select), which a quick zone won't hit
    if name ~= sessionChar or gap > 10 then
        sessionChar = name
        sessionCharSince = now
        sessionGil0 = nil
        pendingNpc = nil
        gilNow, gilPrev = g, g
        return
    end

    gilPrev = gilNow
    gilNow = g

    -- take the start-of-session baseline once the character has settled in.
    -- During a zone-in / login the gil slot can read a stale 0 for several
    -- seconds, so require: at least 2s loaded, gil unchanged frame-to-frame,
    -- and gil > 0 (a real broke-player 0 still baselines after a 20s grace).
    if sessionGil0 == nil then
        local elapsed = os.time() - sessionCharSince
        local stable = (gilNow == gilPrev)
        if elapsed >= 2 and stable and (gilNow > 0 or elapsed >= 20) then
            sessionGil0 = gilNow
        end
        return
    end

    -- heal a 0 baseline captured by an older build during a bad load - would
    -- show "session +<all your gil>" forever otherwise
    if sessionGil0 == 0 and gilNow > 10000 then
        sessionGil0 = nil
        sessionCharSince = os.time()
        return
    end

    if pendingNpc ~= nil then
        if type(pendingNpc.base) ~= 'number' or (os.clock() - pendingNpc.t) > 3 then
            pendingNpc = nil
        elseif gilNow ~= pendingNpc.base and gilNow == gilPrev then
            local dg = gilNow - pendingNpc.base
            local id = economy.resolve_item(pendingNpc.phrase)
            local qty = tonumber(tostring(pendingNpc.phrase):match('^(%d+)')) or 1
            if id ~= nil and dg ~= 0 then
                local per = math.max(1, math.floor(math.abs(dg) / math.max(1, qty) + 0.5))
                economy.set_price(id, per)
                InvalidatePriceRefs()
                CraftyPrint(('%s %s = %s (npc, %s total)'):format(
                    pendingNpc.sold and 'sold' or 'bought',
                    economy.item_name(id) or ('#' .. id),
                    economy.gil(per), economy.gil(math.abs(dg))))
            end
            pendingNpc = nil
        end
    end
end

ashita.events.register('d3d_present', 'd3d_present_handler', function()
    FlushDirty(false)
    TickGil()
    theme.set_active(ThemeName())

    DrawConfig()

    if (options.hideUnderChat[1] and ffxi.IsChatExpanded())
    or (options.hideUnderMap[1] and ffxi.IsMapOpen())
    or (options.hideWhileLoading[1] and GetPlayerEntity() == nil)
    or (options.hideDuringEvent[1] and ffxi.IsEventHappening())
    or (options.hideWithInterface[1] and ffxi.IsInterfaceHidden()) then
        return
    end

    DrawMain()
end)

ashita.events.register('packet_out', 'packet_out_handler', function(e)
    HandlePacketOut(e)
end)

ashita.events.register('packet_in', 'packet_in_handler', function(e)
    HandlePacket(e)
end)

local function PriceLogLine(e)
    if not priceLog[1] then return end
    local f = io.open(economy.dir() .. '/textlog.txt', 'a')
    if f == nil then return end
    local raw = tostring(e.message or e.text or '')
    local shown = raw:gsub('%c', function(c) return ('<%02X>'):format(c:byte()) end)
    f:write(('[%s] mode=%s injected=%s | %s\n'):format(
        os.date('%H:%M:%S'), tostring(e.mode), tostring(e.injected), shown))
    f:close()
end

ashita.events.register('text_in', 'text_in_handler', function(e)
    pcall(PriceLogLine, e)
    -- never re-process our own chat output (guards against print() recursion)
    if e.injected == true then return end
    local ok, err = pcall(HandleText, e)
    if not ok then
        print(chat.header('crafty'):append(chat.message('text handler error: ' .. tostring(err))))
    end
end)

ashita.events.register('command', 'command_handler', function(e)
    local args = e.command:args()
    local cmd = args[1]

    if cmd == nil or (cmd ~= '/crafty' and cmd ~= '/craft') then
        return
    end

    e.blocked = true

    HandleCommand(args:slice(2, #args - 1))
end)
