--[[
    ChatMessage + ChatModel.

    ChatMessage is the one internal message shape every source produces (fake
    chat now, Twitch later):

        { user = "nyanya", text = "hello", color = { R, G, B, A } or nil }

    ChatModel keeps the last N messages and a version counter; renderers redraw
    only when the version changed. No Unreal types in here.
]]

local M = {}

M.MAX_MESSAGES = 60

local S = { messages = {}, version = 0 }

-- Twitch's default name colours, used when a message carries none. The same
-- user always gets the same colour.
local PALETTE = {
    { R = 1.00, G = 0.00, B = 0.00 }, { R = 0.00, G = 0.00, B = 1.00 }, { R = 0.00, G = 0.50, B = 0.00 },
    { R = 0.70, G = 0.13, B = 0.13 }, { R = 1.00, G = 0.50, B = 0.31 }, { R = 0.60, G = 0.80, B = 0.20 },
    { R = 1.00, G = 0.27, B = 0.00 }, { R = 0.18, G = 0.55, B = 0.34 }, { R = 0.85, G = 0.65, B = 0.13 },
    { R = 0.82, G = 0.41, B = 0.12 }, { R = 0.37, G = 0.62, B = 0.63 }, { R = 0.12, G = 0.56, B = 1.00 },
    { R = 1.00, G = 0.41, B = 0.71 }, { R = 0.54, G = 0.17, B = 0.89 }, { R = 0.00, G = 1.00, B = 0.50 },
}

local function colorFor(user)
    local h = 0
    for i = 1, #user do h = (h * 31 + user:byte(i)) % 2147483647 end
    local c = PALETTE[h % #PALETTE + 1]
    -- Dark defaults (pure blue, dark green) are unreadable on a dark screen; lift them.
    local lum = 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
    local lift = lum < 0.35 and 0.35 or 0
    return { R = math.min(1, c.R + lift), G = math.min(1, c.G + lift), B = math.min(1, c.B + lift), A = 1 }
end

--- Valid UTF-8 in, valid UTF-8 out: invalid bytes become "?", control
--- characters become spaces. Every later stage (layout, Canvas) can then trust it.
local function clean(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local len = utf8.len(s, i, i)          -- nil if the byte at i does not start a valid sequence
        local cp = len and utf8.codepoint(s, i)
        if cp then
            local size = #utf8.char(cp)
            if s:sub(i, i + size - 1) == utf8.char(cp) then
                table.insert(out, cp < 32 and " " or utf8.char(cp))
                i = i + size
            else
                table.insert(out, "?"); i = i + 1
            end
        else
            table.insert(out, "?"); i = i + 1
        end
    end
    return table.concat(out)
end
M.clean = clean

--- Twitch "emotes" tag -> the text split into pieces: { text = "..." } and
--- { emote = "<id>", text = "Kappa" }. Positions in the tag are code points,
--- 0-based, inclusive. Nil when there are no emotes or the tag does not fit
--- the text (then the message is plain text, never cut wrongly).
function M.splitEmotes(tag, text)
    if type(tag) ~= "string" or tag == "" then return nil end
    local ranges = {}
    for id, spans in tag:gmatch("([%w_]+):([%d,%-]+)") do
        for a, b in spans:gmatch("(%d+)%-(%d+)") do
            table.insert(ranges, { first = tonumber(a) + 1, last = tonumber(b) + 1, id = id })
        end
    end
    if #ranges == 0 then return nil end
    table.sort(ranges, function(x, y) return x.first < y.first end)
    local n = utf8.len(text)
    if not n then return nil end
    local function sub(i, j)   -- code points i..j, 1-based inclusive
        local a = utf8.offset(text, i)
        local b = utf8.offset(text, j + 1)
        return text:sub(a, (b or #text + 1) - 1)
    end
    local pieces, at = {}, 1
    for _, r in ipairs(ranges) do
        if r.first < at or r.last < r.first or r.last > n then return nil end
        if r.first > at then table.insert(pieces, { text = sub(at, r.first - 1) }) end
        local code = sub(r.first, r.last)
        if code:find("[ \t]") then return nil end
        table.insert(pieces, { emote = r.id, text = code })
        at = r.last + 1
    end
    if at <= n then table.insert(pieces, { text = sub(at, n) }) end
    return pieces
end

function M.add(msg)
    if type(msg) ~= "table" or type(msg.user) ~= "string" or type(msg.text) ~= "string" then return false end
    local text = clean(msg.text)
    table.insert(S.messages, {
        user = clean(msg.user),
        text = text,
        color = msg.color or colorFor(msg.user),
        pieces = M.splitEmotes(msg.emotes, text),
    })
    while #S.messages > M.MAX_MESSAGES do table.remove(S.messages, 1) end
    S.version = S.version + 1
    return true
end

function M.version() return S.version end

--- Oldest first. Read-only for callers.
function M.messages() return S.messages end

function M.clear()
    S.messages = {}
    S.version = S.version + 1
end

return M
