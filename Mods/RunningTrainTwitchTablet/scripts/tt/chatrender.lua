--[[
    ChatRenderer: ChatModel -> lines -> Canvas draw calls.

    Knows nothing about where messages come from. Layout:
      * "user: text" per message, user name in its colour, text in white;
      * word wrap to the screen width, over-long words broken by characters;
      * newest message at the bottom, older ones pushed up and cut at the top
        (that is the scroll);
      * optional scrollback offset in lines, for later manual scrolling.

    Widths come from Canvas:K2_TextSize, measured once per character and cached,
    so a redraw costs one measurement per new character, not per word. Kerning
    is 0 in the draw call, so per-character sums match what is drawn.
]]

local Emotes = require("tt.emotes")

local M = {}

M.STYLE = {
    -- 1.6 read too small in game; the user settled on 2.97 with keys 5 / 6 (M7).
    -- Overwritten from [Screen] FontScale at load (M10).
    scale = 3.0,
    minScale = 1.0,
    maxScale = 12.0,
    padding = 28,
    lineGap = 6,
    -- Dark blue-grey 0.015/0.015/0.03 read like a washed-out old TFT; pure black
    -- merged with the near-black body. With the body lifted to grey, the user
    -- asked for the screen darker again than 0.007.
    background = { R = 0.002, G = 0.002, B = 0.0025, A = 1 },
    textColor = { R = 0.92, G = 0.92, B = 0.95, A = 1 },
}

local widthCache = {}      -- [scale][char] = px
local lineHeightCache = {} -- [scale] = px

local function charWidth(d, ch, scale)
    local cache = widthCache[scale]
    if not cache then cache = {}; widthCache[scale] = cache end
    local w = cache[ch]
    if w == nil then
        w = d:textSize(ch, scale).X
        cache[ch] = w
    end
    return w
end

local function lineHeight(d, scale)
    local h = lineHeightCache[scale]
    if not h then
        h = d:textSize("Ag\u{419}\u{3042}", scale).Y
        lineHeightCache[scale] = h
    end
    return h
end

local function width(d, s, scale)
    local w = 0
    for _, cp in utf8.codes(s) do w = w + charWidth(d, utf8.char(cp), scale) end
    return w
end

--- Splits text into words and single spaces so wrapping keeps spacing.
--- ASCII whitespace only: Lua's %s follows the C runtime's isspace(), which on
--- Windows also matches bytes like 0xA0 -- the second byte of Cyrillic "P"
--- (D0 A0) -- and cut characters in half.
local function tokens(text)
    local out = {}
    for space, word in text:gmatch("([ \t\r\n]*)([^ \t\r\n]+)") do
        if space ~= "" then table.insert(out, " ") end
        table.insert(out, word)
    end
    return out
end

--- Wraps one message into lines. Each line is a list of segments
--- { text, color }; the first line starts with the coloured user name.
local function wrapMessage(d, msg, maxWidth, style)
    local scale = style.scale
    local lines, cur, curW = {}, {}, 0

    local function push(text, color, w)
        local last = cur[#cur]
        if last and last.color == color and not last.emote then
            last.text = last.text .. text
            last.w = last.w + w
        else
            table.insert(cur, { text = text, color = color, w = w })
        end
        curW = curW + w
    end
    local emoteH = lineHeight(d, scale)
    local function newline()
        table.insert(lines, cur)
        cur, curW = {}, 0
    end

    local prefix = msg.user .. ": "
    push(prefix, msg.color, width(d, prefix, scale))

    -- Words and emotes in order. An emote whose image is not ready yet is just
    -- its word, like before emotes existed.
    local items = {}
    for _, piece in ipairs(msg.pieces or { { text = msg.text } }) do
        local e = piece.emote and Emotes.get(piece.emote)
        if e then
            table.insert(items, { emote = e, text = piece.text })
        else
            for _, tok in ipairs(tokens(piece.text)) do table.insert(items, tok) end
        end
    end

    for _, item in ipairs(items) do
        local tok = item
        if type(item) == "table" then
            local w = emoteH * item.emote.aspect
            if curW + w > maxWidth and curW > 0 then newline() end
            table.insert(cur, { emote = item.emote, text = item.text, w = w, h = emoteH })
            curW = curW + w
            goto continue
        end
        local w = width(d, tok, scale)
        if tok == " " then
            if curW > 0 and curW + w <= maxWidth then push(tok, style.textColor, w) end
        elseif curW + w <= maxWidth then
            push(tok, style.textColor, w)
        elseif w <= maxWidth then
            newline()
            push(tok, style.textColor, w)
        else
            -- A word wider than the screen: break it by characters.
            for _, cp in utf8.codes(tok) do
                local ch = utf8.char(cp)
                local cw = charWidth(d, ch, scale)
                if curW + cw > maxWidth and curW > 0 then newline() end
                push(ch, style.textColor, cw)
            end
        end
        ::continue::
    end
    if #cur > 0 then newline() end
    return lines
end

--- Paints the chat. `d` is a tt.dyntexture draw context.
function M.paint(d, messages, W, H, scrollLines)
    local style = M.STYLE
    local lh = lineHeight(d, style.scale) + style.lineGap
    local maxWidth = W - 2 * style.padding

    -- Wrap from the newest message back until the screen (plus scrollback) is full.
    local needed = math.floor((H - 2 * style.padding) / lh) + (scrollLines or 0)
    local lines = {}
    for i = #messages, 1, -1 do
        local wrapped = wrapMessage(d, messages[i], maxWidth, style)
        for j = #wrapped, 1, -1 do table.insert(lines, 1, wrapped[j]) end
        if #lines >= needed then break end
    end

    -- Bottom-aligned: the last line sits at the bottom padding.
    local y = H - style.padding - lh
    local skip = scrollLines or 0
    for i = #lines, 1, -1 do
        if skip > 0 then
            skip = skip - 1
        else
            if y < style.padding - 1 then break end
            local x = style.padding
            for _, seg in ipairs(lines[i]) do
                if seg.emote then
                    local e = seg.emote
                    d:image(Emotes.atlasTexture(), x, y, seg.w, seg.h, e.u, e.v, e.uw, e.vh,
                            { R = 1, G = 1, B = 1, A = 1 }, 0)
                else
                    d:text(x, y, seg.text, style.scale, seg.color)
                end
                x = x + seg.w
            end
            y = y - lh
        end
    end
end

--- Multiplies the font scale, clamped; returns the new scale. Rounded so the
--- width cache (keyed by scale) does not collect near-duplicate entries.
function M.changeScale(factor)
    local s = M.STYLE
    s.scale = math.floor(math.max(s.minScale, math.min(s.maxScale, s.scale * factor)) * 100 + 0.5) / 100
    return s.scale
end

--- Diagnostics for the log.
function M.cacheStats()
    local n = 0
    for _, c in pairs(widthCache) do for _ in pairs(c) do n = n + 1 end end
    return n
end

return M
