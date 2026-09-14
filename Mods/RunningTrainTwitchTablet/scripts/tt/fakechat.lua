--[[
    Fake chat source (Milestone 7): produces ChatMessages exactly like the Twitch
    client will later, so the renderer can be finished without the network.
]]

local ChatModel = require("tt.chatmodel")

local M = {}

-- Neutral placeholder text. Still covers what the renderer must handle: short
-- lines, word wrap over several lines, and a word too long for one line.
local SEED = {
    { "lorem", "Lorem ipsum dolor sit amet." },
    { "consectetur", "Sed do eiusmod tempor." },
}

local USERS = { "lorem", "ipsum", "dolor_sit", "amet", "consectetur", "adipiscing", "elit_sed", "tempor42" }

local TEXTS = {
    "Lorem ipsum",
    "dolor sit amet",
    "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
    "Duis aute irure dolor",
    "Excepteur_sint_occaecat_cupidatat_non_proident_sunt_in_culpa_qui_officia_deserunt",
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "magna aliqua",
    "Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit.",
}

local n = 0

function M.seed()
    for _, m in ipairs(SEED) do ChatModel.add({ user = m[1], text = m[2] }) end
end

--- Adds one message, cycling through users and texts.
function M.addOne()
    n = n + 1
    local user = USERS[(n * 7) % #USERS + 1]
    local text = TEXTS[(n * 5) % #TEXTS + 1]
    ChatModel.add({ user = user, text = text })
    return user, text
end

return M
