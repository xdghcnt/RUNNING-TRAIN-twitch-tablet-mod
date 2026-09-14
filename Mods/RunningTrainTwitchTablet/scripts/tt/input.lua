--[[
    Hotkeys polled on the game thread.

    Why not RegisterKeyBind: its callbacks run on UE4SS's event-loop thread, while
    our redraw / file-watch loops run on the game thread -- and all Lua contexts of
    a mod share ONE lua_State (RESEARCH.md, "Потоки и Lua-состояния"). Two threads
    in one lua_State can corrupt it; HeadTracking's hotkeys "wedged" for exactly
    that reason, and a game hang after many rapid key presses (M7, 2026-09-25)
    could not be ruled out as the same thing. Polling keeps every line of this
    mod's Lua on the game thread.

    Each frame: PlayerController:IsInputKeyDown(FKey) per bound key, edge-detected
    here (fires on press, not while held). Only while the game window has input
    focus, like any game control.

    If polling fails on the first try (e.g. the FKey struct cannot be passed), the
    bindings fall back to RegisterKeyBind and the log says so.
]]

local U = require("tt.util")
local GT = require("tt.gamethread")
local log, try, isValid = U.log, U.try, U.isValid

local M = {}

local S = { binds = {}, modifiers = {}, started = false, fallback = false, pc = nil, nextPcLookup = 0, pausedUntil = 0 }

-- Held keys marked repeatable fire again after this delay, then at this rate.
local REPEAT_DELAY_MS = 400
local REPEAT_EVERY_MS = 80

-- Modifier state, sampled each frame only while some bind wants it.
local MODIFIERS = {
    shift = { "LeftShift", "RightShift" },
    ctrl = { "LeftControl", "RightControl" },
}

--- The UE4SS Key.* value for an Unreal key name, for the fallback only; nil if
--- there is no obvious one (that key then just does not work in fallback mode).
local function ue4ssKey(name)
    if type(Key) ~= "table" and type(Key) ~= "userdata" then return nil end
    local special = { Enter = "RETURN", Add = "ADD", Subtract = "SUBTRACT", Multiply = "MULTIPLY",
                      Divide = "DIVIDE", Decimal = "DECIMAL", SpaceBar = "SPACE" }
    local digits = { Zero = "ZERO", One = "ONE", Two = "TWO", Three = "THREE", Four = "FOUR",
                     Five = "FIVE", Six = "SIX", Seven = "SEVEN", Eight = "EIGHT", Nine = "NINE" }
    local k = special[name] or digits[name]
    if not k then
        local d = name:match("^NumPad(%a+)$")
        if d and digits[d] then k = "NUM_" .. digits[d]
        elseif name:match("^F%d+$") or name:match("^%a$") then k = name:upper() end
    end
    return k and Key[k] or nil
end

--- ueName: Unreal key name (EKeys), e.g. "F1", "Nine", "NumPadFour"; nil or ""
--- = not bound (the action is switched off in [Keys]).
--- fn(mods) runs on the game thread; mods = { shift = bool, ctrl = bool }.
--- opts.when: function -> bool; the key is not even polled while it is false
---            (calibration keys cost nothing outside calibration).
--- opts.repeatable: fires again while held.
function M.bind(ueName, fn, opts)
    opts = opts or {}
    if type(ueName) ~= "string" or ueName == "" then return end
    table.insert(S.binds, { name = ueName, ue4ssKey = ue4ssKey(ueName), fn = fn, down = false,
                            when = opts.when, repeatable = opts.repeatable })
end

local function fallBack(reason)
    if S.fallback then return end
    S.fallback = true
    log("input: game-thread polling unavailable (%s) -- falling back to RegisterKeyBind", tostring(reason))
    for _, b in ipairs(S.binds) do
        local fn, when = b.fn, b.when
        if b.ue4ssKey == nil then
            log("input: no fallback for key %s", b.name)
        else
            RegisterKeyBind(b.ue4ssKey, function()
                GT.run("key " .. b.name, function()
                    if when and not when() then return end
                    fn({ shift = false, ctrl = false, alt = false })
                end)
            end)
        end
    end
end

local function playerController()
    local now = U.nowMs()
    if isValid(S.pc) and now < S.nextPcLookup then return S.pc end
    -- Re-resolved once a second: the controller is recreated on map loads.
    S.nextPcLookup = now + 1000
    S.pc = try(function() return FindFirstOf("PlayerController") end)
    return isValid(S.pc) and S.pc or nil
end

local fkeys = {}
local function isDown(pc, name)
    local k = fkeys[name]
    if not k then k = { KeyName = FName(name) }; fkeys[name] = k end
    local down = pc:IsInputKeyDown(k)
    if type(down) ~= "boolean" then error("IsInputKeyDown returned " .. type(down)) end
    return down
end

-- Shift + a numpad digit with NumLock on reaches the game as an arrow / Home /
-- PgUp key, not as the digit (Windows' numpad shift rule, M11): the press never
-- arrives. Alt does not have that problem, so it is the coarse modifier too.
local function modifiers(pc)
    return {
        shift = isDown(pc, "LeftShift") or isDown(pc, "RightShift"),
        ctrl = isDown(pc, "LeftControl") or isDown(pc, "RightControl"),
        alt = isDown(pc, "LeftAlt") or isDown(pc, "RightAlt"),
    }
end

local function fire(b, mods)
    local ok, err = pcall(b.fn, mods)
    if not ok then log("key %s handler failed: %s", b.name, tostring(err)) end
end

local function poll()
    local now = U.nowMs()
    if now < S.pausedUntil then return end
    local pc = playerController()
    if not pc then return end
    local mods
    for _, b in ipairs(S.binds) do
        if b.when and not b.when() then
            -- Not polled; forget the state so a key held while inactive does not
            -- fire the moment it becomes active.
            b.primed, b.down = false, false
        else
            local down = isDown(pc, b.name)
            -- The first sample after start / a map load only records the state: a key
            -- still held from before must not count as a new press. (M8: key 0 held
            -- across a dev reload fired a second reload inside the fresh mod.)
            if not b.primed then
                b.primed = true
            elseif down and not b.down then
                mods = mods or modifiers(pc)
                b.nextRepeat = now + REPEAT_DELAY_MS
                fire(b, mods)
            elseif down and b.repeatable and now >= (b.nextRepeat or math.huge) then
                mods = mods or modifiers(pc)
                b.nextRepeat = now + REPEAT_EVERY_MS
                fire(b, mods)
            end
            b.down = down
        end
    end
end

--- Starts polling. Must be called after all bind() calls, on the game thread
--- (main.lua's delayed init).
function M.start()
    if S.started then return end
    S.started = true
    do
        local handle
        local okStart = pcall(function()
            handle = LoopInGameThreadAfterFrames(1, function()
                if S.fallback then return end
                local ok, err = pcall(poll)
                if not ok then
                    pcall(CancelDelayedAction, handle)
                    fallBack(err)
                end
            end)
        end)
        if not okStart then
            fallBack("LoopInGameThreadAfterFrames failed")
        else
            log("input: polling %d keys on the game thread", #S.binds)
        end
    end
end

--- A map load is starting: drop the cached controller (it is about to be
--- destroyed) and stay off UObjects for a while (HeadTracking: touching them
--- during a load crashed the game).
function M.pauseForMapLoad(ms)
    S.pc = nil
    S.nextPcLookup = 0
    S.pausedUntil = U.nowMs() + ms
    for _, b in ipairs(S.binds) do b.primed = false end
end

return M
