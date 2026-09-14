--[[
    Chat feed: background producers (C++) -> queue -> game thread -> ChatModel.

        C++ (RunningTrainTwitchTabletNative)             Lua, game thread only
        TwitchClient thread ---push--> ChatQueue ==pop==> ChatFeed --add--> ChatModel --> ChatRenderer
        (SyntheticProducer, M8 test source, off by default)

    Milestone 8 built the queue and the draining; Milestone 9 puts the Twitch
    client behind it. The renderer and ChatModel do not know the source.

    The C++ side registers RTTT_* into this mod AFTER main.lua has run (UE4SS calls
    on_lua_start after a Lua mod starts), so the functions are looked up lazily on
    every tick; nothing is assumed about the order.

    Draining is bounded per tick so a burst cannot stall a frame; the rest waits in
    the C++ queue (bounded itself, drops counted).
]]

local U = require("tt.util")
local ChatModel = require("tt.chatmodel")
local Config = require("tt.config")
local log = U.log

local M = {}

local TICK_MS = 100
local MAX_PER_TICK = 50
local STATUS_EVERY_MS = 60000

local function channel() return Config.values.twitch.channel end

-- M8 test source, kept for load tests; not started by default any more.
local SYNTH = { intervalMs = 3000, burstEvery = 10, burstSize = 20 }

local S = {
    native = false, missingLogged = false, t0 = 0,
    drained = 0, maxBatch = 0, nextStatus = 0,
    twitchState = nil, twitchError = "", twitchWanted = nil,
}

local function nativeAvailable()
    return RTTT_PopMessage ~= nil and RTTT_Status ~= nil and RTTT_TwitchStatus ~= nil
end

--------------------------------------------------------------------------------
-- colours
--------------------------------------------------------------------------------

--- Twitch "#RRGGBB" (sRGB) -> FLinearColor for the Canvas, lifted when too dark
--- to read on the near-black screen. nil for "no colour" (ChatModel picks one).
local function colorFromHex(hex)
    if type(hex) ~= "string" then return nil end
    local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
    if not r then return nil end
    local function lin(x)
        local c = tonumber(x, 16) / 255
        return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
    end
    local R, G, B = lin(r), lin(g), lin(b)
    local lum = 0.2126 * R + 0.7152 * G + 0.0722 * B
    if lum < 0.08 then
        -- Mix toward white until readable, keeping the hue.
        local t = 0.45
        R, G, B = R + (1 - R) * t, G + (1 - G) * t, B + (1 - B) * t
    end
    return { R = R, G = G, B = B, A = 1 }
end
M.colorFromHex = colorFromHex

--------------------------------------------------------------------------------
-- status / logging
--------------------------------------------------------------------------------

local STATE_LABEL = {
    connecting = "Connecting",
    connected = "Connected",
    joined = "Joined",
    waiting = "Disconnected, waiting to reconnect",
    stopped = "Stopped",
}

--- Logs Twitch state transitions once each (never per tick).
local function watchTwitch()
    local state, channel, received, connects, err = RTTT_TwitchStatus()
    if state ~= S.twitchState then
        local label = STATE_LABEL[state] or tostring(state)
        if state == "waiting" or (state == "stopped" and err ~= "") then
            log("[Twitch] %s (#%s): %s", label, tostring(channel), err ~= "" and err or "no error reported")
        elseif state == "joined" then
            log("[Twitch] %s #%s (connection #%s, %s messages so far)", label, tostring(channel), tostring(connects), tostring(received))
        else
            log("[Twitch] %s #%s", label, tostring(channel))
        end
        S.twitchState = state
        S.twitchError = err
    elseif err ~= S.twitchError and err ~= "" then
        log("[Twitch] %s", err)
        S.twitchError = err
    end
end

local function status(prefix)
    if not nativeAvailable() then return end
    local queued, pushed, dropped, synth = RTTT_Status()
    local state, channel, received, connects, err, bytes = RTTT_TwitchStatus()
    log("%s native %s | twitch %s #%s received=%s bytes=%s connects=%s | queue pushed=%s drained=%d queued=%s dropped=%s max batch=%d | synthetic=%s%s",
        prefix, tostring(RTTT_Version()), tostring(state), tostring(channel), tostring(received), tostring(bytes), tostring(connects),
        tostring(pushed), S.drained, tostring(queued), tostring(dropped), S.maxBatch, tostring(synth),
        err ~= "" and (" | last error: " .. err) or "")
end

--------------------------------------------------------------------------------
-- loop
--------------------------------------------------------------------------------

local function connect()
    if S.native then return true end
    if not nativeAvailable() then
        if not S.missingLogged and U.nowMs() - S.t0 > 5000 then
            S.missingLogged = true
            log("chatfeed: C++ mod RunningTrainTwitchTabletNative (0.9+) is not loaded -- no Twitch chat")
        end
        return false
    end
    S.native = true
    log("chatfeed: connected to native %s", tostring(RTTT_Version()))
    -- The M8 producer may still be running from an older Lua state; M9 does not want it.
    RTTT_StopSynthetic()
    S.twitchWanted = Config.values.twitch.enabled
    if S.twitchWanted and channel() == "" then
        S.twitchWanted = false
        RTTT_TwitchStop()
        log("[Twitch] no channel set -- put yours in %s: Channel = <name>", Config.FILE_NAME)
    elseif S.twitchWanted then
        -- Idempotent for the same channel; a changed channel reconnects.
        RTTT_TwitchStart(channel())
    else
        RTTT_TwitchStop()
        log("[Twitch] disabled in %s", Config.FILE_NAME)
    end
    return true
end

local function drain()
    local n = 0
    while n < MAX_PER_TICK do
        local user, text, color, emotes = RTTT_PopMessage()
        if user == nil then break end
        ChatModel.add({ user = user, text = text, color = colorFromHex(color), emotes = emotes })
        n = n + 1
    end
    S.drained = S.drained + n
    if n > S.maxBatch then S.maxBatch = n end
end

--- Game thread only.
function M.start()
    S.t0 = U.nowMs()
    S.nextStatus = S.t0 + STATUS_EVERY_MS
    LoopInGameThreadWithDelay(TICK_MS, function()
        local ok, err = pcall(function()
            if not connect() then return end
            drain()
            watchTwitch()
            if U.nowMs() >= S.nextStatus then
                S.nextStatus = U.nowMs() + STATUS_EVERY_MS
                status("chatfeed:")
            end
        end)
        if not ok then log("chatfeed error: %s", tostring(err)) end
    end)
end

--------------------------------------------------------------------------------
-- keys (game thread)
--------------------------------------------------------------------------------

--- Twitch key: disconnect from / reconnect to Twitch.
function M.toggleTwitch()
    if not nativeAvailable() then log("chatfeed: native mod not loaded"); return end
    if not S.twitchWanted and channel() == "" then
        log("[Twitch] no channel set in %s", Config.FILE_NAME)
        return
    end
    S.twitchWanted = not S.twitchWanted
    if S.twitchWanted then
        log("[Twitch] start requested")
        RTTT_TwitchStart(channel())
    else
        log("[Twitch] stop requested, was running=%s", tostring(RTTT_TwitchStop()))
    end
end

--- DropConnection key: abort the connection as if the network dropped; it must reconnect.
function M.simulateNetworkDrop()
    if not nativeAvailable() then log("chatfeed: native mod not loaded"); return end
    log("[Twitch] simulating a network drop")
    RTTT_TwitchDrop()
end

--- M8 load-test source, not bound to a key by default.
function M.toggleSynthetic()
    if not nativeAvailable() then log("chatfeed: native mod not loaded"); return end
    local _, _, _, running = RTTT_Status()
    if running then
        log("chatfeed: synthetic producer stopped=%s", tostring(RTTT_StopSynthetic()))
    else
        log("chatfeed: synthetic producer started=%s",
            tostring(RTTT_StartSynthetic(SYNTH.intervalMs, SYNTH.burstEvery, SYNTH.burstSize)))
    end
end

function M.logStatus()
    status("chatfeed:")
    log("%s", require("tt.emotes").status())
end

return M
