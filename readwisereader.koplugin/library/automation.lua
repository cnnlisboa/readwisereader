-- Automatic / Ask / Manual modes for every automatic action (PLAN D.0).
--
--   auto    runs at its trigger
--   ask     asks at its trigger; "No" skips it this time
--   manual  never runs at its trigger, only from its own menu action
--
-- Pure: main.lua shows the dialogs and runs the work.
local Automation = {}

Automation.MODES = { "auto", "ask", "manual" }
Automation.MODE_LABELS = { auto = "Automatic", ask = "Ask", manual = "Manual" }

-- Order is the menu order.
Automation.ACTIONS = {
    { id = "pull_progress",   label = "Pull reading position when opening a book", default = "auto" },
    { id = "push_progress",   label = "Push reading position when closing / sleeping", default = "auto" },
    { id = "books_open",      label = "Mark as reading in Readwise Books when opening", default = "auto" },
    { id = "books_reread",    label = "Start a re-read when opening a finished book", default = "ask" },
    { id = "books_status",    label = "Send status and rating to Readwise Books", default = "auto" },
    { id = "books_remote",    label = "Apply Readwise Books shelf changes to the device", default = "auto" },
    { id = "download_books",  label = "Download books from Readwise at sync", default = "auto" },
    { id = "send_highlights", label = "Send highlights at sync", default = "auto" },
    { id = "highlight_tags",  label = "Apply highlight tags at sync", default = "auto" },
    { id = "chapter_headings", label = "Export chapter headings at sync", default = "auto" },
    { id = "sessions",        label = "Post reading sessions", default = "auto" },
    { id = "archive_finished", label = "Archive and delete finished documents at sync", default = "auto" },
    { id = "upload_epubs",    label = "Upload sideloaded EPUBs to Readwise", default = "ask" },
}

local BY_ID = {}
for _, action in ipairs(Automation.ACTIONS) do BY_ID[action.id] = action end

local VALID = { auto = true, ask = true, manual = true }

function Automation.action(id)
    return BY_ID[id]
end

function Automation.mode(modes, id)
    local value = type(modes) == "table" and modes[id] or nil
    if VALID[value] then return value end
    local action = BY_ID[id]
    return action and action.default or "manual"
end

-- What to do at an automatic trigger: "run", "ask" or "skip".
-- A manual trigger (the action's own menu entry) always runs.
function Automation.decide(modes, id, trigger)
    if trigger == "manual" then return "run" end
    local mode = Automation.mode(modes, id)
    if mode == "auto" then return "run" end
    if mode == "ask" then return "ask" end
    return "skip"
end

-- Older boolean settings become modes once, so upgrading keeps behaviour:
-- archive_finished=false and export_highlights_at_sync=false were "only from
-- the Advanced sync menu", which is Manual.
function Automation.migrate(modes, legacy)
    modes = type(modes) == "table" and modes or {}
    legacy = legacy or {}
    if modes.archive_finished == nil and legacy.archive_finished ~= nil then
        modes.archive_finished = legacy.archive_finished and "auto" or "manual"
    end
    if modes.send_highlights == nil and legacy.export_highlights_at_sync ~= nil then
        modes.send_highlights = legacy.export_highlights_at_sync and "auto" or "manual"
    end
    return modes
end

return Automation
