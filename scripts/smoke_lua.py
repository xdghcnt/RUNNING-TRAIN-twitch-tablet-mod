"""Run the Lua mod against tests/ue4ss_stub.lua and fail on any error it logs.

    python scripts/smoke_lua.py

Catches Lua-level mistakes before a game launch. Says nothing about whether the
Unreal calls themselves work -- only the real game can answer that.
"""

import pathlib
import sys

try:
    import lupa.lua54 as lupa
except ImportError:
    sys.exit("lupa is missing: pip install lupa")

repo = pathlib.Path(__file__).resolve().parent.parent
scripts = repo / "Mods" / "RunningTrainTwitchTablet" / "scripts"
tests = repo / "tests"

lua = lupa.LuaRuntime()
lua.execute(f'package.path = "{scripts.as_posix()}/?.lua;{tests.as_posix()}/?.lua;" .. package.path')

printed, scenario_error = lua.execute(r"""
local Stub = require("ue4ss_stub")
-- Controllable clock so time-based guards can be exercised.
Stub.clockMs = 0
os.clock = function() return Stub.clockMs / 1000 end
-- The real config files are never touched: the shipped defaults are copied,
-- and the player's file is a scratch one with a test channel and the testing keys.
do
    local Config = require("tt.config")
    local src = io.open(Config.defaultsPath(), "rb"); local text = src:read("a"); src:close()
    local defaults = os.tmpname() .. "_TwitchTablet.default.ini"
    local d = io.open(defaults, "wb"); d:write(text); d:close()
    local user = os.tmpname() .. "_TwitchTablet.ini"
    local u = io.open(user, "wb")
    u:write([[
[Twitch]
Channel = smoke_channel

[Keys]
FakeMessage = NumPadThree
DropConnection = Decimal
]])
    u:close()
    Config.defaultsPath = function() return defaults end
    Config.path = function() return user end
    Stub.configCopy = user
    Stub.defaultsCopy = defaults
end
dofile(package.searchpath("main", package.path))
local ok, err = pcall(function()

-- Keybinds only queue; draining runs the queued work as the game thread would.
Stub.drain()             -- first frame: input primes, auto-spawn puts the tablet up (config transform)
assert((Stub.texts or 0) >= 1 and Stub.openDraws == 0, "empty-chat hint was not drawn")
Stub.pressKey("NumPadOne")      -- hide
Stub.drain()             -- auto-spawn must NOT bring it back while hidden
Stub.pressKey("NumPadOne")          -- show again (config transform)
-- M13: a [Train.<class>] section overrides [Tablet] for that train only.
do
    local Config = require("tt.config")
    local keep = io.open(Stub.configCopy, "rb"); local original = keep:read("a"); keep:close()
    local f = io.open(Stub.configCopy, "a")
    f:write([[

[Train.Cpy_KuHa115_C]
X = 111.5
Z = 222
[Train.Cpy_Other_C]
X = 999
]])
    f:close()
    Config.load()
    local t, profile, hasPos = Config.tabletFor("Cpy_KuHa115_C")
    assert(profile == "Train.Cpy_KuHa115_C" and hasPos and t.x == 111.5 and t.z == 222,
           "train profile not applied")
    local d, dp, dpos = Config.tabletFor("Cpy_Unknown_C")
    assert(dp == "none" and not dpos and d.width == Config.values.tablet.width,
           "unknown train must get the default look and no position")
    Stub.pressKey("NumPadOne"); Stub.pressKey("NumPadOne")   -- respawn with the profile
    -- Back to the plain config for the calibration checks below.
    local w = io.open(Stub.configCopy, "wb"); w:write(original); w:close()
    Config.load()
    -- M14: a train with no profile gets the tablet in front of the eyes and a hint.
    Config.trains["cpy_kuha115_c"] = nil
    local texts = Stub.texts or 0
    Stub.pressKey("NumPadOne"); Stub.pressKey("NumPadOne")
    local sawHint = false
    for _, l in ipairs(Stub.printed) do
        if l:find("no saved position for Cpy_KuHa115_C", 1, true) then sawHint = true end
    end
    assert(sawHint, "unknown train was not placed in front of the view")
    assert((Stub.texts or 0) > texts, "hint was not drawn")
    Config.load()
    Stub.pressKey("NumPadOne"); Stub.pressKey("NumPadOne")
end
Stub.pressKey("NumPadThree")    -- one message so the chat itself is drawn
local texts0 = Stub.texts or 0
assert(texts0 >= 2 and Stub.openDraws == 0, "chat was not drawn: " .. tostring(texts0))
Stub.drain()                                     -- loop tick without changes: must NOT redraw
assert((Stub.texts or 0) == texts0, "redrew an unchanged chat")
local measures0 = Stub.measures
for _ = 1, 25 do Stub.pressKey("NumPadThree") end   -- 25 fake messages, all queued
Stub.drain()                                     -- loop tick: redraw once
assert((Stub.texts or 0) > texts0, "chat did not redraw after new messages")
print(string.format("[Tablet] smoke: %d text draws, %d width measurements (cache)", Stub.texts, Stub.measures))
-- M11 calibration: numpad inactive until Num0.
local rts = Stub.renderTargets
Stub.pressKey("Add")
assert(Stub.renderTargets == rts, "calibration key acted outside calibration")
-- M16: key map from [Keys]; screen off / on and brightness.
do
    local Config = require("tt.config")
    local Dyn = require("tt.dyntexture")
    assert(Config.keyLabel("calibrate") == "Num0" and Config.keyLabel("calsave") == "Enter", "key labels")
    local t = Stub.texts or 0
    Stub.pressKey("NumPadTwo")                  -- screen off: nothing but the background
    assert((Stub.texts or 0) == t, "screen off still drew text")
    Stub.pressKey("NumPadThree")                -- a message while off: still no text
    Stub.drain()
    assert((Stub.texts or 0) == t, "screen off drew a new message")
    Stub.pressKey("NumPadTwo")                  -- screen on: chat again
    assert((Stub.texts or 0) > t, "screen on did not redraw the chat")
    Stub.pressKey("NumPadSeven")
    assert(Dyn.brightness < 1, "dimmer did nothing")
    for _ = 1, 20 do Stub.pressKey("NumPadNine") end
    assert(Dyn.brightness == 1, "brighter did not return to full: " .. Dyn.brightness)
end
local before = require("tt.config").tabletFor("Cpy_KuHa115_C")
local defaultBefore = require("tt.config").values.tablet.width
Stub.pressKey("NumPadZero")    -- calibration ON
Stub.pressKey("NumPadSix")     -- MOVE +Y 1 cm
Stub.keysDown["LeftAlt"] = true
Stub.pressKey("NumPadEight")   -- MOVE +X 10 cm (Alt)
Stub.keysDown["LeftAlt"] = nil
Stub.pressKey("NumPadFive")    -- ROTATE
Stub.pressKey("NumPadFour")    -- yaw -1
Stub.pressKey("NumPadFive")    -- SIZE
Stub.pressKey("NumPadSix")     -- width +1: new render target with the new aspect
Stub.pressKey("NumPadTwo")     -- height -1
assert(Stub.renderTargets == rts + 2, "resize did not rebuild the render target")
Stub.pressKey("Add")           -- scale +0.01
Stub.pressKey("Enter")         -- save (writes the config next to the mod: a temp copy in this test)
Stub.pressKey("Decimal")       -- reset to saved
Stub.pressKey("NumPadZero")    -- calibration OFF
do
    -- M14: Save goes to the current train's own profile (the stub train is
    -- Cpy_KuHa115_C), creating the section; [Tablet] and other trains untouched.
    local Config = require("tt.config")
    local kcBefore = Config.tabletFor("Cpy_KC1000Tc_C")
    Config.load()                                   -- reads the scratch copy back
    local t, profile = Config.tabletFor("Cpy_KuHa115_C")
    local function near(a, b) return math.abs(a - b) < 0.051 end
    assert(profile == "Train.Cpy_KuHa115_C", "saved into " .. tostring(profile) .. ", not the train's profile")
    assert(near(t.x, before.x + 10) and near(t.y, before.y + 1) and near(t.yaw, before.yaw - 1)
           and near(t.width, before.width + 1) and near(t.height, before.height - 1) and near(t.scale, before.scale + 0.01),
           string.format("saved transform wrong: x %.2f->%.2f y %.2f->%.2f width %.1f->%.1f",
                         before.x, t.x, before.y, t.y, before.width, t.width))
    local d = Config.values.tablet
    assert(d.x == nil and near(d.width, defaultBefore), "the default [Tablet] profile was overwritten")
    local kc = Config.tabletFor("Cpy_KC1000Tc_C")
    assert(near(kc.x, kcBefore.x) and near(kc.z, kcBefore.z), "another train's profile was touched")
    local f = io.open(Stub.configCopy, "r"); local text = f:read("a"); f:close()
    assert(text:find("[Train.Cpy_KuHa115_C]", 1, true), "section header not written with its original case")
    os.remove(Stub.configCopy); os.remove(Stub.configCopy .. ".bak"); os.remove(Stub.defaultsCopy)
end
Stub.pressKey("NumPadSix")     -- font bigger: immediate redraw
Stub.pressKey("NumPadFour")    -- font smaller
Stub.pressKey("NumPadFive")   -- perf sample
-- M8: the native mod appears after main.lua ran; a burst of 120 must drain in ticks of <= 50.
Stub.registerNative()
for i = 1, 120 do Stub.nativePush("synthetic_bot", "#" .. i .. " burst message", i % 2 == 0 and "#8A2BE2" or "") end
Stub.drain(); Stub.drain(); Stub.drain(); Stub.drain()
assert(#Stub.nativeQueue == 0, "native queue not drained: " .. #Stub.nativeQueue)
assert(Stub.twitch.state == "joined" and Stub.twitch.channel == "smoke_channel", "Twitch was not started")
-- Emotes: the tag splits the text by code points (Cyrillic before the emote).
do
    local CM = require("tt.chatmodel")
    local p = CM.splitEmotes("25:0-4,6-10", "Kappa Kappa")
    assert(p and #p == 3 and p[1].emote == "25" and p[2].text == " " and p[3].text == "Kappa", "emote split")
    p = CM.splitEmotes("25:7-11", "\u{43F}\u{440}\u{438}\u{432}\u{435}\u{442} Kappa!")
    assert(p and p[1].text == "\u{43F}\u{440}\u{438}\u{432}\u{435}\u{442} " and p[2].text == "Kappa" and p[3].text == "!",
           "emote split after Cyrillic")
    assert(CM.splitEmotes("25:0-40", "Kappa") == nil, "out-of-range tag must fall back to text")
    assert(CM.splitEmotes("", "Kappa") == nil, "no tag, no pieces")
    -- A message with an emote: first drawn as text, then from the atlas.
    local Emotes = require("tt.emotes")
    local dir = os.tmpname():gsub("[^\\/]+$", "")
    Emotes.configure(true, dir:sub(1, -2))   -- the temp folder itself (no mkdir in plain Lua)
    Stub.pressKey("NumPadOne"); Stub.pressKey("NumPadOne")   -- respawn: the atlas needs the native mod
    Stub.nativePush("viewer", "hi Kappa there", "", "25:3-7")
    Stub.drain()
    assert(Stub.emoteRequests["25"], "emote download was not requested")
    for _ = 1, 4 do Stub.clockMs = Stub.clockMs + 300; Stub.drain() end
    assert((Stub.imports or 0) == 1, "emote was not imported into the atlas: " .. tostring(Stub.imports))
    assert((Stub.emoteDraws or 0) >= 1, "emote was not drawn from the atlas")
    os.remove(Stub.emoteRequests["25"])
    print("[Tablet] smoke: " .. Emotes.status())
end
Stub.pressKey("Decimal")    -- simulate network drop
Stub.pressKey("NumPadEight")   -- Twitch off
assert(Stub.twitch.state == "stopped", "Twitch did not stop")
Stub.pressKey("NumPadEight")   -- Twitch on
assert(Stub.twitch.state == "joined", "Twitch did not restart")
Stub.pressKey("NumPadOne")   -- remove
Stub.pressKey("NumPadOne")   -- spawn again (not re-seeded)
Stub.pressKey("Multiply")   -- dev reload within 2 s of start: must be ignored
assert(not Stub.restarted, "reload was not guarded right after start")
Stub.clockMs = Stub.clockMs + 5000
Stub.pressKey("Multiply")   -- dev reload
Stub.drain()
assert(Stub.cleared and Stub.restarted == 1, "dev reload did not restart")
print("[Tablet] smoke: restart requested once")
end)
return Stub.printed, (not ok) and tostring(err) or nil
""")

lines = [printed[i] for i in range(1, len(printed) + 1)]
bad = [l for l in lines if any(w in l for w in ("FAILED", "error", "could not queue", "attempt to"))]
for l in lines:
    print(l)
print(f"\n{len(lines)} log lines, {len(bad)} problems")
for l in bad:
    print("PROBLEM:", l)
if scenario_error:
    print("SCENARIO FAILED:", scenario_error)
sys.exit(1 if bad or scenario_error else 0)
