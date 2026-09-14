--[[
    RunningTrainTwitchTablet
    ========================
    A physical 3D tablet in the RUNNING TRAIN cab that shows Twitch chat.
    Built milestone by milestone -- see PROGRESS.md in the repository.

    Current stage: Milestone 16 + release 1.0: key map in the config, screen off, brightness, default + player config.

    Hotkeys: [Keys] in TwitchTablet.ini, action = Unreal key name (empty = off).
    Defaults are all on the numpad; the same key does one thing outside
    calibration and another inside it.
      outside calibration                 in calibration (Num0 toggles)
      Num1  hide / show the tablet        Num5  mode MOVE / ROTATE / SIZE
      Num2  screen off / on               Num4/6 Num8/2 Num9/3  adjust
      Num4 / Num6  font smaller / bigger  Num+ / Num-  scale
      Num7 / Num9  dimmer / brighter      NumEnter  save   Num.  reset
      Num8  Twitch off / on               Num/  place in front of the view
      Num5  10 s frame-time sample + status
      Num*  reload this mod (always)      Num7  fine step x0.1 on / off
                                          Alt x10 (Shift+numpad digit becomes an
      testing aids, off unless given a    arrow key in Windows); not Ctrl: UE4SS
      key: FakeMessage, DropConnection    dumps on Ctrl+Num6..9. Keys repeat.
    Plain keys, no modifiers: the Ctrl+F-key combos kept colliding with the game.

    Taken elsewhere, do not use: 1-3 (game: camera switching), F11 (game fullscreen, even with Ctrl), F12
    (Steam screenshot), Ctrl+F5 (game), F10 and ~ (UE4SS console enabler),
    '-', '=', Ctrl+F6 (HeadTracking), Ctrl+J/H/Num6-9 (UE4SS dumpers).

    All of this mod's Lua runs on the game thread: keys are polled there
    (tt/input.lua) instead of RegisterKeyBind, whose callbacks run on another
    thread in the same lua_State. tt/recon.lua (M0) and Cab.dump (M2) are kept but not bound.
]]

local U = require("tt.util")
local DevReload = require("tt.devreload")
local Input = require("tt.input")
local Config = require("tt.config")

--[[
    Startup rule: this file must not put anything on the game thread while it
    runs. main.lua executes on UE4SS's event-loop thread; on a dev reload the game
    thread is live, and a queued callback can start running in the same lua_State
    before this file has finished. M11 hit exactly that: UE4SS logged "Hook threw
    exception: Ref was not function, removing hook!" and dropped the EngineTick
    hook for the rest of the session. So everything that runs on the game thread
    is collected here and started by ONE delayed call at the very end.
]]
local STARTUP_DELAY_MS = 1000
local startups = {}
local function atStartup(name, fn) table.insert(startups, { name = name, fn = fn }) end

local MAIN_PATH = (debug.getinfo(1, "S").source or ""):gsub("^@", "")

-- Reload goes first and the rest loads under pcall: a broken module must not
-- take the reload key and file watcher down with it.
Config.load()
local keys = Config.values.keys
Input.bind(keys.reload, function() DevReload.request("key " .. Config.keyLabel("reload")) end)
DevReload.watchFile(Config.path())
DevReload.watchFile(Config.defaultsPath())
atStartup("dev reload", function() DevReload.start(MAIN_PATH) end)

local ok, err = pcall(function()
    local tablet = require("tt.tablet")
    local ChatFeed = require("tt.chatfeed")
    local ChatRender = require("tt.chatrender")
    local Calibration = require("tt.calibration")
    local ChatModel = require("tt.chatmodel")

    -- The font follows the train's profile; this is only the value before the
    -- first tablet appears.
    ChatRender.STYLE.scale = Config.values.tablet.fontscale

    DevReload.onUnload("tablet", tablet.shutdown)
    Calibration.init(tablet)
    local calibrating = Calibration.isActive

    ChatModel.MAX_MESSAGES = math.max(5, math.min(500, math.floor(Config.values.screen.maxmessages)))
    require("tt.emotes").configure(Config.values.screen.emotes, Config.modDir() .. "\\emotecache")
    require("tt.dyntexture").brightness = math.max(0.05, math.min(1, Config.values.screen.brightness))

    -- Every handler runs on the game thread (tt/input.lua polls there).
    local function normal() return not calibrating() end
    local out = { when = normal }
    local outRep = { when = normal, repeatable = true }
    local cal = { when = calibrating }
    local rep = { when = calibrating, repeatable = true }
    -- action, handler, opts, mode (for the clash check: "any" clashes with both)
    local actions = {
        { "calibrate", Calibration.toggle, nil, "any" },
        { "reload", nil, nil, "any" },     -- bound above
        { "tablet", tablet.toggle, out, "out" },
        { "screen", tablet.toggleScreen, out, "out" },
        { "fontsmaller", function() tablet.changeFontScale(1 / 1.15) end, outRep, "out" },
        { "fontbigger", function() tablet.changeFontScale(1.15) end, outRep, "out" },
        { "dimmer", function() tablet.changeBrightness(0.8) end, outRep, "out" },
        { "brighter", function() tablet.changeBrightness(1 / 0.8) end, outRep, "out" },
        { "twitch", ChatFeed.toggleTwitch, out, "out" },
        { "status", function() tablet.perfSample(10); ChatFeed.logStatus() end, out, "out" },
        { "fakemessage", tablet.addFakeMessage, out, "out" },
        { "dropconnection", ChatFeed.simulateNetworkDrop, out, "out" },
        { "calmode", Calibration.nextMode, cal, "cal" },
        { "calleft", function(m) Calibration.nudge(1, -1, m) end, rep, "cal" },
        { "calright", function(m) Calibration.nudge(1, 1, m) end, rep, "cal" },
        { "calforward", function(m) Calibration.nudge(2, 1, m) end, rep, "cal" },
        { "calback", function(m) Calibration.nudge(2, -1, m) end, rep, "cal" },
        { "calup", function(m) Calibration.nudge(3, 1, m) end, rep, "cal" },
        { "caldown", function(m) Calibration.nudge(3, -1, m) end, rep, "cal" },
        { "calbigger", function(m) Calibration.scale(1, m) end, rep, "cal" },
        { "calsmaller", function(m) Calibration.scale(-1, m) end, rep, "cal" },
        { "calsave", Calibration.save, cal, "cal" },
        { "calreset", Calibration.reset, cal, "cal" },
        { "calinfront", Calibration.placeInFront, cal, "cal" },
        { "calfine", Calibration.toggleFine, cal, "cal" },
    }
    local used = {}
    for _, a in ipairs(actions) do
        local name, fn, opts, mode = a[1], a[2], a[3], a[4]
        local key = keys[name]
        if key and key ~= "" then
            local k = key:lower()
            for _, u in ipairs(used[k] or {}) do
                if u.mode == mode or u.mode == "any" or mode == "any" then
                    U.log("keys: %s = %s clashes with %s -- both will fire", name, key, u.name)
                end
            end
            used[k] = used[k] or {}
            table.insert(used[k], { name = name, mode = mode })
            if fn then Input.bind(key, fn, opts) end
        end
    end

    atStartup("chatfeed", ChatFeed.start)
    atStartup("tablet auto-spawn", tablet.startAutoSpawn)

    -- Measured in Milestone 0: both hooks fire on the game thread.
    if RegisterLoadMapPreHook ~= nil then
        pcall(RegisterLoadMapPreHook, function()
            U.log("LoadMap pre")
            Calibration.stop()
            Input.pauseForMapLoad(3000)
            tablet.pauseForMapLoad(3000)
            tablet.forget()
        end)
    end
    if RegisterLoadMapPostHook ~= nil then
        pcall(RegisterLoadMapPostHook, function()
            U.log("LoadMap post")
            Input.pauseForMapLoad(3000)
            tablet.pauseForMapLoad(3000)
        end)
    end
end)

atStartup("input", Input.start)

-- The one hand-off to the game thread (see the startup rule above).
ExecuteInGameThreadWithDelay(STARTUP_DELAY_MS, function()
    for _, s in ipairs(startups) do
        local sok, serr = pcall(s.fn)
        if not sok then U.log("startup %s FAILED: %s", s.name, tostring(serr)) end
    end
end)

if ok then
    local K = Config.keyLabel
    U.log("loaded: milestone 16 | %s tablet | %s screen | %s calibration | %s/%s font | %s/%s brightness | %s Twitch off/on | %s status | %s fake message | %s drop connection | %s reload",
        K("tablet"), K("screen"), K("calibrate"), K("fontsmaller"), K("fontbigger"), K("dimmer"), K("brighter"),
        K("twitch"), K("status"), K("fakemessage"), K("dropconnection"), K("reload"))
else
    U.log("LOAD FAILED: %s -- fix the file; the mod reloads itself when it changes", tostring(err))
end
