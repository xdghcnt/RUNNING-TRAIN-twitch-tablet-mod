--[[
    Milestone 10 -- one manual config file.

    <mod folder>/TwitchTablet.ini, plain "key = value" under [Section] headers,
    ';' or '#' start a comment. Types follow the defaults below: a key the mod
    does not know, or a value of the wrong type, is logged and ignored -- a typo
    never takes the mod down. Missing file -> defaults.

    The tablet transform is relative to the cab interior (BaseUntendai, M2), in
    cm and degrees; Scale multiplies the whole tablet.

    Milestone 13 -- per-train profiles. [Tablet] is the default profile; a
    section [Train.<car class>] (the M12 identifier, e.g. [Train.Cpy_KC1000Tc_C])
    overrides any of its placement keys for that train only. A train without a
    section -- or one the mod cannot identify -- uses [Tablet].

    Release -- two files. TwitchTablet.default.ini ships with the mod: every
    option with its explanation plus the train presets; an update replaces it.
    TwitchTablet.ini is the player's: created on first run, read on top of the
    defaults, never shipped, so an update cannot wipe the channel or a
    calibration. Calibration Save writes only there.
]]

local U = require("tt.util")
local log = U.log

local M = {}

M.FILE_NAME = "TwitchTablet.ini"
M.DEFAULTS_FILE_NAME = "TwitchTablet.default.ini"

-- Written when the player's file does not exist yet.
M.USER_TEMPLATE = [[
; RUNNING TRAIN -- Twitch Tablet: YOUR settings
;
; Anything here overrides TwitchTablet.default.ini, which lists every option
; with an explanation plus the tablet positions for the known trains. Mod
; updates replace that file, never this one: copy a line or a whole section
; from there to here and change it.
;
; Calibration Save (Num0 ... NumEnter) writes the train's section here.

[Twitch]
; Your channel, as in twitch.tv/<channel>
Channel =
]]

-- Defaults. The transform is where the M9 session's "in front of the camera"
-- spawn ended up (a starting point; calibrate with Num5 / M11).
M.defaults = {
    twitch = {
        channel = "",         -- empty: not connected; the screen says where to set it
        enabled = true,
    },
    -- [Tablet]: AutoSpawn plus the look a tablet has in a train that has no
    -- profile yet. No position: a placement from another train's cab lands
    -- somewhere random (outside kr5000, above the head in DC8500), so an
    -- unknown train gets the tablet in front of the eyes instead (M14).
    tablet = {
        autospawn = true,
        scale = 1.0,
        width = 16.0,
        height = 12.0,
        -- Chat font size. Part of the tablet profile, so it can differ per train
        -- (the user: "everything per train"). The old [Screen] FontScale is still
        -- read when [Tablet] has none.
        fontscale = 3.0,
    },
    screen = {
        fontscale = 3.0,      -- legacy location (M10-M13)
        -- M16. 1.0 = full; the screen material is unlit pass-through and the
        -- render target is 8-bit, so the colours cannot go brighter than that.
        brightness = 0.64,    -- two Dimmer presses below full: 1.0 glared, most of all on emotes
        maxmessages = 60,     -- messages kept in memory (only the newest fit on the screen anyway)
        pixelspercm = 768 / 14.4,   -- render target density; text size in cm stays the same
        emotes = true,        -- Twitch emotes as images (downloaded once, kept in emotecache\)
    },
    -- M16: action -> Unreal key name (EKeys: NumPadZero..NumPadNine, Add, Subtract,
    -- Multiply, Divide, Decimal, Enter, F1..F12, A..Z, Zero..Nine, ...). An empty
    -- value switches the action off. Outside calibration and inside it the same
    -- key may do different things; the Cal* keys work only in calibration.
    keys = {
        tablet = "NumPadOne",
        screen = "NumPadTwo",
        calibrate = "NumPadZero",
        fontsmaller = "NumPadFour",
        fontbigger = "NumPadSix",
        dimmer = "NumPadSeven",
        brighter = "NumPadNine",
        twitch = "NumPadEight",
        status = "NumPadFive",
        fakemessage = "",           -- testing aids, off unless given a key
        dropconnection = "",
        reload = "Multiply",
        calmode = "NumPadFive",
        calleft = "NumPadFour",
        calright = "NumPadSix",
        calforward = "NumPadEight",
        calback = "NumPadTwo",
        calup = "NumPadNine",
        caldown = "NumPadThree",
        calbigger = "Add",
        calsmaller = "Subtract",
        calsave = "Enter",
        calreset = "Decimal",
        calinfront = "Divide",
        calfine = "NumPadSeven",
    },
}

local function deepCopy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = type(v) == "table" and deepCopy(v) or v end
    return c
end

-- Keys a [Train.*] section may override: everything about the tablet itself.
M.PROFILE_KEYS = { x = true, y = true, z = true, pitch = true, yaw = true, roll = true,
                   scale = true, width = true, height = true, fontscale = true }

M.values = deepCopy(M.defaults)
M.trains = {}         -- lower-case class name -> { key = value } overrides
M.trainNames = {}     -- lower-case class name -> name as written in the file

--- Directory of the mod (the folder that holds scripts/).
function M.modDir()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    -- .../<mod>/Scripts/tt/config.lua -> .../<mod>. Case-insensitive: UE4SS
    -- reports the folder as "Scripts" while the repo has "scripts" (M10 first
    -- run looked for ...\config.lua\TwitchTablet.ini and fell back to defaults).
    return (src:gsub("[/\\][Ss][Cc][Rr][Ii][Pp][Tt][Ss][/\\]tt[/\\][^/\\]*$", ""))
end

function M.path()
    return M.modDir() .. "\\" .. M.FILE_NAME
end

function M.defaultsPath()
    return M.modDir() .. "\\" .. M.DEFAULTS_FILE_NAME
end

local function toBool(s)
    s = s:lower()
    if s == "true" or s == "1" or s == "yes" or s == "on" then return true end
    if s == "false" or s == "0" or s == "no" or s == "off" then return false end
    return nil
end

--- Reads one file over what is already in M.values / M.trains.
--- st collects counters across files. Returns true if the file was read.
local function readFile(path, st)
    local f = io.open(path, "r")
    if not f then return false end

    local section, applied, ignored = nil, 0, 0
    local train = nil     -- lower-case class name while inside a [Train.*] section
    local lineNo = 0
    for rawLine in f:lines() do
        lineNo = lineNo + 1
        -- ASCII-only trimming: Lua's %s matches some UTF-8 continuation bytes on Windows (M7).
        local line = rawLine:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")
        if line == "" or line:find("^[;#]") then
            -- comment / blank
        elseif line:find("^%[") then
            local raw = line:match("^%[([%w_%.]+)%]") or ""
            section, train = raw:lower(), nil
            local cls = raw:match("^[Tt][Rr][Aa][Ii][Nn]%.([%w_]+)$")
            if cls then
                train = cls:lower()
                M.trains[train] = M.trains[train] or {}
                M.trainNames[train] = cls
            elseif not M.values[section] then
                log("config: line %d: unknown section [%s]", lineNo, raw)
            end
        elseif train then
            local k, v = line:match("^([%w_]+)[ \t]*=[ \t]*(.-)[ \t]*$")
            if k then v = v:gsub("[ \t]*[;#].*$", "") end
            local key = k and k:lower()
            local num = v and tonumber(v)
            if not k or not M.PROFILE_KEYS[key] then
                log("config: line %d: [Train.%s] takes X Y Z Pitch Yaw Roll Scale Width Height FontScale, not %q", lineNo,
                    M.trainNames[train], line)
                ignored = ignored + 1
            elseif not num then
                log("config: line %d: %s = %q is not a number", lineNo, k, v); ignored = ignored + 1
            else
                M.trains[train][key] = num
                applied = applied + 1
            end
        else
            local k, v = line:match("^([%w_]+)[ \t]*=[ \t]*(.-)[ \t]*$")
            if k then v = v:gsub("[ \t]*[;#].*$", "") end
            local sec = section and M.values[section]
            local key = k and k:lower()
            if not k then
                log("config: line %d: cannot parse %q", lineNo, line); ignored = ignored + 1
            elseif not sec or sec[key] == nil then
                log("config: line %d: unknown key %s in [%s]", lineNo, k, tostring(section)); ignored = ignored + 1
            else
                local def = M.defaults[section][key]
                local val
                if type(def) == "boolean" then val = toBool(v)
                elseif type(def) == "number" then val = tonumber(v)
                else val = v end
                if val == nil then
                    log("config: line %d: %s = %q is not a %s, keeping %s", lineNo, k, v, type(def), tostring(sec[key]))
                    ignored = ignored + 1
                else
                    sec[key] = val
                    applied = applied + 1
                    if section == "tablet" and key == "fontscale" then st.tabletFontSet = true end
                end
            end
        end
    end
    f:close()
    log("config: read %s (%d values, %d ignored)", path, applied, ignored)
    return true
end

--- Defaults in code, then TwitchTablet.default.ini, then the player's
--- TwitchTablet.ini (created from USER_TEMPLATE if missing). Returns true if
--- at least one file was read.
function M.load()
    M.values = deepCopy(M.defaults)
    M.trains, M.trainNames = {}, {}
    local st = { tabletFontSet = false }
    local gotDefaults = readFile(M.defaultsPath(), st)
    if not gotDefaults then log("config: %s not found -- built-in defaults", M.defaultsPath()) end
    local gotUser = readFile(M.path(), st)
    if not gotUser then
        local f = io.open(M.path(), "w")
        if f then
            f:write(M.USER_TEMPLATE); f:close()
            log("config: created %s for your settings", M.path())
        else
            log("config: %s not found and cannot be created", M.path())
        end
    end
    -- Legacy: before M14 the font lived in [Screen].
    if not st.tabletFontSet then M.values.tablet.fontscale = M.values.screen.fontscale end
    local names = {}
    for _, n in pairs(M.trainNames) do table.insert(names, n) end
    table.sort(names)
    log("config: channel %s; train profiles: %s",
        M.values.twitch.channel ~= "" and ("#" .. M.values.twitch.channel) or "(not set)",
        #names > 0 and table.concat(names, ", ") or "none")
    return gotDefaults or gotUser
end

--- Short name of the key bound to `action` for on-screen hints and the log
--- ("NumPadZero" -> "Num0"), or "(off)" when the action has no key.
function M.keyLabel(action)
    local k = M.values.keys[action]
    if not k or k == "" then return "(off)" end
    local digits = { Zero = 0, One = 1, Two = 2, Three = 3, Four = 4, Five = 5, Six = 6, Seven = 7, Eight = 8, Nine = 9 }
    local d = k:match("^[Nn][Uu][Mm][Pp][Aa][Dd](%a+)$")
    if d and digits[d] then return "Num" .. digits[d] end
    local named = { Add = "Num+", Subtract = "Num-", Multiply = "Num*", Divide = "Num/", Decimal = "Num." }
    return named[k] or k
end

--- Settings for a train: [Tablet] (look only) with the [Train.<className>] keys
--- on top. Returns the table, the profile name ("Train.<class>" or "none") and
--- whether the profile has a position (X, Y and Z) -- without one the tablet is
--- placed in front of the eyes for the player to calibrate and save.
function M.tabletFor(className)
    local t = deepCopy(M.values.tablet)
    t.pitch, t.yaw, t.roll = 0, 0, 0
    local over = className and M.trains[className:lower()]
    if not over then return t, "none", false end
    for k, v in pairs(over) do t[k] = v end
    local hasPosition = over.x ~= nil and over.y ~= nil and over.z ~= nil
    return t, "Train." .. M.trainNames[className:lower()], hasPosition
end

local function formatValue(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then
        local s = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ".0")
        if s == "-0.0" then s = "0.0" end
        return s
    end
    return tostring(v)
end

-- Order for keys the file does not have yet (new sections especially).
local KEY_ORDER = { "x", "y", "z", "pitch", "yaw", "roll", "scale", "width", "height", "fontscale" }
local KEY_NAMES = { x = "X", y = "Y", z = "Z", pitch = "Pitch", yaw = "Yaw", roll = "Roll", scale = "Scale",
                    width = "Width", height = "Height", fontscale = "FontScale" }

local function orderedKeys(kv)
    local keys, seen = {}, {}
    for _, k in ipairs(KEY_ORDER) do
        if kv[k] ~= nil then table.insert(keys, k); seen[k] = true end
    end
    local rest = {}
    for k in pairs(kv) do if not seen[k] then table.insert(rest, k) end end
    table.sort(rest)
    for _, k in ipairs(rest) do table.insert(keys, k) end
    return keys
end

--- Writes `updates` into the file, changing only those values: comments, order
--- and other keys stay as the user wrote them. Missing keys are added to their
--- section; a missing section is appended.
---
---   updates = { ["tablet"] = { x = 1 }, ["train.cpy_kc1000tc_c"] = { x = 2 } }
---   (section names lower-case; `headers` gives the spelling for a section that
---   has to be created, e.g. { ["train.cpy_kc1000tc_c"] = "Train.Cpy_KC1000Tc_C" })
---
--- Safe write: the new text goes to <file>.tmp first; the old file becomes
--- <file>.bak; then .tmp takes the file's name. A crash in between leaves either
--- the old file or the .bak. Afterwards the file is read back (M.load), so the
--- values and profiles in memory match it. Returns true or nil, error.
function M.save(updates, headers)
    headers = headers or {}
    local path = M.path()
    local lines = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do table.insert(lines, (line:gsub("\r$", ""))) end
        f:close()
    end

    local pending = {}
    for sec, kv in pairs(updates) do
        pending[sec:lower()] = {}
        for k, v in pairs(kv) do pending[sec:lower()][k:lower()] = v end
    end

    local out, section, lastLineOf = {}, nil, {}
    for _, line in ipairs(lines) do
        local sec = line:match("^[ \t]*%[([%w_%.]+)%]")
        if sec then
            section = sec:lower()
        else
            local indent, key, rest = line:match("^([ \t]*)([%w_]+)([ \t]*=.*)$")
            local p = section and pending[section]
            if key and p and p[key:lower()] ~= nil then
                local comment = rest:match("([ \t]+[;#].*)$") or ""
                local eq = rest:match("^([ \t]*=[ \t]*)")
                line = indent .. key .. eq .. formatValue(p[key:lower()]) .. comment
                p[key:lower()] = nil
            end
        end
        table.insert(out, line)
        -- Remember where each section's last key/value line is, for additions.
        if section and not line:find("^[ \t]*$") and not line:find("^[ \t]*[;#]") then
            lastLineOf[section] = #out
        end
    end

    -- Keys missing from existing sections: insert from the bottom up, so one
    -- insertion does not shift the position of the next.
    local inserts, newSections = {}, {}
    for sec, kv in pairs(pending) do
        local keys = orderedKeys(kv)
        if #keys > 0 then
            local lines2 = {}
            for _, k in ipairs(keys) do
                table.insert(lines2, string.format("%s = %s", KEY_NAMES[k] or k, formatValue(kv[k])))
            end
            if lastLineOf[sec] then
                table.insert(inserts, { at = lastLineOf[sec], lines = lines2 })
            else
                table.insert(newSections, { header = headers[sec] or sec, lines = lines2 })
            end
        end
    end
    table.sort(inserts, function(a, b) return a.at > b.at end)
    for _, ins in ipairs(inserts) do
        for i, l in ipairs(ins.lines) do table.insert(out, ins.at + i, l) end
    end
    table.sort(newSections, function(a, b) return a.header < b.header end)
    for _, ns in ipairs(newSections) do
        table.insert(out, "")
        table.insert(out, "[" .. ns.header .. "]")
        for _, l in ipairs(ns.lines) do table.insert(out, l) end
    end

    local text = table.concat(out, "\n") .. "\n"
    local tmp, bak = path .. ".tmp", path .. ".bak"
    local tf, err = io.open(tmp, "w")
    if not tf then return nil, "cannot write " .. tmp .. ": " .. tostring(err) end
    tf:write(text)
    tf:close()
    os.remove(bak)
    if f then
        local ok, rerr = os.rename(path, bak)
        if not ok then os.remove(tmp); return nil, "cannot back up to " .. bak .. ": " .. tostring(rerr) end
    end
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        os.rename(bak, path)
        return nil, "cannot replace " .. path .. ": " .. tostring(rerr)
    end

    M.load()
    return true
end

--- The [Tablet] block for the given transform, ready to paste into the file.
function M.tabletBlock(t, header)
    return string.format(
        "[%s]\nX = %.1f\nY = %.1f\nZ = %.1f\nPitch = %.1f\nYaw = %.1f\nRoll = %.1f\nScale = %.2f\nWidth = %.1f\nHeight = %.1f\nFontScale = %.2f",
        header or "Train.<car class>", t.x, t.y, t.z, t.pitch, t.yaw, t.roll, t.scale, t.width, t.height,
        t.fontscale or M.values.tablet.fontscale)
end

return M
