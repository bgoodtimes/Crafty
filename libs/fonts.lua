--[[
* synthex - font family + text-size scaling for the addon's windows
*
* Approach lifted from floos' libs/fonts.lua (GPLv3): load bundled-name faces
* via imgui.AddFontFromFileTTF and scale per-window with SetWindowFontScale,
* falling back to PushFontSize / PushFont(font, size) on newer ImGui bindings
* that dropped it.
*
* No font files are shipped with synthex. Every face here (besides the no-file
* "Agave" default) is a standard Windows font - it's loaded straight from
* %WINDIR%\Fonts, which every Windows install already has. Dropping a
* same-named .ttf in synthex/assets/fonts/ overrides the system copy.
]]--

require('common')
local imgui = require('imgui')

local M = {}

M.OPTIONS = T{
    { label = 'Agave (Default)', file = nil },            -- Ashita's built-in font, no file needed
    { label = 'Tahoma Bold',     file = 'tahomabd.ttf' },
    { label = 'Tahoma',          file = 'tahoma.ttf' },
    { label = 'Segoe UI',        file = 'segoeui.ttf' },
    { label = 'Consolas',        file = 'consola.ttf' },
    { label = 'Verdana',         file = 'verdana.ttf' },
}

M.BASE_SIZE = 18 -- pixel size passed to AddFontFromFileTTF; the scale slider adjusts from here

local cache = {}
local warned = {}
local prewarmed = false

local function addon_fonts_dir()
    local base = (addon and addon.path) or '.'
    base = tostring(base):gsub('[/\\]+$', '')
    return base .. '/assets/fonts/'
end

local function windows_fonts_dir()
    local win = os.getenv('WINDIR') or os.getenv('SystemRoot') or 'C:/Windows'
    return tostring(win):gsub('[/\\]+$', '') .. '/Fonts/'
end

local function find_option(label)
    for _, opt in ipairs(M.OPTIONS) do
        if opt.label == label then return opt end
    end
    return M.OPTIONS[1]
end

local function try_add_font(path)
    local ok, font = pcall(function() return imgui.AddFontFromFileTTF(path, M.BASE_SIZE) end)
    if ok and font ~= nil and font ~= false then return font end
    return nil
end

function M.resolve_label(label)
    return find_option(label).label
end

-- Returns the ImFont*, or nil for "Agave" / a face that failed to load (caller
-- just skips PushFont and stays on the default font in that case).
function M.get_font(label)
    label = M.resolve_label(label)
    local opt = find_option(label)
    if opt.file == nil then return nil end

    if cache[label] ~= nil then
        return (cache[label] ~= false) and cache[label] or nil
    end

    -- a same-named file dropped in synthex/assets/fonts/ wins over the system copy
    local font = try_add_font(addon_fonts_dir() .. opt.file) or try_add_font(windows_fonts_dir() .. opt.file)

    if font == nil then
        cache[label] = false
        if not warned[label] then
            warned[label] = true
            print(('[synthex] could not load font "%s" (looked in %s and %s) - using default'):format(
                label, addon_fonts_dir(), windows_fonts_dir()))
        end
        return nil
    end

    cache[label] = font
    return font
end

--- Load every bundled-name face once. Call at addon load, never from
--- d3d_present - mutating the ImGui font atlas mid-frame can crash Ashita.
function M.prewarm()
    if prewarmed then return end
    prewarmed = true
    for _, opt in ipairs(M.OPTIONS) do
        if opt.file ~= nil then M.get_font(opt.label) end
    end
end

--- Push the chosen face. Returns true if something was pushed - pair with
--- M.pop(that value). No-op (returns false) for "Agave" or a failed load.
function M.push(label)
    local font = M.get_font(label)
    if font == nil then return false end
    local ok = pcall(function() imgui.PushFont(font) end)
    return ok
end

function M.pop(pushed)
    if not pushed then return end
    pcall(function() imgui.PopFont() end)
end

--- Scale the current window's text by `scale` (1.0 = 100%). Call right after
--- imgui.Begin succeeds; always pair with M.end_scale on the returned tag.
function M.begin_scale(scale)
    scale = tonumber(scale) or 1.0
    if scale <= 0 then scale = 1.0 end

    if imgui.SetWindowFontScale ~= nil then
        local ok = pcall(function() imgui.SetWindowFontScale(scale) end)
        if ok then return { mode = 'legacy' } end
    end

    local base = imgui.GetFontSize()
    if base == nil or base <= 0 then base = M.BASE_SIZE end
    local size = base * scale

    if imgui.PushFontSize ~= nil then
        local ok = pcall(function() imgui.PushFontSize(size) end)
        if ok then return { mode = 'font_size' } end
    end

    local font = nil
    pcall(function() font = imgui.GetFont() end)
    local ok = pcall(function() imgui.PushFont(font, size) end)
    if ok then return { mode = 'push_font' } end

    return { mode = 'none' }
end

function M.end_scale(tag)
    if tag == nil then return end

    if tag.mode == 'legacy' then
        if imgui.SetWindowFontScale ~= nil then
            pcall(function() imgui.SetWindowFontScale(1.0) end)
        end
        return
    end

    if tag.mode == 'font_size' then
        pcall(function()
            if imgui.PopFontSize ~= nil then imgui.PopFontSize() else imgui.PopFont() end
        end)
        return
    end

    if tag.mode == 'push_font' then
        pcall(function() imgui.PopFont() end)
    end
end

function M.render_combo(labelRef)
    local current = M.resolve_label(labelRef[1])
    local changed = false
    if imgui.BeginCombo('Font', current) then
        for _, opt in ipairs(M.OPTIONS) do
            local selected = (opt.label == current)
            if imgui.Selectable(opt.label, selected) then
                labelRef[1] = opt.label
                changed = true
            end
            if selected then imgui.SetItemDefaultFocus() end
        end
        imgui.EndCombo()
    end
    return changed
end

return M
