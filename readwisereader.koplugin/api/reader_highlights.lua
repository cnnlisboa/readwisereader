-- Reader v3 highlight placement. Transport stays with main.lua's callAPI, the
-- same way api/reader.lua defers to it.
--
-- Reader creates a highlight as a child document: POST /save/ with parent_id
-- and the passage as content. Reader finds the passage in the parent's text
-- and anchors the highlight there, returning 400 (and creating nothing) when
-- it cannot. Readwise then picks the highlight up from Reader on its own, so a
-- placed highlight must never also be sent through the v2 exporter, or it
-- would appear twice.
--
-- PATCH /update/<id>/ accepts only notes and tags on a highlight, so a note
-- edited in KOReader can follow the highlight but an edited passage cannot.
-- Deletions are deliberately never sent.
local Highlights = require("api/highlights")

local ReaderHighlights = {}
ReaderHighlights.__index = ReaderHighlights

local function stringOrNil(value)
    return type(value) == "string" and value ~= "" and value or nil
end

-- Reader matches content against the parent's HTML text, so the plain passage
-- is escaped to the HTML it renders from. Entities decode back to the same
-- characters, which keeps an "&" or "<" in the passage from breaking the match.
local function escapeHtml(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function ReaderHighlights:new(options)
    assert(type(options) == "table" and type(options.request) == "function",
        "ReaderHighlights request adapter required")
    return setmetatable({ request = options.request }, self)
end

-- Only highlights made at or after `since` are placed in Reader. Older ones may
-- already be in Readwise through v2, and placing them too would duplicate them
-- there. A highlight without a creation time cannot be dated, so it stays on v2.
function ReaderHighlights.isEligible(clipping, since)
    return stringOrNil(clipping.text) ~= nil
        and type(since) == "number"
        and type(clipping.time) == "number"
        and clipping.time >= since
        and Highlights.annotationKey(clipping) ~= nil
end

-- Whether the v2 exporter should still send this clipping. Eligible highlights
-- belong to Reader unless Reader already refused their passage; a failed
-- placement is retried next sync rather than handed to v2, which would leave a
-- duplicate behind once the retry succeeds.
function ReaderHighlights.sendsToV2(clipping, records, since)
    if not ReaderHighlights.isEligible(clipping, since) then
        return true
    end
    local record = records and records[Highlights.annotationKey(clipping)]
    return record ~= nil and record.fallback == true
end

-- `records` maps annotation key to what happened to that highlight:
--   { id = <reader id>, note = <note last sent> }  placed in Reader
--   { fallback = true }   Reader could not find the passage; v2 owns it
--   { gone = true }       deleted in Reader; left alone from then on
-- It is updated in place, so the caller only has to persist it.
--
-- Returns { placed, updated, unplaced, failures = { { book, message } } }.
function ReaderHighlights:exportBook(document_id, title, booknotes, records, since)
    local report = { placed = 0, updated = 0, unplaced = 0, failures = {} }
    for _, chapter in ipairs(booknotes) do
        for _, clipping in ipairs(chapter) do
            if ReaderHighlights.isEligible(clipping, since) then
                self:exportOne(document_id, title, clipping, records, report)
            end
        end
    end
    return report
end

function ReaderHighlights:exportOne(document_id, title, clipping, records, report)
    local key = Highlights.annotationKey(clipping)
    local record = records[key]
    local note = stringOrNil(clipping.note) or ""

    if record == nil then
        local result, err, code = self.request("POST", "/save/", {
            parent_id = document_id,
            content = escapeHtml(clipping.text),
            notes = note ~= "" and note or nil,
            saved_using = "koreader",
        })
        if result then
            records[key] = {
                id = type(result) == "table" and stringOrNil(result.id) or nil,
                note = note,
            }
            report.placed = report.placed + 1
        elseif code == 400 then
            records[key] = { fallback = true }
            report.unplaced = report.unplaced + 1
        else
            table.insert(report.failures, {
                book = title,
                message = "could not place highlight in Reader (" .. tostring(code or err) .. ")",
            })
        end
        return
    end

    -- A placement whose response carried no id cannot be updated, but it is
    -- still placed, so it is never re-created.
    if not record.id or record.fallback or record.gone or record.note == note then
        return
    end

    local result, err, code = self.request("PATCH", "/update/" .. record.id .. "/", { notes = note })
    if result then
        record.note = note
        report.updated = report.updated + 1
    elseif code == 404 then
        record.gone = true
    else
        table.insert(report.failures, {
            book = title,
            message = "could not update highlight note in Reader (" .. tostring(code or err) .. ")",
        })
    end
end

return ReaderHighlights
