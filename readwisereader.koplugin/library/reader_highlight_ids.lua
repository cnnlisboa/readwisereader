-- Reader highlight ids kept on KOReader's own annotations.
--
-- When this plugin places a highlight in a Reader document it writes the new
-- Reader id onto the annotation (field READER_ID_FIELD). Device Sync copies
-- annotations between readers field for field, so the other reader receives
-- the id with the highlight and adopts it instead of placing a second copy.
--
-- `records` is the per-document table from reader_highlights.lua:
-- annotation key -> { id, note } | { fallback = true } | { gone = true }.
local ReaderHighlightIds = {}

ReaderHighlightIds.READER_ID_FIELD = "readwise_reader_id"

local function nonEmpty(value)
    return type(value) == "string" and value ~= "" and value or nil
end

-- Annotations carrying an id this reader has no record of become placed
-- records, so they are never sent again. Returns how many were adopted.
function ReaderHighlightIds.adopt(annotations, records, key_for)
    local adopted = 0
    for _, annotation in ipairs(annotations or {}) do
        local id = type(annotation) == "table" and nonEmpty(annotation[ReaderHighlightIds.READER_ID_FIELD])
        local key = id and key_for(annotation)
        if key and records[key] == nil then
            records[key] = { id = id, note = annotation.note or "" }
            adopted = adopted + 1
        end
    end
    return adopted
end

-- Writes placed ids onto annotations that lack them. Returns how many changed.
function ReaderHighlightIds.stamp(annotations, records, key_for)
    local changed = 0
    for _, annotation in ipairs(annotations or {}) do
        if type(annotation) == "table" and not nonEmpty(annotation[ReaderHighlightIds.READER_ID_FIELD]) then
            local key = key_for(annotation)
            local record = key and records[key]
            if record and nonEmpty(record.id) and not record.gone and not record.fallback then
                annotation[ReaderHighlightIds.READER_ID_FIELD] = record.id
                changed = changed + 1
            end
        end
    end
    return changed
end

return ReaderHighlightIds
