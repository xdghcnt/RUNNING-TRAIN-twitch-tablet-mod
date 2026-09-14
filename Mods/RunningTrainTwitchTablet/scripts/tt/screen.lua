--[[
    Milestone 5 -- the screen shows OUR texture.

    Material: the engine's WidgetComponent material (in memory per M0). It is an
    unlit pass-through: the texture is the emitted colour, which is what a screen
    wants. Its texture parameter is "SlateUI" -- not assumed: after setting it,
    the value is read back with K2_GetTextureParameterValue.

    Static test textures (cooked /Engine content, in memory per M0): a checker and
    the engine default texture. MiniFont was tried and dropped: it is 512x8, one
    glyph row, useless for judging orientation. Runtime content: tt/dyntexture.lua.
]]

local U = require("tt.util")
local log, try, isValid, fullName = U.log, U.try, U.isValid, U.fullName

local M = {}

M.MATERIALS = {
    "/Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque",
    "/Engine/EngineMaterials/Widget3DPassThrough.Widget3DPassThrough",
}
M.TEXTURE_PARAM = "SlateUI"
M.TEXTURES = {
    "/Engine/OpenWorldTemplate/LandscapeMaterial/T_GridChecker_A.T_GridChecker_A",
    "/Engine/EngineResources/DefaultTexture.DefaultTexture",
}

local function asset(path)
    local o = try(function() return StaticFindObject(path) end)
    if isValid(o) then return o end
    local ok, loaded = pcall(LoadAsset, path)
    if ok and isValid(loaded) then return loaded end
    return nil
end

--- Creates the screen's own dynamic material. Returns the MID or nil.
function M.createMaterial(screenComp)
    for _, path in ipairs(M.MATERIALS) do
        local base = asset(path)
        if base then
            local mid = try(function() return screenComp:CreateDynamicMaterialInstance(0, base, FName("TabletScreen")) end)
            if isValid(mid) then
                log("screen: material %s from %s", fullName(mid), path)
                return mid
            end
            log("screen: CreateDynamicMaterialInstance failed for %s", path)
        else
            log("screen: %s not available", path)
        end
    end
    return nil
end

--- Sets any texture object (Texture2D or render target) and verifies it by reading it back.
function M.setTexture(mid, tex, label)
    local ok, err = pcall(function() mid:SetTextureParameterValue(FName(M.TEXTURE_PARAM), tex) end)
    local back = try(function() return mid:K2_GetTextureParameterValue(FName(M.TEXTURE_PARAM)) end)
    local match = isValid(back) and fullName(back) == fullName(tex)
    log("screen: SetTextureParameterValue(%s, %s) ok=%s %s -> read back match=%s, size %sx%s",
        M.TEXTURE_PARAM, label or fullName(tex), tostring(ok), err or "", tostring(match),
        tostring(try(function() return tex:Blueprint_GetSizeX() end) or try(function() return tex.SizeX end)),
        tostring(try(function() return tex:Blueprint_GetSizeY() end) or try(function() return tex.SizeY end)))
    return match
end

--- Static test texture #index.
function M.showTexture(mid, index)
    local path = M.TEXTURES[index]
    local tex = asset(path)
    if not tex then
        log("screen: texture %s not available", path)
        return false
    end
    return M.setTexture(mid, tex, path)
end

return M
