-- Cleanup for the Reader-document note line older versions wrote as a
-- progress workaround ("KOReader progress: N% <!-- koreader-progress -->"),
-- before Reader's API accepted reading_progress. The unique HTML marker lets
-- us remove only our own line while preserving the rest of the user's note.
local ProgressNote = {}

local MARKER = "<!-- koreader-progress -->"

function ProgressNote.remove(notes)
    notes = type(notes) == "string" and notes or ""
    -- The marker is generated only by this plugin. Remove its entire line and
    -- one adjacent newline so removal does not leave a blank paragraph.
    local updated, removed = notes:gsub("[^\r\n]*<!%-%- koreader%-progress %-%->[^\r\n]*[\r]?\n?", "")
    return updated, removed > 0
end

ProgressNote.MARKER = MARKER

return ProgressNote
