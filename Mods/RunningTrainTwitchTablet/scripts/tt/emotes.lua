--[[
    Twitch emotes (native ones, from the IRC "emotes" tag).

      1. ChatModel keeps each message's tag; the renderer asks M.get(id) for
         every emote it lays out. The first ask queues a download in the C++
         mod (RTTT_EmoteRequest) into <mod>\emotecache\<id>.png -- a cache that
         survives restarts.
      2. M.tick() (game thread, from the tablet's redraw loop) polls the
         downloads. A ready file is imported with
         KismetRenderingLibrary:ImportFileAsTexture2D and drawn at once into one
         slot of the atlas: a render target owned by the tablet.
      3. The renderer draws the slot. Until then the emote shows as its text.

    Why the atlas: a texture created at runtime is referenced by no UPROPERTY,
    so Unreal's GC may free it at any moment -- M6 crashed on exactly that with a
    render target. The atlas is set on a hidden material of the tablet (the same
    way the screen keeps its render target alive); imported textures are used
    for one draw only and then forgotten.

    Slots are composited over the chat background and drawn opaque, so no alpha
    has to survive the round trip through the atlas. The brightness setting is
    applied when a slot is drawn to the screen, not when it is stored.

    Animated emotes show their first frame ("static" on Twitch's CDN).
]]

local U = require("tt.util")
local log, try, isValid = U.log, U.try, U.isValid

local M = {}

M.SLOT = 128          -- px per atlas slot (Twitch's 3.0 images are up to 112 px)
M.ATLAS = 2048        -- 16 x 16 = 256 slots
local LOADS_PER_TICK = 4
local POLL_EVERY_MS = 250

local S = {
    enabled = true,
    known = {},        -- id -> { state = "pending" | "file" | "loaded" | "failed", slot, u, v, uw, vh, aspect }
    order = {},        -- ids in slot order, for eviction when the atlas is full
    nextSlot = 0,
    atlas = nil,       -- tt.dyntexture surface, owned by the tablet
    background = nil,
    version = 0,       -- bumped whenever a slot becomes drawable
    nextPoll = 0,
    cacheDir = nil,
    importFailures = 0,
}

local function available()
    return S.enabled and RTTT_EmoteRequest ~= nil and S.cacheDir ~= nil
end

function M.configure(enabled, cacheDir)
    S.enabled = enabled and true or false
    S.cacheDir = cacheDir
end

function M.version() return S.version end

local function path(id) return S.cacheDir .. "\\" .. id .. ".png" end

--- Width / height from the PNG header (IHDR), or nil.
local function pngSize(file)
    local f = io.open(file, "rb")
    if not f then return nil end
    local head = f:read(24)
    f:close()
    if not head or #head < 24 or head:sub(2, 4) ~= "PNG" then return nil end
    local w = string.unpack(">I4", head, 17)
    local h = string.unpack(">I4", head, 21)
    if w < 1 or h < 1 or w > 4096 or h > 4096 then return nil end
    return w, h
end

--- The renderer's question: is this emote drawable? Returns the entry (with
--- u, v, uw, vh in atlas UV and aspect = width / height) or nil. The first ask
--- starts the download.
function M.get(id)
    if not available() then return nil end
    local e = S.known[id]
    if not e then
        e = { state = "pending" }
        S.known[id] = e
        local ok, st = pcall(RTTT_EmoteRequest, id, path(id))
        if not ok or st == "failed" then e.state = "failed"
        elseif st == "ready" then e.state = "file" end
    end
    if e.state == "loaded" and S.atlas then return e end
    return nil
end

--------------------------------------------------------------------------------
-- atlas (game thread)
--------------------------------------------------------------------------------

--- The tablet made a new atlas surface (spawn) or lost it (nil). Slots of the
--- old one are gone: every loaded emote goes back to "file" and is redrawn.
function M.attach(surface, background)
    S.atlas, S.background = surface, background
    S.nextSlot, S.order = 0, {}
    for _, e in pairs(S.known) do
        if e.state == "loaded" then e.state = "file"; e.slot = nil end
    end
    S.version = S.version + 1
end

local function freeSlot()
    local perRow = math.floor(M.ATLAS / M.SLOT)
    local total = perRow * perRow
    if S.nextSlot >= total then
        -- Full: start over. Emotes on screen come back from the disk cache.
        log("emotes: atlas full (%d), starting over", total)
        for _, id in ipairs(S.order) do
            local e = S.known[id]
            if e and e.state == "loaded" then e.state = "file"; e.slot = nil end
        end
        S.order, S.nextSlot = {}, 0
    end
    local slot = S.nextSlot
    S.nextSlot = slot + 1
    return (slot % perRow) * M.SLOT, math.floor(slot / perRow) * M.SLOT, slot
end

local function importAndStore(Dyn, lib, id, e)
    local file = path(id)
    local w, h = pngSize(file)
    if not w then e.state = "failed"; return false end
    local tex = try(function() return lib:ImportFileAsTexture2D(S.atlas.world, file) end)
    if not isValid(tex) then
        e.state = "failed"
        S.importFailures = S.importFailures + 1
        if S.importFailures <= 3 then log("emotes: ImportFileAsTexture2D failed for %s", file) end
        return false
    end
    local x, y, slot = freeSlot()
    -- Fit into the slot, keeping the aspect ratio; centred vertically is not
    -- needed: the renderer uses exactly the drawn rectangle.
    local scale = math.min(M.SLOT / w, M.SLOT / h)
    local dw, dh = math.floor(w * scale), math.floor(h * scale)
    local ok, err = pcall(Dyn.paintInto, S.atlas, function(d)
        d:rect(x, y, dw, dh, S.background)
        d:image(tex, x, y, dw, dh, 0, 0, 1, 1, { R = 1, G = 1, B = 1, A = 1 }, 2)
    end)
    if not ok then
        e.state = "failed"
        log("emotes: drawing %s into the atlas failed: %s", id, tostring(err))
        return false
    end
    e.state, e.slot = "loaded", slot
    e.u, e.v, e.uw, e.vh = x / M.ATLAS, y / M.ATLAS, dw / M.ATLAS, dh / M.ATLAS
    e.aspect = dw / dh
    table.insert(S.order, id)
    return true
end

--- Polls downloads and moves finished ones into the atlas. Returns true if
--- anything new became drawable (the chat should be redrawn).
function M.tick(Dyn)
    if not (available() and S.atlas) then return false end
    local now = U.nowMs()
    if now < S.nextPoll then return false end
    S.nextPoll = now + POLL_EVERY_MS
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not isValid(lib) then return false end
    local loaded = 0
    for id, e in pairs(S.known) do
        if loaded >= LOADS_PER_TICK then break end
        if e.state == "pending" then
            local ok, st = pcall(RTTT_EmoteRequest, id, path(id))
            if not ok or st == "failed" then e.state = "failed"
            elseif st == "ready" then e.state = "file" end
        end
        if e.state == "file" then
            if importAndStore(Dyn, lib, id, e) then loaded = loaded + 1 end
        end
    end
    if loaded > 0 then S.version = S.version + 1 end
    return loaded > 0
end

--- The atlas render target, for the renderer (valid while M.get returns entries).
function M.atlasTexture() return S.atlas and S.atlas.rt end

--- One line for the status log.
function M.status()
    local counts = { pending = 0, file = 0, loaded = 0, failed = 0 }
    for _, e in pairs(S.known) do counts[e.state] = (counts[e.state] or 0) + 1 end
    local native = ""
    if RTTT_EmoteStats ~= nil then
        local ok, dl, failed, cached, queued, lastErr = pcall(RTTT_EmoteStats)
        if ok then
            native = string.format(" | downloads %s ok, %s failed, %s from cache, %s queued%s", tostring(dl),
                tostring(failed), tostring(cached), tostring(queued),
                (lastErr and lastErr ~= "") and (" (last error: " .. lastErr .. ")") or "")
        end
    end
    return string.format("emotes: %s | %d on screen-ready, %d loading, %d failed%s",
        available() and "on" or (S.enabled and "off (native mod 1.0+ needed)" or "off (config)"),
        counts.loaded, counts.pending + counts.file, counts.failed, native)
end

return M
