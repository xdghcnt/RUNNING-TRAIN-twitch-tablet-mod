--[[
    Milestone 11 -- calibration mode (keyboard).

    Num0 enters / leaves. While active (numpad only, nothing is polled otherwise).
    Default keys below; M16 moved them to [Keys] in TwitchTablet.ini (Cal*):

        Num5            mode: MOVE -> ROTATE -> SIZE
        Num4 / Num6     MOVE: left / right     ROTATE: yaw - / +     SIZE: width - / +
        Num8 / Num2     MOVE: forward / back   ROTATE: pitch + / -   SIZE: height + / -
        Num9 / Num3     MOVE: up / down        ROTATE: roll + / -
        Num+ / Num-     whole-tablet scale
        NumEnter        save to TwitchTablet.ini
        Num.            reset to the saved values
        Num/            put the tablet in front of the view (then fine-tune)

    Steps: normal 1 cm / 1 deg / 1 cm / 0.01; Alt (or Shift) x10; Num7 toggles
    a fine step x0.1. Shift does nothing on the numpad digits with NumLock on --
    Windows turns Shift+Num8 into an arrow key -- so Alt is the one to use there.
    Not Ctrl: UE4SS's own Keybinds mod runs dumpers on Ctrl+Num6..9 (the header
    generator can hang the game for minutes).
    Keys repeat while held.

    Axes are the cab's (BaseUntendai): +X towards the front window, +Y to the
    right, +Z up -- "forward" means towards the front of the train.

    The current mode, step and transform are shown on the tablet itself and
    every change is logged as one line; Save logs the saved block.
]]

local U = require("tt.util")
local Config = require("tt.config")
local DevReload = require("tt.devreload")
local GT = require("tt.gamethread")
local ChatRender = require("tt.chatrender")
local log = U.log

local M = {}

M.MODES = { "MOVE", "ROTATE", "SIZE" }

local STEP = {
    MOVE = 1.0,      -- cm
    ROTATE = 1.0,    -- degrees
    SIZE = 1.0,      -- cm
    SCALE = 0.01,
}

local S = { active = false, mode = 1, tablet = nil, fine = false }

function M.init(tablet) S.tablet = tablet end
function M.isActive() return S.active end

local function factor(mods)
    if mods and (mods.alt or mods.shift) then return 10, " (x10)" end
    if S.fine then return 0.1, " (fine x0.1)" end
    return 1, ""
end

local function fmt(p)
    return string.format("X %.1f Y %.1f Z %.1f | P %.1f Y %.1f R %.1f | scale %.2f | %.1f x %.1f cm",
        p.x, p.y, p.z, p.pitch, p.yaw, p.roll, p.scale, p.width, p.height)
end

local FLASH_MS = 2000
local flashSeq = 0

local function showStatus(extra)
    local p = S.tablet.getPlacement()
    local mode = M.MODES[S.mode]
    -- Short on purpose: it is drawn at the chat font size to stay readable.
    -- The key list is in the log (calibration ON) and in main.lua.
    local _, trainClass = S.tablet.profile()
    S.tablet.setOverlay(string.format("CALIBRATE: %s%s  %s%s", mode, S.fine and " FINE" or "", tostring(trainClass or "default"),
        extra and ("  " .. extra) or ""))
    return p
end

--- Replaces the whole band with `text` for a moment, then the normal status.
--- "SAVED" appended to the status line did not fit on a narrow tablet, so a
--- save gave no visible response.
local function flash(text)
    flashSeq = flashSeq + 1
    local mine = flashSeq
    S.tablet.setOverlay(text)
    GT.runAfter(FLASH_MS, "calibration flash", function()
        -- Only if nothing newer happened meanwhile and we are still calibrating.
        if mine == flashSeq and S.active then showStatus() end
    end)
end

local function changed(what)
    local p = S.tablet.getPlacement()
    if p then log("calibration: %s -> %s", what, fmt(p)) end
    showStatus()
end

--------------------------------------------------------------------------------
-- keys (game thread, via tt/input.lua)
--------------------------------------------------------------------------------

function M.toggle()
    if S.active then
        S.active = false
        S.tablet.setOverlay(nil)
        log("calibration: OFF (unsaved changes stay until the tablet is respawned; %s saves)", Config.keyLabel("calsave"))
        return
    end
    if not S.tablet.exists() then
        log("calibration: no tablet in the cab (%s shows it)", Config.keyLabel("tablet"))
        return
    end
    S.active = true
    local p = showStatus()
    log("calibration: ON, mode %s | %s", M.MODES[S.mode], p and fmt(p) or "?")
    local K = Config.keyLabel
    log("calibration keys: %s mode | %s/%s %s/%s %s/%s adjust | %s/%s scale | Alt x10, %s fine x0.1 | %s save | %s reset | %s in front of view | %s exit",
        K("calmode"), K("calleft"), K("calright"), K("calforward"), K("calback"), K("calup"), K("caldown"),
        K("calbigger"), K("calsmaller"), K("calfine"), K("calsave"), K("calreset"), K("calinfront"), K("calibrate"))
end

--- Fine step (x0.1) on / off.
function M.toggleFine()
    S.fine = not S.fine
    log("calibration: fine step %s", S.fine and "ON (x0.1)" or "OFF")
    showStatus()
end

function M.nextMode()
    S.mode = S.mode % #M.MODES + 1
    log("calibration: mode %s", M.MODES[S.mode])
    showStatus()
end

--- axis: 1 = Num4/6 pair, 2 = Num8/2 pair, 3 = Num9/3 pair; sign +1/-1.
function M.nudge(axis, sign, mods)
    local p = S.tablet.getPlacement()
    if not p then return end
    local f, tag = factor(mods)
    local mode = M.MODES[S.mode]
    if mode == "MOVE" then
        local d = STEP.MOVE * f * sign
        if axis == 1 then p.y = p.y + d elseif axis == 2 then p.x = p.x + d else p.z = p.z + d end
        S.tablet.setPlacement(p)
        changed(string.format("move %s%+.2f cm%s", ({ "Y", "X", "Z" })[axis], d, tag))
    elseif mode == "ROTATE" then
        local d = STEP.ROTATE * f * sign
        if axis == 1 then p.yaw = p.yaw + d elseif axis == 2 then p.pitch = p.pitch + d else p.roll = p.roll + d end
        S.tablet.setPlacement(p)
        changed(string.format("rotate %s%+.2f deg%s", ({ "yaw", "pitch", "roll" })[axis], d, tag))
    else
        local d = STEP.SIZE * f * sign
        if axis == 1 then S.tablet.setSize(p.width + d, p.height)
        elseif axis == 2 then S.tablet.setSize(p.width, p.height + d)
        else return end
        changed(string.format("size %s%+.2f cm%s", axis == 1 and "width" or "height", d, tag))
    end
end

function M.scale(sign, mods)
    local p = S.tablet.getPlacement()
    if not p then return end
    local f, tag = factor(mods)
    p.scale = math.max(0.2, math.min(5, p.scale + STEP.SCALE * f * sign))
    S.tablet.setPlacement(p)
    changed(string.format("scale %+.3f%s", STEP.SCALE * f * sign, tag))
end

function M.reset()
    local _, trainClass = S.tablet.profile()
    local c, _, hasPosition = Config.tabletFor(trainClass)
    S.tablet.changeFontScale(c.fontscale / ChatRender.STYLE.scale)
    if not hasPosition then
        -- Nothing saved for this train yet: back to "in front of the eyes".
        S.tablet.placeInFrontOfCamera()
        changed("reset: no saved position for this train, placed in front of the view")
        return
    end
    S.tablet.setSize(c.width, c.height)
    S.tablet.setPlacement({ x = c.x, y = c.y, z = c.z, pitch = c.pitch, yaw = c.yaw, roll = c.roll, scale = c.scale })
    changed("reset to the saved values")
end

--- Milestone 14: where Save writes -- the current train's own profile
--- [Train.<car class>] (created if missing), never another train's section.
--- Nil if the train could not be identified: there is nowhere sensible to
--- keep a position then (the default profile has none on purpose).
local function saveTarget()
    local _, trainClass = S.tablet.profile()
    if type(trainClass) == "string" and trainClass:match("^[%w_]+$") then
        return "train." .. trainClass:lower(), "Train." .. trainClass
    end
    return nil
end

function M.save()
    local p = S.tablet.getPlacement()
    if not p then log("calibration: nothing to save"); return end
    local section, header = saveTarget()
    if not section then
        log("calibration: SAVE SKIPPED: the train could not be identified, so there is no profile to save into")
        flash("NOT SAVED: UNKNOWN TRAIN")
        return
    end
    -- Everything about the tablet goes into the train's profile, font included.
    local ok, err = Config.save({
        [section] = { x = p.x, y = p.y, z = p.z, pitch = p.pitch, yaw = p.yaw, roll = p.roll,
                      scale = p.scale, width = p.width, height = p.height, fontscale = p.fontscale },
    }, { [section] = header })
    if not ok then
        log("calibration: SAVE FAILED: %s", tostring(err))
        flash("SAVE FAILED")
        return
    end
    -- Our own write must not look like a user edit to the dev-reload watcher.
    DevReload.acknowledgeChanges()
    log("calibration: saved profile [%s] to %s (previous file kept as .bak): %s", header, Config.path(), fmt(p))
    S.tablet.profileSaved(header)
    flash("SAVED")
end

--- The tablet is going away (map change): leave calibration quietly.
function M.stop()
    if S.active then
        S.active = false
        S.tablet.setOverlay(nil)
        log("calibration: OFF (map change)")
    end
end

function M.placeInFront()
    S.tablet.placeInFrontOfCamera()
    if S.active then showStatus() end
end

return M
