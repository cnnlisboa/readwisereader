-- Crash-safe bookkeeping for the highlight export, kept in its own small
-- settings file (readwisereader_export.lua) beside the main one.
--
-- The export used to save what it had placed in Reader only after every book
-- was done. Closing KOReader halfway lost that, and the next export placed
-- the same highlights in Reader again. Now:
--
--   * Before each placement an in-flight marker is written. If KOReader stops
--     during the request, the next export asks Reader whether the highlight
--     arrived (reconcile) instead of placing it blind.
--   * After each request the export's state (ledger, Reader records) is
--     written here. Every plugin instance merges it on start, so the state
--     survives whichever instance happens to be on screen when the export
--     ends, and an instance that saves older state can't lose it.
--
-- Pure: the caller reads and writes the file.
local Journal = {}

-- The export-owned state from `plugin` into a journal table.
function Journal.snapshot(plugin, inflight)
    return {
        ledger = plugin.highlight_ledger,
        records = plugin.reader_highlight_records,
        ledger_migrated = plugin.highlight_ledger_migrated,
        deletions_checked_at = plugin.highlight_deletions_checked_at,
        parsed_at = plugin.highlights_parsed_at,
        inflight = inflight or {},
    }
end

local function laterString(a, b)
    if type(a) ~= "string" then return b end
    if type(b) ~= "string" then return a end
    return a >= b and a or b
end

-- Folds a journal into the plugin's state. The journal is newer for anything
-- it holds; the plugin keeps entries the journal doesn't have, and a ledger
-- state or v2 id another path added (tags, deletions) survives.
function Journal.merge(plugin, journal)
    if type(journal) ~= "table" then return false end
    local changed = false
    if type(journal.ledger) == "table" then
        plugin.highlight_ledger = plugin.highlight_ledger or {}
        local ledger = plugin.highlight_ledger
        for key, entry in pairs(journal.ledger) do
            local mine = ledger[key]
            local merged = {}
            for field, value in pairs(entry) do merged[field] = value end
            if type(mine) == "table" then
                if mine.state and not merged.state then
                    merged.state = mine.state
                    merged.deleted_at = mine.deleted_at
                end
                if mine.v2_id and not merged.v2_id then merged.v2_id = mine.v2_id end
            end
            ledger[key] = merged
            changed = true
        end
    end
    if type(journal.records) == "table" then
        plugin.reader_highlight_records = plugin.reader_highlight_records or {}
        for doc_id, records in pairs(journal.records) do
            local mine = plugin.reader_highlight_records[doc_id] or {}
            for key, record in pairs(records) do
                mine[key] = record
                changed = true
            end
            plugin.reader_highlight_records[doc_id] = mine
        end
    end
    if journal.ledger_migrated and not plugin.highlight_ledger_migrated then
        plugin.highlight_ledger_migrated = true
        changed = true
    end
    local checked = laterString(plugin.highlight_deletions_checked_at, journal.deletions_checked_at)
    if checked ~= plugin.highlight_deletions_checked_at then
        plugin.highlight_deletions_checked_at = checked
        changed = true
    end
    return changed
end

function Journal.inflightKey(doc_id, key)
    return doc_id .. "\0" .. key
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

-- Reader content to comparable text: tags and entities out, whitespace
-- folded. Placements send escaped plain text, which Reader may wrap.
function Journal.normalize(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("<[^>]*>", " ")
    text = text:gsub("&(#?%w+);", function(name)
        if name:sub(1, 1) == "#" then
            local code = tonumber(name:sub(2))
            return code and code < 128 and string.char(code) or " "
        end
        return ENTITIES[name] or ("&" .. name .. ";")
    end)
    text = text:gsub("%s+", " ")
    return (text:gsub("^ ", ""):gsub(" $", ""))
end

-- In-flight placements that did reach Reader: recorded in `records_by_doc`
-- from `remote` (Reader highlight documents: { id, parent_id, content,
-- notes }). Returns the number found. Markers are not cleared here.
function Journal.reconcile(records_by_doc, inflight, remote)
    local found = 0
    for _, marker in pairs(inflight or {}) do
        local want = Journal.normalize(marker.text)
        for _, doc in ipairs(remote or {}) do
            if doc.parent_id == marker.doc and want ~= ""
                and Journal.normalize(doc.content) == want then
                records_by_doc[marker.doc] = records_by_doc[marker.doc] or {}
                records_by_doc[marker.doc][marker.key] = { id = doc.id, note = marker.note or "" }
                found = found + 1
                break
            end
        end
    end
    return found
end

return Journal
