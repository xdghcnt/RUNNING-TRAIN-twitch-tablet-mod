--[[
    Development reload: restart only this Lua mod without restarting the game.

    Triggers: key 0, or any watched .lua file changing on disk.

    Why not UE4SS's own systems (checked in RE-UE4SS 1c1a1497):
      * HotReloadKey reinstalls ALL mods, HeadTracking included.
      * EnableAutoReloadingLuaMods only watches <primary Mods dir>/<mod>/Scripts,
        not folders added with +ModsFolderPaths, which is how this mod is loaded.

    How the restart is made safe:
      1. On the game thread: run unload hooks (destroy spawned actors, stop loops),
         then ClearAllDelayedActions() so no game-thread work of ours is pending.
      2. From there, ExecuteAsync(RestartCurrentMod). RestartCurrentMod only QUEUES
         the reinstall to the UE4SS event-loop thread, which then stops and joins our
         async thread before destroying the Lua state -- so the state is never torn
         down under running Lua code. Calling it straight from a keybind callback
         would be wrong: keybinds run ON the event-loop thread, where the reinstall
         happens synchronously, inside the callback.

    Files are compiled with loadfile() before restarting; a syntax error is logged
    and the running version stays alive.

    C++ DLLs cannot be reloaded this way (UE4SS has no C++ mod reload).
]]

local U = require("tt.util")
local GT = require("tt.gamethread")
local log, try = U.log, U.try

local M = {}

local POLL_MS = 1500
-- A reload request right after the mod started is ignored: the fresh Lua state
-- is still starting up, and restarting it again would tear it down under
-- running code (seen in M8).
local STARTUP_GUARD_MS = 2000

local S = { unloadHooks = {}, files = {}, snapshot = nil, pendingSnapshot = nil, reloading = false, startedAt = U.nowMs() }

--- Extra non-Lua files whose change should also reload the mod (the config).
function M.watchFile(path)
    S.extraFiles = S.extraFiles or {}
    table.insert(S.extraFiles, path)
end

--- fn runs on the game thread right before the mod restarts.
function M.onUnload(name, fn)
    table.insert(S.unloadHooks, { name = name, fn = fn })
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

--- main.lua plus every tt.* module reachable through require("tt.x") in the
--- source text -- not package.loaded, so a module that failed to load is still
--- watched and fixing it triggers the reload.
local function watchedFiles()
    local files, seen, queue = {}, {}, {}
    if S.mainPath then
        table.insert(files, S.mainPath)
        table.insert(queue, S.mainPath)
    end
    while #queue > 0 do
        local src = readAll(table.remove(queue, 1)) or ""
        for name in src:gmatch('require%(%s*"(tt%.[%w_%.]+)"%s*%)') do
            if not seen[name] then
                seen[name] = true
                local path = package.searchpath(name, package.path)
                if path then
                    table.insert(files, path)
                    table.insert(queue, path)
                end
            end
        end
    end
    for _, path in ipairs(S.extraFiles or {}) do table.insert(files, path) end
    return files
end

local function takeSnapshot(files)
    local parts = {}
    for _, path in ipairs(files) do
        parts[#parts + 1] = path .. "\0" .. (readAll(path) or "<missing>")
    end
    return table.concat(parts, "\1")
end

local function compileAll(files)
    for _, path in ipairs(files) do
        if path:find("%.lua$") then
            local fn, err = loadfile(path)
            if not fn then return false, err end
        end
    end
    return true
end

--- Must run on the game thread.
local function reloadNow(reason)
    if S.reloading then return end
    if U.nowMs() - S.startedAt < STARTUP_GUARD_MS then
        log("dev reload (%s) ignored: the mod started less than %d ms ago", reason, STARTUP_GUARD_MS)
        return
    end
    local ok, err = compileAll(S.files)
    if not ok then
        log("dev reload (%s) SKIPPED, code does not compile: %s", reason, tostring(err))
        return
    end
    S.reloading = true
    log("dev reload (%s): unloading", reason)
    for _, h in ipairs(S.unloadHooks) do
        local hok, herr = pcall(h.fn)
        if not hok then log("dev reload: unload hook %s failed: %s", h.name, tostring(herr)) end
    end
    pcall(ClearAllDelayedActions)
    local qok, qerr = pcall(ExecuteAsync, function() RestartCurrentMod() end)
    if not qok then
        log("dev reload: could not queue restart: %s", tostring(qerr))
        S.reloading = false
    end
end

--- Game thread only (the reload key is polled there by tt/input.lua).
--- The mod itself just wrote a watched file (the config on Save): take the
--- current contents as the baseline so that write does not reload the mod.
function M.acknowledgeChanges()
    S.files = watchedFiles()
    S.snapshot = takeSnapshot(S.files)
    S.pendingSnapshot = nil
end

function M.request(reason)
    reloadNow(reason)
end

--- Game thread only (called from main.lua's delayed init, see there).
function M.start(mainPath)
    S.mainPath = mainPath
    do
        S.files = watchedFiles()
        S.snapshot = takeSnapshot(S.files)
        log("dev reload: watching %d files every %d ms (key 0 reloads by hand)", #S.files, POLL_MS)
        LoopInGameThreadWithDelay(POLL_MS, function()
            if S.reloading then return end
            local ok, err = pcall(function()
                local files = watchedFiles()
                local snap = takeSnapshot(files)
                if snap == S.snapshot then
                    S.pendingSnapshot = nil
                    return
                end
                -- Wait for the same content on two polls, so a file caught
                -- mid-write is not loaded.
                if snap ~= S.pendingSnapshot then
                    S.pendingSnapshot = snap
                    return
                end
                S.files = files
                S.snapshot = snap
                S.pendingSnapshot = nil
                reloadNow("file changed")
            end)
            if not ok then log("dev reload watcher error: %s", tostring(err)) end
        end)
    end
end

return M
