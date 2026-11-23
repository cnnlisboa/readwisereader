-- What this device has already sent to Readwise, per highlight (PLAN D.6).
--
-- Without it every sync re-sent every highlight, and Readwise recreates a
-- highlight it had deleted when it is sent again (tested 2026-11-23). With it
-- a highlight is sent only when it is new or its text/note changed here, and
-- never again once Readwise deleted it or a rule processed it.
--
-- ledger[key] = { hash = <text+note fingerprint>, sent_at = epoch,
--                 state = nil | "deleted_remotely" | "processed" }
local Ledger = {}

local function shortHash(value)
    local hash = 5381
    for index = 1, #value do
        hash = (hash * 33 + value:byte(index)) % 0x7FFFFFFF
    end
    return string.format("%08x", hash)
end
Ledger.shortHash = shortHash

-- annotation_key: Highlights.annotationKey(clipping) when there is one;
-- otherwise the book title and text identify it (Kindle My Clippings).
function Ledger.keyFor(annotation_key, title, text)
    if annotation_key then return annotation_key end
    if type(text) ~= "string" or text == "" then return nil end
    return "t" .. shortHash((title or "") .. "\0" .. text)
end

function Ledger.hashFor(text, note)
    return shortHash((text or "") .. "\0" .. (note or ""))
end

function Ledger.shouldSend(ledger, key, hash)
    if not key then return true end
    local entry = ledger[key]
    if not entry then return true end
    if entry.state == "deleted_remotely" or entry.state == "processed" then return false end
    return entry.hash ~= hash
end

function Ledger.recordSent(ledger, key, hash, now)
    if not key then return end
    local entry = ledger[key] or {}
    if entry.state == "deleted_remotely" or entry.state == "processed" then return end
    entry.hash = hash
    entry.sent_at = now or os.time()
    ledger[key] = entry
end

function Ledger.markDeleted(ledger, key, now)
    if not key then return end
    local entry = ledger[key] or {}
    if entry.state ~= "processed" then entry.state = "deleted_remotely" end
    entry.deleted_at = entry.deleted_at or now or os.time()
    ledger[key] = entry
end

-- The annotation key inside a highlight URL this plugin made, or nil.
function Ledger.keyFromUrl(url)
    if type(url) ~= "string" then return nil end
    return url:match("#koreader%-(.+)$")
end

-- Reads v2 export books into { by_key = { [key] = { deleted, text, note } },
-- by_text = { [title\0text] = {...} } } for this device's highlights.
function Ledger.indexExport(export_books)
    local by_key, by_text = {}, {}
    for _, book in ipairs(export_books or {}) do
        for _, highlight in ipairs(book.highlights or {}) do
            local entry = {
                id = highlight.id,
                deleted = highlight.is_deleted == true,
                text = highlight.text,
                note = highlight.note,
            }
            local key = Ledger.keyFromUrl(highlight.url)
            if key then
                -- A later live copy beats a deleted one with the same key.
                if not by_key[key] or by_key[key].deleted then by_key[key] = entry end
            end
            if book.source == "koreader" and type(highlight.text) == "string" then
                local text_key = (book.title or "") .. "\0" .. highlight.text
                if not by_text[text_key] or by_text[text_key].deleted then by_text[text_key] = entry end
            end
        end
    end
    return { by_key = by_key, by_text = by_text }
end

-- First run: what Readwise already has counts as sent, what it deleted is
-- remembered as deleted. Highlights Readwise doesn't have are left out, so
-- they are sent. `clippings` = { { key, title, text, note, annotation_key } }.
function Ledger.migrate(ledger, index, clippings, now)
    local counts = { sent = 0, deleted = 0, new = 0 }
    for _, clip in ipairs(clippings) do
        local remote = (clip.annotation_key and index.by_key[clip.annotation_key])
            or index.by_text[(clip.title or "") .. "\0" .. (clip.text or "")]
        if remote and remote.deleted then
            Ledger.markDeleted(ledger, clip.key, now)
            counts.deleted = counts.deleted + 1
        elseif remote then
            -- Recorded with the remote fingerprint: a local edit since then
            -- still differs and is sent.
            Ledger.recordSent(ledger, clip.key, Ledger.hashFor(remote.text, remote.note), now)
            counts.sent = counts.sent + 1
        else
            counts.new = counts.new + 1
        end
    end
    return counts
end

-- Remote deletions since the last check (export with includeDeleted).
function Ledger.applyRemoteDeletions(ledger, index, now)
    local marked = 0
    local function mark(key)
        if ledger[key] and ledger[key].state ~= "deleted_remotely" then
            Ledger.markDeleted(ledger, key, now)
            marked = marked + 1
        end
    end
    for key, remote in pairs(index.by_key) do
        if remote.deleted then mark(key) end
    end
    for text_key, remote in pairs(index.by_text) do
        if remote.deleted then mark("t" .. shortHash(text_key)) end
    end
    return marked
end

-- v2 ids of this device's live highlights, needed to tag them later.
function Ledger.recordRemoteIds(ledger, index)
    local recorded = 0
    for key, remote in pairs(index.by_key) do
        if not remote.deleted and remote.id and ledger[key] then
            ledger[key].v2_id = remote.id
            recorded = recorded + 1
        end
    end
    for text_key, remote in pairs(index.by_text) do
        local key = "t" .. shortHash(text_key)
        if not remote.deleted and remote.id and ledger[key] then
            ledger[key].v2_id = remote.id
            recorded = recorded + 1
        end
    end
    return recorded
end

-- One heading highlight per chapter for books with no Reader document
-- (Reader makes its own from the table of contents). Returns clippings to
-- send ahead of each chapter's first highlight.
function Ledger.chapterHeadings(booknotes, level)
    local headings, seen = {}, {}
    local note = "." .. (level or "h2")
    -- A heading you made yourself (".h1"/".h2"/".h3" note) wins.
    for _, chapter in ipairs(booknotes or {}) do
        for _, clipping in ipairs(chapter) do
            if type(clipping.note) == "string" and clipping.note:match("^%s*%.h[123]") and clipping.text then
                seen[(clipping.text:gsub("^%s+", ""):gsub("%s+$", ""))] = true
            end
        end
    end
    for _, chapter in ipairs(booknotes or {}) do
        for _, clipping in ipairs(chapter) do
            local title = type(clipping.chapter) == "string" and clipping.chapter:gsub("^%s+", ""):gsub("%s+$", "") or ""
            if title ~= "" and not seen[title] and clipping.text ~= title then
                seen[title] = true
                table.insert(headings, {
                    text = title,
                    note = note,
                    chapter = title,
                    page = clipping.page,
                    time = type(clipping.time) == "number" and clipping.time - 1 or nil,
                    heading_key = "chapter-" .. shortHash(title),
                })
            end
        end
    end
    return headings
end

return Ledger
