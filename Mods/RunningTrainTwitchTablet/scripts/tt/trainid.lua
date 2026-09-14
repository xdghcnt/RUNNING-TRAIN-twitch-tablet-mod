--[[
    Milestone 12 -- train identification, research only.

    Nothing here picks a profile. It collects every candidate identifier the game
    exposes about the train the player is in and logs it once per car (actor
    instance), so several trains can be compared in UE4SS.log:

      * the car's class and its asset path (e.g. Cpy_KuHa115_C, M0-M2);
      * scalar Blueprint properties (names, strings, numbers, enums, bools) of the
        car, the game instance and the game mode -- a train/consist/vehicle ID
        would be one of these if the game has one;
      * the body mesh (BaseTrain's StaticMesh) as a geometry-level fallback.

    If the tablet had to fall back from the cab-interior anchor, the car's
    component tree is dumped too (Cab.dump), for supporting that train later.

    Game thread only; cheap enough to run once per spawn (no world sweeps).
]]

local U = require("tt.util")
local Cab = require("tt.cab")
local log, try, isValid, fullName = U.log, U.try, U.isValid, U.fullName

local M = {}

local SCALAR_TYPES = {
    NameProperty = true, StrProperty = true, TextProperty = true,
    IntProperty = true, Int64Property = true, Int16Property = true, UInt32Property = true,
    FloatProperty = true, DoubleProperty = true,
    BoolProperty = true, ByteProperty = true, EnumProperty = true,
    ClassProperty = true, SoftClassProperty = true, SoftObjectProperty = true,
}

-- Per-frame noise that says nothing about which train it is.
local SKIP = { "Timeline", "UberGraphFrame", "Delta Seconds", "Lerp", "Direction", "Prev_", "Accel", "Speed" }

local MAX_LINES_PER_OBJECT = 120

local S = { reportedCars = {}, dumpedClasses = {} }

local function valueToString(v)
    local t = type(v)
    if t == "number" then
        if math.type and math.type(v) == "float" then return string.format("%.4g", v) end
        return tostring(v)
    end
    if t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        local s = try(function() return v:ToString() end)
        if type(s) == "string" then return string.format("%q", s) end
        if isValid(v) then return fullName(v) end
    end
    return "<" .. t .. ">"
end

local function skipped(name)
    for _, w in ipairs(SKIP) do
        if name:find(w, 1, true) then return true end
    end
    return false
end

--- Scalar properties declared by Blueprint (/Game/) classes of obj.
local function scalars(obj, label)
    local cls = try(function() return obj:GetClass() end)
    local lines, depth = 0, 0
    while isValid(cls) and depth < 8 and lines < MAX_LINES_PER_OBJECT do
        local cname = fullName(cls)
        if not cname:find("/Game/", 1, true) then break end
        try(function()
            cls:ForEachProperty(function(p)
                if lines >= MAX_LINES_PER_OBJECT then return true end
                local ptype = try(function() return p:GetClass():GetFName():ToString() end) or "?"
                local pname = try(function() return p:GetFName():ToString() end) or "?"
                if SCALAR_TYPES[ptype] and not skipped(pname) then
                    log("  %s.%s (%s) = %s", label, pname, ptype, valueToString(try(function() return obj[pname] end)))
                    lines = lines + 1
                end
            end)
        end)
        cls = try(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
    if lines == 0 then log("  %s: no Blueprint scalar properties", label) end
end

--- Logs the candidates for the current train once per car instance.
--- anchorUsed: the tablet anchor name, or nil if none was found.
function M.report(anchorUsed)
    local cab = Cab.resolve()
    if not cab then return end
    local carName = fullName(cab.car)
    if S.reportedCars[carName] then return end
    S.reportedCars[carName] = true

    local cls = try(function() return cab.car:GetClass() end)
    local className = U.className(cab.car)
    log("== train id candidates (M12, research only) ==")
    log("  car          %s", carName)
    log("  car class    %s", fullName(cls))
    log("  pawn class   %s", U.className(cab.pawn))
    local body = try(function() return cab.car.BaseTrain end)
    log("  body mesh    %s", fullName(try(function() return body.StaticMesh end)))
    log("  tablet anchor %s", tostring(anchorUsed))

    scalars(cab.car, "car")
    local world = try(function() return cab.pc:GetWorld() end)
    local gm = try(function() return world.AuthorityGameMode end)
    if isValid(gm) then scalars(gm, "gamemode") end
    local gi = try(function() return cab.pawn.MainGameInstance end)
    if isValid(gi) then scalars(gi, "gameinstance") end
    log("== end of train id candidates ==")

    -- A train that does not have the cab-interior anchor: keep its layout.
    if anchorUsed ~= "BaseUntendai" and not S.dumpedClasses[className] then
        S.dumpedClasses[className] = true
        log("train %s has no BaseUntendai -- component tree for later support:", className)
        Cab.dump()
    end
end

return M
