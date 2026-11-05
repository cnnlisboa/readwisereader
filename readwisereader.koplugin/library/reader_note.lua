-- Merge policy for editing a Reader document note from KOReader.
--
-- Reader's UPDATE replaces the whole note, so every edit remembers the note
-- it started from (`base`). When the note is saved, Reader's current note
-- (`remote`) decides what is sent:
--   * unchanged since the edit began: the edited text replaces it;
--   * changed meanwhile: both are kept. If the edit only added text at the
--     end, just that addition is appended; otherwise the whole edited note
--     is appended under a "From KOReader" line.
-- A nil base means the starting note is unknown (edited offline with no
-- saved copy), so the edit is only ever added to the end.
--
-- Pure: no KOReader requires, no transport.
local ReaderNote = {}

ReaderNote.SEPARATOR = "From KOReader:"

local function text(value)
    return type(value) == "string" and value or ""
end

local function trimEnd(value)
    return (value:gsub("%s+$", ""))
end

local function trimStart(value)
    return (value:gsub("^%s+", ""))
end

-- Adds `addition` after `notes` with one blank line between them.
function ReaderNote.append(notes, addition)
    notes, addition = trimEnd(text(notes)), trimStart(trimEnd(text(addition)))
    if addition == "" then
        return notes
    end
    if notes == "" then
        return addition
    end
    return notes .. "\n\n" .. addition
end

-- Text to send so the edit and any change made in Reader both survive.
function ReaderNote.merge(base, remote, edited)
    remote, edited = text(remote), text(edited)
    if trimEnd(edited) == "" then
        return remote
    end
    if base ~= nil then
        base = text(base)
        if base ~= "" and edited:sub(1, #base) == base then
            return ReaderNote.append(remote, edited:sub(#base + 1))
        end
        if base == "" then
            return ReaderNote.append(remote, edited)
        end
    end
    if trimEnd(remote) == "" then
        return trimEnd(edited)
    end
    return ReaderNote.append(remote, ReaderNote.SEPARATOR .. "\n" .. trimStart(edited))
end

-- Decide what saving an edit does.
-- Returns { action = "none" }            nothing to send
--         { action = "send", text = ... } send this text
--         { action = "conflict", merged = ... } Reader changed meanwhile;
--             `merged` keeps both, for when nobody can be asked.
function ReaderNote.resolve(base, remote, edited)
    remote, edited = text(remote), text(edited)
    if remote == edited then
        return { action = "none" }
    end
    if base ~= nil and text(base) == edited then
        return { action = "none" }
    end
    if base == nil and trimEnd(edited) == "" then
        -- Nothing written from an unknown starting note: never clear Reader's.
        return { action = "none" }
    end
    if base ~= nil and text(base) == remote then
        return { action = "send", text = edited }
    end
    if base == nil and trimEnd(remote) == "" then
        return { action = "send", text = trimEnd(edited) }
    end
    return { action = "conflict", merged = ReaderNote.merge(base, remote, edited) }
end

return ReaderNote
