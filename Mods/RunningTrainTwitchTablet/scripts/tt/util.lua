--[[
    Small helpers shared by every module.

    Patterns carried over from HeadTracking (see HEADTRACKING_REFERENCE.md):
      * every UObject access goes through pcall -- a missing property raises or
        yields a TrivialObject instead of nil;
      * numbers read from structs are type-checked before use;
      * UE4SS print() does not append a newline, so log() always does.
]]

local M = {}

local TAG = "[Tablet] "

function M.log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print(TAG .. (ok and s or tostring(fmt)) .. "\n")
end

--- pcall that returns the value or nil, err.
function M.try(f, ...)
    local ok, res = pcall(f, ...)
    if ok then return res end
    return nil, tostring(res)
end

function M.isValid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

function M.fullName(o)
    if not M.isValid(o) then return "<invalid>" end
    return M.try(function() return o:GetFullName() end) or "<no name>"
end

--- Short class name, e.g. "PyBP_Base_Unten_Actor_C".
function M.className(o)
    if not M.isValid(o) then return "<invalid>" end
    return M.try(function() return o:GetClass():GetFName():ToString() end) or "<no class>"
end

function M.nowMs()
    return math.floor(os.clock() * 1000)
end

local function num(x) return type(x) == "number" end

--- Copies an FVector-like value into a plain table, or nil if it is not one.
function M.vec(v)
    if v == nil then return nil end
    local ok, r = pcall(function() return { X = v.X, Y = v.Y, Z = v.Z } end)
    if not ok or not (num(r.X) and num(r.Y) and num(r.Z)) then return nil end
    return r
end

function M.rot(v)
    if v == nil then return nil end
    local ok, r = pcall(function() return { Pitch = v.Pitch, Yaw = v.Yaw, Roll = v.Roll } end)
    if not ok or not (num(r.Pitch) and num(r.Yaw) and num(r.Roll)) then return nil end
    return r
end

function M.vecStr(v)
    local c = M.vec(v)
    if not c then return "n/a" end
    return string.format("(%.1f, %.1f, %.1f)", c.X, c.Y, c.Z)
end

function M.rotStr(v)
    local c = M.rot(v)
    if not c then return "n/a" end
    return string.format("(P=%.2f Y=%.2f R=%.2f)", c.Pitch, c.Yaw, c.Roll)
end

function M.threadTag()
    local g = M.try(function() return IsInGameThread() end)
    if g == true then return "game thread" end
    if g == false then return "NOT game thread" end
    return "thread unknown"
end

return M
