--[[
    The one way this mod runs Unreal work: ExecuteInGameThread with the EngineTick
    method, errors caught and logged.

    Measured in Milestone 0 (RESEARCH.md): EngineTick delivers in 3-5 ms and keeps
    working across LoadMap. The ProcessEvent method once ran a callback with
    IsInGameThread() == false, so it is never used here.
]]

local U = require("tt.util")

local M = {}

function M.available()
    return EngineTickAvailable == true and EGameThreadMethod ~= nil
end

--- Queue fn on the game thread. Returns false if it could not even be queued.
function M.run(label, fn)
    if not M.available() then
        U.log("%s: EngineTick hook is not available, cannot run on the game thread", label)
        return false
    end
    local ok, err = pcall(ExecuteInGameThread, function()
        local ok2, err2 = pcall(fn)
        if not ok2 then U.log("%s FAILED: %s", label, tostring(err2)) end
    end, EGameThreadMethod.EngineTick)
    if not ok then U.log("%s: could not queue: %s", label, tostring(err)) end
    return ok
end

--- Same, after a delay (still EngineTick: ExecuteInGameThreadWithDelay uses the
--- configured default method, which is EngineTick in this install).
function M.runAfter(ms, label, fn)
    local ok, err = pcall(ExecuteInGameThreadWithDelay, ms, function()
        local ok2, err2 = pcall(fn)
        if not ok2 then U.log("%s FAILED: %s", label, tostring(err2)) end
    end)
    if not ok then U.log("%s: could not queue: %s", label, tostring(err)) end
    return ok
end

return M
