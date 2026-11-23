-- One note per book: the Writer Deck book note is kept the same as the
-- Reader document note (decided 2026-11-23). readwise-sync then brings the
-- Reader note into the Obsidian book note, so KOReader Bridge leaves these
-- books alone.
--
-- A Writer Deck book note is writer_deck/books/<name>.md with a JSON comment
-- on its first line; Writer Deck records the Reader id there (readwise_id)
-- when the note is opened in a Reader document. Writer Deck's "— exported"
-- separator lines are its own bookkeeping and never reach Reader.
--
-- Both sides are compared with the text last synced (book_notes_state):
-- changed on one side -> copied to the other; changed on both -> both kept,
-- the Reader version under a ⚠ line, and the result written to both.
local BookNotes = {}

local META_PATTERN = "^<!%-%- writer%-deck%-meta:(.-) %-%->\r?\n?(.*)$"
BookNotes.CONFLICT_LINE = "⚠ Also changed in Reader since the last sync:"

local function trim(text)
    return ((text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The note as Reader should see it: no export separators, tidy blank lines.
function BookNotes.strip(body)
    local lines = {}
    for line in ((body or "") .. "\n"):gmatch("(.-)\r?\n") do
        if line:sub(1, #"— exported ") ~= "— exported " then
            table.insert(lines, line)
        end
    end
    local text = table.concat(lines, "\n"):gsub("\n\n\n+", "\n\n")
    return trim(text)
end

-- What to do: "same", "push" (device -> Reader), "pull" (Reader -> device),
-- or "conflict" with the merged text for both.
function BookNotes.decide(local_text, remote_text, base)
    local mine, theirs = trim(local_text), trim(remote_text)
    if mine == theirs then return { action = "same", text = mine } end
    if base ~= nil then
        base = trim(base)
        if mine == base then return { action = "pull", text = theirs } end
        if theirs == base then return { action = "push", text = mine } end
    else
        if theirs == "" then return { action = "push", text = mine } end
        if mine == "" then return { action = "pull", text = theirs } end
    end
    return {
        action = "conflict",
        text = mine .. "\n\n" .. BookNotes.CONFLICT_LINE .. "\n\n" .. theirs,
    }
end

-- { meta = table|nil, meta_json = string|nil, body = string } from a file's text.
function BookNotes.parseFile(content, decode)
    local encoded, body = (content or ""):match(META_PATTERN)
    if not encoded then return { body = content or "" } end
    local ok, meta = pcall(decode, encoded)
    return { meta = ok and type(meta) == "table" and meta or nil, meta_json = encoded, body = body or "" }
end

function BookNotes.serialize(meta, body, encode)
    local encoded = encode(meta)
    return "<!-- writer-deck-meta:" .. encoded .. " -->\n" .. body
end

function BookNotes.install(R, deps)
    local logger = deps.logger
    local lfs = deps.lfs
    local DataStorage = deps.DataStorage
    local json = deps.json

    function R:initBookNotes(settings)
        -- Reader id -> { text = last synced text }
        self.book_notes_state = settings.book_notes_state or {}
    end

    function R:bookNotesSettingsForSave(settings)
        settings.book_notes_state = self.book_notes_state
        return settings
    end

    function R:writerDeckBooksDir()
        return DataStorage:getDataDir() .. "/writer_deck/books"
    end

    local function readFile(path)
        local file = io.open(path, "rb")
        if not file then return nil end
        local content = file:read("*a")
        file:close()
        return content
    end

    local function writeFile(path, content)
        local temp = path .. ".tmp"
        local file, err = io.open(temp, "wb")
        if not file then return nil, err end
        file:write(content)
        file:close()
        local ok, rename_err = os.rename(temp, path)
        if not ok then os.remove(temp) return nil, rename_err end
        return true
    end

    -- Book notes that name a Reader document: { [doc_id] = { path, meta, body } }.
    function R:listWriterDeckBookNotes()
        local notes = {}
        local dir = self:writerDeckBooksDir()
        if lfs.attributes(dir, "mode") ~= "directory" then return notes end
        for name in lfs.dir(dir) do
            if name:match("%.md$") and name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local parsed = BookNotes.parseFile(readFile(path), json.decode)
                local doc_id = parsed.meta and parsed.meta.readwise_id
                if type(doc_id) == "string" and doc_id ~= "" then
                    parsed.path = path
                    notes[doc_id] = parsed
                end
            end
        end
        return notes
    end

    function R:writeWriterDeckNote(note, text)
        note.meta.updated_at = os.time()
        -- Writer Deck shows the note as written; keep a final newline.
        return writeFile(note.path, BookNotes.serialize(note.meta, text .. "\n", json.encode))
    end

    -- Runs in syncReadingData. kinds = "books": only notes of local books.
    -- only_doc: just that Reader document (quick sync after closing a book).
    -- Returns { sent, received, conflicts }.
    function R:syncBookNotes(kinds, only_doc)
        local report = { sent = 0, received = 0, conflicts = 0 }
        local notes = self:listWriterDeckBookNotes()
        if next(notes) == nil then return report end
        local books = kinds == "books" and self:localBookIds() or nil
        for doc_id, note in pairs(notes) do
            if (not books or books[doc_id]) and (not only_doc or only_doc == doc_id) then
                local document, err, status = self.reader_api:getDocument(doc_id, false)
                if not document then
                    logger.warn("ReadwiseReader:syncBookNotes: could not read", doc_id, err, status)
                else
                    local state = self.book_notes_state[doc_id]
                    local local_text = BookNotes.strip(note.body)
                    local decision = BookNotes.decide(local_text, document.notes, state and state.text)
                    local ok = true
                    if decision.action == "push" or decision.action == "conflict" then
                        local sent, send_err = self:updateReaderDocumentNotes(doc_id, decision.text)
                        ok = sent ~= nil and sent ~= false
                        if ok then report.sent = report.sent + 1
                        else logger.warn("ReadwiseReader:syncBookNotes: could not send", doc_id, send_err) end
                    end
                    if ok and (decision.action == "pull" or decision.action == "conflict") then
                        local written, write_err = self:writeWriterDeckNote(note, decision.text)
                        ok = written == true
                        if ok then report.received = report.received + 1
                        else logger.warn("ReadwiseReader:syncBookNotes: could not write", note.path, write_err) end
                    end
                    if decision.action == "conflict" then report.conflicts = report.conflicts + 1 end
                    if ok then self.book_notes_state[doc_id] = { text = decision.text } end
                end
            end
        end
        self:saveSettings()
        return report
    end
end

return BookNotes
