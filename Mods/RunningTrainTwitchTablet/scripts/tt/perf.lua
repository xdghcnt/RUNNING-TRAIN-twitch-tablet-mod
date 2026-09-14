--[[
    Frame-time sampler for comparing "tablet off / static / dynamic" (M6).

    One game-thread callback per frame for the sample window only, reading
    GameplayStatics:GetWorldDeltaSeconds. Reports average, 1% worst and max frame
    time, plus how long our own screen updates took in the same window (wall clock
    around the Lua draw calls; GPU cost is not visible from here).
]]

local U = require("tt.util")
local log, try, isValid = U.log, U.try, U.isValid

local M = {}

local S = { running = false, updates = { n = 0, totalMs = 0, maxMs = 0 } }

--- Called by the dynamic screen around each redraw.
function M.recordUpdate(ms)
    local u = S.updates
    u.n = u.n + 1
    u.totalMs = u.totalMs + ms
    if ms > u.maxMs then u.maxMs = ms end
end

local function clock() return os.clock() * 1000 end
M.clock = clock

function M.sample(label, seconds)
    if S.running then log("perf: a sample is already running"); return end
    local pc = try(function() return FindFirstOf("PlayerController") end)
    local gs = try(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
    if not (isValid(pc) and isValid(gs)) then log("perf: no PlayerController / GameplayStatics"); return end
    local world = pc:GetWorld()

    S.running = true
    S.updates = { n = 0, totalMs = 0, maxMs = 0 }
    local frames, t0, handle = {}, clock(), nil
    log("perf: sampling %d s [%s]", seconds, label)

    local function finish()
        pcall(CancelDelayedAction, handle)
        S.running = false
        if #frames == 0 then log("perf: no frames recorded"); return end
        local sum = 0
        for _, f in ipairs(frames) do sum = sum + f end
        table.sort(frames)
        local p99 = frames[math.max(1, math.floor(#frames * 0.99))]
        local over33 = 0
        for _, f in ipairs(frames) do if f > 33.4 then over33 = over33 + 1 end end
        local u = S.updates
        log("perf [%s]: %d frames, avg %.2f ms (%.1f fps), 1%% worst %.2f ms, max %.2f ms, >33ms %d",
            label, #frames, sum / #frames, 1000 / (sum / #frames), p99, frames[#frames], over33)
        log("perf [%s]: screen updates %d, avg %.2f ms, max %.2f ms (Lua wall clock, 1 ms resolution)",
            label, u.n, u.n > 0 and u.totalMs / u.n or 0, u.maxMs)
    end

    handle = LoopInGameThreadAfterFrames(1, function()
        local ok, err = pcall(function()
            local dt = try(function() return gs:GetWorldDeltaSeconds(world) end)
            if type(dt) == "number" then table.insert(frames, dt * 1000) end
            if clock() - t0 >= seconds * 1000 then finish() end
        end)
        if not ok then
            pcall(CancelDelayedAction, handle)
            S.running = false
            log("perf: sample failed: %s", tostring(err))
        end
    end)
end

return M
