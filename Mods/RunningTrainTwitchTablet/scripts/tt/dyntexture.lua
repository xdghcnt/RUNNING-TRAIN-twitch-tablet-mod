--[[
    Milestone 6 -- a runtime texture that is redrawn in place.

    Why a render target + Canvas and not "CPU bitmap -> UTexture2D" (RESEARCH.md):
    writing pixels into a UTexture2D needs native engine functions
    (UpdateTextureRegions / mip locking) that neither Lua reflection nor our C++
    (no UEPseudo headers) can reach. A render target is created ONCE; every update
    draws into the same GPU resource through the engine's reflected Canvas API:

        KismetRenderingLibrary:ClearRenderTarget2D
        KismetRenderingLibrary:BeginDrawCanvasToRenderTarget  -> Canvas, Size, Context (out)
        Canvas:K2_DrawText / K2_DrawTexture
        KismetRenderingLibrary:EndDrawCanvasToRenderTarget(Context)

    No UObject is created per update. Out parameters come back through Lua tables
    (UE4SS LuaUObject.cpp: object out params land in table[ParamName], struct out
    params are copied into the table itself).

    Game thread only.
]]

local U = require("tt.util")
local log, try, isValid, fullName = U.log, U.try, U.isValid, U.fullName

local M = {}

-- ETextureRenderTargetFormat: RTF_R8, RTF_RG8, RTF_RGBA8, RTF_RGBA8_SRGB, ...
local RTF_RGBA8_SRGB = 3

local FONT_PATHS = {
    "/Engine/EngineFonts/Roboto.Roboto",
    "/Engine/EngineFonts/RobotoDistanceField.RobotoDistanceField",
}
local WHITE_TEXTURE = "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"

local function asset(path)
    local o = try(function() return StaticFindObject(path) end)
    if isValid(o) then return o end
    local ok, loaded = pcall(LoadAsset, path)
    if ok and isValid(loaded) then return loaded end
    return nil
end

local function lib()
    return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
end

--- Returns a surface table { rt, width, height, world, font, white } or nil.
function M.create(world, width, height)
    local l = lib()
    if not isValid(l) then log("dyntexture: KismetRenderingLibrary CDO missing"); return nil end

    local rt = try(function()
        return l:CreateRenderTarget2D(world, width, height, RTF_RGBA8_SRGB, { R = 0, G = 0, B = 0, A = 1 }, false, false)
    end)
    if not isValid(rt) then log("dyntexture: CreateRenderTarget2D failed"); return nil end

    local font
    for _, path in ipairs(FONT_PATHS) do
        font = asset(path)
        if font then break end
    end

    local surface = { rt = rt, width = width, height = height, world = world, font = font, white = asset(WHITE_TEXTURE) }
    log("dyntexture: Texture created: %dx%d %s (size %sx%s), font %s", width, height, fullName(rt),
        tostring(try(function() return rt.SizeX end)), tostring(try(function() return rt.SizeY end)), fullName(font))
    return surface
end

--------------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------------

-- M16: every colour drawn is multiplied by this (0..1): dims the whole screen.
M.brightness = 1.0

local function dim(c)
    local b = M.brightness
    if b >= 1 then return c end
    return { R = c.R * b, G = c.G * b, B = c.B * b, A = c.A }
end

local Draw = {}
Draw.__index = Draw

function Draw:rect(x, y, w, h, color)
    color = dim(color)
    if not self.surface.white then return end
    self.canvas:K2_DrawTexture(self.surface.white, { X = x, Y = y }, { X = w, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
                               color, 2, 0, { X = 0.5, Y = 0.5 })   -- EBlendMode 2 = Translucent
end

--- A texture (or a part of one: u, v, uw, vh in 0..1) stretched to x, y, w, h.
--- blend: EBlendMode, 0 = Opaque, 2 = Translucent.
function Draw:image(tex, x, y, w, h, u, v, uw, vh, color, blend)
    self.canvas:K2_DrawTexture(tex, { X = x, Y = y }, { X = w, Y = h }, { X = u, Y = v }, { X = uw, Y = vh },
                               dim(color), blend or 2, 0, { X = 0.5, Y = 0.5 })
end

function Draw:text(x, y, str, scale, color)
    color = dim(color)
    if not self.surface.font then return end
    self.canvas:K2_DrawText(self.surface.font, str, { X = x, Y = y }, { X = scale, Y = scale }, color, 0,
                            { R = 0, G = 0, B = 0, A = 0 }, { X = 1, Y = 1 }, false, false, false, { R = 0, G = 0, B = 0, A = 1 })
end

local textSizeChecked = false

--- Rendered size of `str` at `scale`, in render-target pixels: { X, Y }.
--- Uses Canvas:K2_TextSize; if that ever fails, falls back to a rough estimate
--- (0.55 em per character) so layout degrades instead of breaking.
function Draw:textSize(str, scale)
    if not textSizeChecked then
        textSizeChecked = true
        local fn = try(function() return StaticFindObject("/Script/Engine.Canvas:K2_TextSize") end)
        local parts = {}
        if isValid(fn) then
            try(function()
                fn:ForEachProperty(function(p)
                    table.insert(parts, (try(function() return p:GetClass():GetFName():ToString() end) or "?") .. " "
                        .. (try(function() return p:GetFName():ToString() end) or "?"))
                end)
            end)
        end
        log("dyntexture: Canvas:K2_TextSize(%s)", isValid(fn) and table.concat(parts, ", ") or "MISSING")
    end
    local v = self.surface.font and try(function()
        return self.canvas:K2_TextSize(self.surface.font, str, { X = scale, Y = scale })
    end)
    local x, y = v and try(function() return v.X end), v and try(function() return v.Y end)
    if type(x) == "number" and type(y) == "number" then return { X = x, Y = y } end
    local em = 24 * scale
    return { X = utf8.len(str) * em * 0.55, Y = em }
end

--- Draws into the target WITHOUT clearing it, at full brightness (for stored
--- content such as the emote atlas; brightness is applied when it is shown).
function M.paintInto(surface, painter)
    local keep = M.brightness
    M.brightness = 1
    local ok, err = pcall(function()
        local l = lib()
        local canvasOut, sizeOut, context = {}, {}, {}
        l:BeginDrawCanvasToRenderTarget(surface.world, surface.rt, canvasOut, sizeOut, context)
        local canvas = canvasOut.Canvas
        if not isValid(canvas) then
            pcall(function() l:EndDrawCanvasToRenderTarget(surface.world, context) end)
            error("BeginDrawCanvasToRenderTarget returned no Canvas")
        end
        local pok, perr = pcall(painter, setmetatable({ canvas = canvas, surface = surface, size = sizeOut }, Draw))
        l:EndDrawCanvasToRenderTarget(surface.world, context)
        if not pok then error(perr) end
    end)
    M.brightness = keep
    if not ok then error(err) end
    return true
end

--- Clears the target and runs painter(draw) between Begin/End. Returns true on success.
function M.redraw(surface, background, painter)
    local l = lib()
    l:ClearRenderTarget2D(surface.world, surface.rt, dim(background))

    local canvasOut, sizeOut, context = {}, {}, {}
    l:BeginDrawCanvasToRenderTarget(surface.world, surface.rt, canvasOut, sizeOut, context)
    local canvas = canvasOut.Canvas
    if not isValid(canvas) then
        -- Still end the draw so the world canvas is not left half-open.
        pcall(function() l:EndDrawCanvasToRenderTarget(surface.world, context) end)
        error("BeginDrawCanvasToRenderTarget returned no Canvas")
    end

    local ok, err = pcall(painter, setmetatable({ canvas = canvas, surface = surface, size = sizeOut }, Draw))
    l:EndDrawCanvasToRenderTarget(surface.world, context)
    if not ok then error(err) end
    return true
end

return M
