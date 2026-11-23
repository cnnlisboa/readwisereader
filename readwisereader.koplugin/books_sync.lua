-- Readwise Books sync for the KOReader plugin (PLAN-readwise-books.md, D.0-D.4).
--
-- Installed onto ReadwiseReader by main.lua:
--     require("books_sync").install(ReadwiseReader, deps)
-- Decisions live in library/books_map.lua and library/automation.lua; this
-- file only reads sidecars, calls the API and applies results.
local BooksAPI = require("api/books")
local BooksMap = require("library/books_map")
local Automation = require("library/automation")
local Sessions = require("library/sessions")
local Progress = require("library/progress")
local EpubUpload = require("library/epub_upload")

local BooksSync = {}

-- deps: everything KOReader-specific, passed in so this file loads anywhere.
function BooksSync.install(R, deps)
    local logger = deps.logger
    local DocSettings = deps.DocSettings
    local UIManager = deps.UIManager
    local ConfirmBox = deps.ConfirmBox
    local InfoMessage = deps.InfoMessage
    local NetworkMgr = deps.NetworkMgr
    local Trapper = deps.Trapper
    local lfs = deps.lfs
    local getReadCollection = deps.getReadCollection
    local DataStorage = deps.DataStorage
    local Device = deps.Device
    local util = deps.util

    local SETTINGS_KEYS = {
        "books_sync_enabled", "books_ids", "books_state", "books_cache",
        "pending_books_updates", "automation_modes", "books_download_shelves",
        "books_tbr", "books_tbr_collection", "delete_finished_books", "books_keep",
        "books_archived_kept", "books_unmatched", "books_match_signature",
        "books_sessions", "sessions_from_device", "sessions_gap_minutes", "sessions_min_minutes",
        "sessions_publish", "books_uploads", "books_upload_skip", "books_upload_baseline",
    }

    function R:initBooks(settings)
        self.books_sync_enabled = settings.books_sync_enabled or false
        -- Reader document id -> Readwise Books id.
        self.books_ids = settings.books_ids or {}
        -- Books id -> what this device last saw/sent (library/books_map.lua).
        self.books_state = settings.books_state or {}
        -- Books id -> { status, rating, started_reading_at, finished_reading_at }
        -- from the last fetch, so closing a book needs no request to decide.
        self.books_cache = settings.books_cache or {}
        -- PATCH items that failed offline or on a retryable error.
        self.pending_books_updates = settings.pending_books_updates or {}
        self.automation_modes = Automation.migrate(settings.automation_modes, {
            archive_finished = settings.archive_finished,
            export_highlights_at_sync = settings.export_highlights_at_sync,
        })
        self.books_download_shelves = settings.books_download_shelves or { currently_reading = true }
        self.books_tbr = settings.books_tbr ~= false
        self.books_tbr_collection = settings.books_tbr_collection or "To Be Read"
        self.delete_finished_books = settings.delete_finished_books ~= false
        -- Reader document id -> true: never deleted automatically.
        self.books_keep = settings.books_keep or {}
        -- Kept books already archived in Reader, so it happens once.
        self.books_archived_kept = settings.books_archived_kept or {}
        -- Reader ids that matched no Books entry, retried when the library changes.
        self.books_unmatched = settings.books_unmatched or {}
        self.books_match_signature = settings.books_match_signature
        -- Books id -> { watermark = epoch, sent = { [key] = ended } }
        self.books_sessions = settings.books_sessions or {}
        self.sessions_from_device = settings.sessions_from_device ~= false
        self.sessions_gap_minutes = settings.sessions_gap_minutes or 5
        self.sessions_min_minutes = settings.sessions_min_minutes or 2
        self.sessions_publish = settings.sessions_publish or false
        -- filepath -> { upload_id, state = "processing"|"done"|"failed", at, book_id }
        self.books_uploads = settings.books_uploads or {}
        -- filepath -> true: never offered for upload
        self.books_upload_skip = settings.books_upload_skip or {}
        -- Set once the EPUBs already on the device were set aside, so only
        -- books added afterwards are offered.
        self.books_upload_baseline = settings.books_upload_baseline or false
        self.books_api = BooksAPI:new{
            request = function(method, endpoint, body)
                return self:callAPI(method, endpoint, body, true, BooksAPI.BASE_URL)
            end,
        }
    end

    function R:booksSettingsForSave(settings)
        for _, key in ipairs(SETTINGS_KEYS) do
            settings[key] = self[key]
        end
        return settings
    end

    -- ------------------------------------------------------------------
    -- Automation
    -- ------------------------------------------------------------------

    function R:automationMode(id)
        return Automation.mode(self.automation_modes, id)
    end

    function R:setAutomationMode(id, mode)
        self.automation_modes[id] = mode
        self.export_highlights_at_sync = self:automationMode("send_highlights") ~= "manual"
        self.archive_finished = self:automationMode("archive_finished") ~= "manual"
        self:saveSettings()
    end

    -- "run", "ask" or "skip" for an action at its automatic trigger. A
    -- "Run now" menu entry marks the action in self.manual_actions first.
    function R:actionDecision(id)
        local trigger = (self.manual_actions and self.manual_actions[id]) and "manual" or "auto"
        return Automation.decide(self.automation_modes, id, trigger)
    end

    -- Inside a Trapper-wrapped sync: blocks for the answer. Elsewhere (open,
    -- close): shows a dialog and runs fn from its callback. Returns whether fn
    -- ran now.
    function R:runAutomated(id, question, fn)
        local decision = self:actionDecision(id)
        if decision == "run" then
            fn()
            return true
        elseif decision == "skip" then
            return false
        end
        if coroutine.running() then
            if Trapper:confirm(question, "Not now", "Yes") then
                fn()
                return true
            end
            return false
        end
        UIManager:show(ConfirmBox:new{
            text = question,
            ok_text = "Yes",
            cancel_text = "Not now",
            ok_callback = fn,
        })
        return false
    end

    -- Runs a sync where the given actions count as started by hand.
    function R:runActionsNow(ids)
        self.manual_actions = {}
        for _, id in ipairs(ids) do self.manual_actions[id] = true end
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
                local ok, err = pcall(function() self:synchronize() end)
                self.manual_actions = nil
                if not ok then error(err, 0) end
            end)
        end)
    end

    -- ------------------------------------------------------------------
    -- Local books
    -- ------------------------------------------------------------------

    function R:isBookFile(doc_id, filepath)
        if type(filepath) == "string" and filepath:lower():match("%.epub$") then
            return true
        end
        return doc_id ~= nil and self.document_categories and self.document_categories[doc_id] == "epub"
    end

    -- Whether automatic cleanup must leave this file alone (D.9).
    function R:keepsOnDevice(doc_id, filepath)
        if not self:isBookFile(doc_id, filepath) then
            return false
        end
        return not self.delete_finished_books or (doc_id ~= nil and self.books_keep[doc_id] == true)
    end

    -- doc_id -> filepath for every local book with a Reader identity:
    -- downloaded EPUBs and linked sideloaded books.
    function R:getLocalBooks()
        local books = {}
        self:forEachLocalDocument(function(doc_id, filepath)
            if self:isBookFile(doc_id, filepath) then
                books[doc_id] = books[doc_id] or filepath
            end
        end)
        for filepath in pairs(self.local_book_links or {}) do
            local link = self:getLocalBookLink(filepath)
            if link and lfs.attributes(filepath, "mode") == "file"
                and (link.category == "epub" or self:isBookFile(nil, filepath)) then
                books[link.id] = books[link.id] or filepath
            end
        end
        return books
    end

    function R:isInTbr(filepath)
        local ReadCollection = getReadCollection()
        local name = self.books_tbr_collection
        return ReadCollection ~= nil and ReadCollection.coll ~= nil and ReadCollection.coll[name] ~= nil
            and ReadCollection:isFileInCollection(filepath, name) or false
    end

    function R:addToTbr(filepath)
        local ReadCollection = getReadCollection()
        if not ReadCollection then return false end
        local name = self.books_tbr_collection
        if not ReadCollection.coll[name] then
            ReadCollection:addCollection(name)
        end
        if ReadCollection:isFileInCollection(filepath, name) then return false end
        ReadCollection:addItem(filepath, name)
        ReadCollection:write({ [name] = true })
        return true
    end

    -- { status, rating, in_tbr } from the sidecar, or from the open document.
    function R:readLocalBookStatus(filepath)
        local summary
        if self:isDocumentOpen(filepath) and self.ui.doc_settings then
            summary = self.ui.doc_settings:readSetting("summary")
        elseif DocSettings:hasSidecarFile(filepath) then
            summary = DocSettings:open(filepath):readSetting("summary")
        end
        summary = type(summary) == "table" and summary or {}
        return {
            status = summary.status,
            rating = tonumber(summary.rating),
            in_tbr = self:isInTbr(filepath),
        }
    end

    -- Applies BooksMap.planRemoteChange actions to a closed book's sidecar.
    function R:applyDeviceActions(filepath, actions)
        if self:isDocumentOpen(filepath) then
            return false
        end
        if actions.status or actions.rating then
            local doc_settings = DocSettings:open(filepath)
            local summary = doc_settings:readSetting("summary") or {}
            if actions.status then
                summary.status = actions.status
                summary.modified = os.date("%Y-%m-%d")
            end
            if actions.rating then
                summary.rating = actions.rating
            end
            doc_settings:saveSetting("summary", summary)
            doc_settings:flush()
        end
        if actions.add_tbr then
            self:addToTbr(filepath)
        end
        return true
    end

    -- ------------------------------------------------------------------
    -- Identity
    -- ------------------------------------------------------------------

    function R:getBooksIdForFile(filepath)
        local doc_id = self:getReaderIdentity(filepath)
        return doc_id and self.books_ids[doc_id] or nil, doc_id
    end

    -- Fills books_ids for every Reader EPUB that lacks one. One Reader list
    -- request, made only when something is unmapped and the library changed
    -- since the last attempt.
    function R:refreshBooksIdentities(books, by_id, force)
        local wanted = false
        for doc_id in pairs(self:getLocalBooks()) do
            local mapped = self.books_ids[doc_id]
            if not mapped or not by_id[mapped] then
                wanted = true
                break
            end
        end
        local signature = tostring(#books)
        if not force and (not wanted or signature == self.books_match_signature) then
            return
        end
        local identities, err, status = self.reader_api:listEpubIdentities()
        if not identities then
            logger.warn("ReadwiseReader:refreshBooksIdentities: Reader list failed", err, status)
            return
        end
        local matches, unmatched = BooksMap.matchBooks(identities, books)
        for doc_id, book_id in pairs(matches) do
            self.books_ids[doc_id] = book_id
        end
        self.books_unmatched = {}
        for _, doc_id in ipairs(unmatched) do self.books_unmatched[doc_id] = true end
        self.books_match_signature = signature
        logger.dbg("ReadwiseReader:refreshBooksIdentities: unmatched", #unmatched)
    end

    -- ------------------------------------------------------------------
    -- Sending
    -- ------------------------------------------------------------------

    local function cacheEntry(book)
        return {
            status = book.status,
            rating = book.rating,
            started_reading_at = book.started_reading_at,
            finished_reading_at = book.finished_reading_at,
        }
    end

    function R:rememberBook(book)
        if type(book) == "table" and type(book.id) == "number" then
            self.books_cache[book.id] = cacheEntry(book)
        end
    end

    local function applyPatchToCache(cache, patch)
        local entry = cache[patch.id]
        if not entry then return end
        for key, value in pairs(patch) do
            if key ~= "id" then entry[key] = value end
        end
    end

    local function queuePatch(queue, patch)
        for _, queued in ipairs(queue) do
            if queued.id == patch.id then
                for key, value in pairs(patch) do queued[key] = value end
                return
            end
        end
        local copy = {}
        for key, value in pairs(patch) do copy[key] = value end
        table.insert(queue, copy)
    end

    -- Sends patches; failed retryable ones are queued. Returns sent count and
    -- the ids that were applied.
    function R:sendBooksPatches(patches)
        if #patches == 0 then return 0, {} end
        local results = self.books_api:update(patches)
        local sent, applied = 0, {}
        for i, patch in ipairs(patches) do
            local result = results[i]
            if result and result.ok then
                sent = sent + 1
                applied[patch.id] = true
                applyPatchToCache(self.books_cache, patch)
            elseif BooksAPI.isRetryable(result) then
                queuePatch(self.pending_books_updates, patch)
            else
                logger.warn("ReadwiseReader:sendBooksPatches: dropped", patch.id,
                    result and result.code, result and result.message)
            end
        end
        return sent, applied
    end

    function R:flushPendingBooksUpdates()
        if #self.pending_books_updates == 0 then return 0 end
        local queue = self.pending_books_updates
        self.pending_books_updates = {}
        local sent = self:sendBooksPatches(queue)
        self:saveSettings()
        return sent
    end

    -- Opening and closing run with the fast request budget and never turn
    -- Wi-Fi on: offline, the patch waits for the next sync.
    function R:sendBooksPatchNow(patch)
        if not NetworkMgr:isOnline() then
            queuePatch(self.pending_books_updates, patch)
            self:saveSettings()
            return false
        end
        local ok, sent = pcall(function()
            return self:withFastRequests(function()
                return self:sendBooksPatches({ patch })
            end)
        end)
        if not ok then
            logger.warn("ReadwiseReader:sendBooksPatchNow: failed", sent)
            queuePatch(self.pending_books_updates, patch)
            sent = 0
        end
        self:saveSettings()
        return sent == 1
    end

    -- ------------------------------------------------------------------
    -- Sync
    -- ------------------------------------------------------------------

    local function recordLocal(state, now_local)
        state.local_status = now_local.status
        state.in_tbr = now_local.in_tbr and true or false
        state.local_rating = now_local.rating
    end

    -- Runs inside synchronize(). Returns { [reader doc id] = shelf } for the
    -- download filter (nil when Books sync is off or unreachable) and a
    -- report { sent, applied, queued }.
    function R:syncReadwiseBooks()
        local report = { sent = 0, applied = 0, queued = 0 }
        if not self.books_sync_enabled then
            return nil, report
        end
        self:showProgress("Syncing Readwise Books…")
        self:flushPendingBooksUpdates()

        local books, err, status = self.books_api:listAll()
        if not books then
            logger.warn("ReadwiseReader:syncReadwiseBooks: list failed", err, status)
            self:hideProgress()
            return nil, report
        end
        local by_id = {}
        for _, book in ipairs(books) do
            by_id[book.id] = book
        end
        self:refreshBooksIdentities(books, by_id)

        local shelves = {}
        for doc_id, book_id in pairs(self.books_ids) do
            local book = by_id[book_id]
            if book then shelves[doc_id] = book.status end
        end
        -- Forget cache entries for books no longer in the library.
        for book_id in pairs(self.books_cache) do
            if not by_id[book_id] then self.books_cache[book_id] = nil end
        end

        local patches, device_jobs, observed = {}, {}, {}
        for doc_id, filepath in pairs(self:getLocalBooks()) do
            local book = by_id[self.books_ids[doc_id] or -1]
            if book and not self:isDocumentOpen(filepath) then
                self:rememberBook(book)
                local now_local = self:readLocalBookStatus(filepath)
                local state = self.books_state[book.id] or {}
                self.books_state[book.id] = state
                local patch = BooksMap.planLocalChange(book, now_local, state)
                local actions = BooksMap.planRemoteChange(book, now_local, state, { tbr = self.books_tbr })
                if patch and patch.status and actions then
                    actions.status = nil -- the device's own change wins this round
                    actions.add_tbr = nil
                end
                if patch then table.insert(patches, patch) end
                if actions and next(actions) then
                    table.insert(device_jobs, { filepath = filepath, actions = actions, book = book })
                end
                table.insert(observed, { book = book, state = state, now_local = now_local, patch = patch })
            end
        end

        local sent_ok = {}
        if #patches > 0 then
            self:runAutomated("books_status",
                string.format("Send %d status/rating change(s) to Readwise Books?", #patches),
                function()
                    local sent, applied = self:sendBooksPatches(patches)
                    report.sent = sent
                    sent_ok = applied
                end)
        end
        local applied_ok = {}
        if #device_jobs > 0 then
            self:runAutomated("books_remote",
                string.format("Apply %d Readwise Books change(s) to this device?", #device_jobs),
                function()
                    for _, job in ipairs(device_jobs) do
                        if self:applyDeviceActions(job.filepath, job.actions) then
                            applied_ok[job.book.id] = job.actions
                            report.applied = report.applied + 1
                        end
                    end
                end)
        end

        -- Record what this device now agrees with. Anything skipped or failed
        -- keeps its old state, so it is noticed again next time.
        for _, entry in ipairs(observed) do
            local book, state, now_local = entry.book, entry.state, entry.now_local
            if state.remote_status == nil then
                state.remote_status = book.status -- baseline
            end
            if not entry.patch or sent_ok[book.id] then
                recordLocal(state, now_local)
                if entry.patch and entry.patch.status then
                    state.remote_status = entry.patch.status
                end
            end
            local actions = applied_ok[book.id]
            if actions then
                state.remote_status = book.status
                if actions.status then state.local_status = actions.status end
                if actions.rating then state.local_rating = actions.rating end
                if actions.add_tbr then state.in_tbr = true end
            elseif not BooksMap.planRemoteChange(book, now_local, state, { tbr = self.books_tbr }) then
                state.remote_status = book.status
            end
        end
        report.queued = #self.pending_books_updates
        self.books_last_list = { books = books, by_id = by_id }
        self:saveSettings()
        self:hideProgress()
        return shelves, report
    end

    -- Readwise Books shelves for the Library browser: the Reader EPUB of
    -- every book, grouped by shelf, so one can be picked for download.
    -- Returns { [shelf] = { documents = {...}, not_in_reader = n } } or nil, err, status.
    function R:loadBooksShelves()
        local books, err, status = self.books_api:listAll()
        if not books then return nil, err, status end
        local identities, list_err, list_status = self.reader_api:listEpubIdentities()
        if not identities then return nil, list_err, list_status end

        local by_id = {}
        for _, book in ipairs(books) do by_id[book.id] = book end
        local matches, unmatched = BooksMap.matchBooks(identities, books)
        for doc_id, book_id in pairs(matches) do self.books_ids[doc_id] = book_id end
        self.books_unmatched = {}
        for _, doc_id in ipairs(unmatched) do self.books_unmatched[doc_id] = true end
        self.books_match_signature = tostring(#books)
        self.books_last_list = { books = books, by_id = by_id }
        self:saveSettings()

        local result, in_reader = {}, {}
        local function shelf(name)
            result[name] = result[name] or { documents = {}, not_in_reader = 0 }
            return result[name]
        end
        for _, identity in ipairs(identities) do
            local book = by_id[matches[identity.id] or -1]
            if book and book.status ~= "deleted" then
                in_reader[book.id] = true
                table.insert(shelf(book.status).documents, {
                    id = identity.id,
                    title = identity.title or book.title,
                    author = identity.author or book.author,
                    category = "epub",
                    location = identity.location,
                    reading_progress = identity.reading_progress,
                })
            end
        end
        for _, book in ipairs(books) do
            if not in_reader[book.id] and book.status ~= "deleted" then
                local entry = shelf(book.status)
                entry.not_in_reader = entry.not_in_reader + 1
            end
        end
        for _, entry in pairs(result) do
            table.sort(entry.documents, function(a, b) return (a.title or "") < (b.title or "") end)
        end
        return result
    end

    -- The shelf of each Reader book about to be downloaded. Matching above
    -- only covers books already on the device, so a new book is matched here
    -- (one Reader list request, skipped when every candidate was already
    -- unmatched against an unchanged Books library).
    function R:addCandidateShelves(shelves, doc_ids)
        local last = self.books_last_list
        if not (shelves and last) then return shelves end
        local signature = tostring(#last.books)
        local needed = false
        for _, doc_id in ipairs(doc_ids) do
            if not shelves[doc_id] and not (self.books_ids[doc_id] and last.by_id[self.books_ids[doc_id]])
                and (not self.books_unmatched[doc_id] or signature ~= self.books_match_signature) then
                needed = true
                break
            end
        end
        if needed then
            self:refreshBooksIdentities(last.books, last.by_id, true)
            self:saveSettings()
        end
        for _, doc_id in ipairs(doc_ids) do
            local book = last.by_id[self.books_ids[doc_id] or -1]
            if book and not shelves[doc_id] then shelves[doc_id] = book.status end
        end
        return shelves
    end

    -- ------------------------------------------------------------------
    -- Open / close
    -- ------------------------------------------------------------------

    -- Shortly after a book opens: currently_reading and first start date, or
    -- the re-read question for a finished book.
    function R:booksOnOpen(filepath)
        if not self.books_sync_enabled or not self:hasAccessToken() then return end
        local book_id = self:getBooksIdForFile(filepath)
        if not book_id then return end
        if self:actionDecision("books_open") == "skip" and self:actionDecision("books_reread") == "skip" then
            return
        end
        if not NetworkMgr:isOnline() then return end
        local ok, found = pcall(function()
            return self:withFastRequests(function()
                return self.books_api:getByIds({ book_id })
            end)
        end)
        local book = ok and type(found) == "table" and found[book_id] or nil
        if not book then
            logger.dbg("ReadwiseReader:booksOnOpen: could not read", book_id)
            return
        end
        if not self:isDocumentOpen(filepath) then return end
        self:rememberBook(book)
        local plan = BooksMap.planOpen(book)
        if not plan then
            self:saveSettings()
            return
        end
        if plan.prompt == "reread" then
            self:runAutomated("books_reread",
                "You finished this book in Readwise Books.\n\nStart a re-read? It moves back to Currently reading.",
                function() self:startReread(filepath, book) end)
            return
        end
        self:runAutomated("books_open", "Mark this book as Currently reading in Readwise Books?", function()
            if self:sendBooksPatchNow(plan.patch) then
                local state = self.books_state[book.id] or {}
                self.books_state[book.id] = state
                state.remote_status = plan.patch.status or state.remote_status
                self:saveSettings()
            end
        end)
    end

    function R:startReread(filepath, book)
        local plan = BooksMap.planReread(book)
        local state = self.books_state[book.id] or {}
        self.books_state[book.id] = state
        -- The open book becomes "reading" again so finishing it later is a
        -- change the close hook can see.
        if self:isDocumentOpen(filepath) and self.ui.doc_settings then
            local summary = self.ui.doc_settings:readSetting("summary") or {}
            summary.status = "reading"
            summary.modified = os.date("%Y-%m-%d")
            self.ui.doc_settings:saveSetting("summary", summary)
        end
        state.local_status = "reading"
        if self:sendBooksPatchNow(plan.patch) then
            state.remote_status = "currently_reading"
        end
        self:saveSettings()
    end

    -- Closing: status and rating changes made while reading (finishing the
    -- book, putting it on hold, rating it). Decided from the cached book, so
    -- no request is made unless there is something to send.
    function R:booksOnClose(filepath)
        if not self.books_sync_enabled or not self:hasAccessToken() then return end
        local book_id = self:getBooksIdForFile(filepath)
        local cached = book_id and self.books_cache[book_id]
        if not cached then return end
        local book = { id = book_id }
        for key, value in pairs(cached) do book[key] = value end
        local now_local = self:readLocalBookStatus(filepath)
        local state = self.books_state[book_id] or {}
        self.books_state[book_id] = state
        local patch = BooksMap.planLocalChange(book, now_local, state)
        if not patch then
            recordLocal(state, now_local)
            self:saveSettings()
            return
        end
        local question = patch.status == "finished" and "Mark this book as Finished in Readwise Books?"
            or "Send this book's status and rating to Readwise Books?"
        self:runAutomated("books_status", question, function()
            if self:sendBooksPatchNow(patch) then
                recordLocal(state, now_local)
                if patch.status then state.remote_status = patch.status end
                self:saveSettings()
            end
        end)
    end

    -- ------------------------------------------------------------------
    -- Reading sessions (D.5)
    -- ------------------------------------------------------------------

    local SQ3
    local function openStats()
        if SQ3 == nil then
            local ok, module = pcall(require, "lua-ljsqlite3/init")
            SQ3 = ok and module or false
        end
        if not SQ3 then return nil end
        local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        if lfs.attributes(path, "mode") ~= "file" then return nil end
        local ok, conn = pcall(SQ3.open, path, "ro")
        return ok and conn or nil
    end

    -- The statistics id KOReader uses is found by the file's partial MD5,
    -- which it keeps in the sidecar.
    function R:partialMD5(filepath)
        local md5
        if self:isDocumentOpen(filepath) and self.ui.doc_settings then
            md5 = self.ui.doc_settings:readSetting("partial_md5_checksum")
        elseif DocSettings:hasSidecarFile(filepath) then
            md5 = DocSettings:open(filepath):readSetting("partial_md5_checksum")
        end
        if not md5 and util and util.partialMD5 then
            md5 = util.partialMD5(filepath)
        end
        return md5
    end

    -- page_stat_data rows for a file since `since` (epoch).
    function R:readStatsRows(filepath, since)
        local md5 = self:partialMD5(filepath)
        if not md5 then return {} end
        local conn = openStats()
        if not conn then return {} end
        local rows = {}
        local ok, err = pcall(function()
            local stmt = conn:prepare("SELECT id FROM book WHERE md5 = ?")
            local ids = {}
            for row in stmt:bind(md5):rows() do table.insert(ids, tonumber(row[1])) end
            stmt:close()
            local query = conn:prepare("SELECT page, start_time, duration, total_pages FROM page_stat_data "
                .. "WHERE id_book = ? AND start_time > ? ORDER BY start_time")
            for _, id in ipairs(ids) do
                for row in query:bind(id, since or 0):rows() do
                    table.insert(rows, { page = tonumber(row[1]), start_time = tonumber(row[2]),
                        duration = tonumber(row[3]), total_pages = tonumber(row[4]) })
                end
                query:clearbind():reset()
            end
            query:close()
        end)
        conn:close()
        if not ok then
            logger.warn("ReadwiseReader:readStatsRows: statistics query failed", err)
        end
        return rows
    end

    function R:sessionDevice()
        local model = Device and Device.model
        if type(model) ~= "string" or model == "" then model = "KOReader" end
        local vendor = "KOReader"
        if Device and Device.isKindle and Device:isKindle() then vendor = "Amazon"
        elseif Device and Device.isAndroid and Device:isAndroid() then vendor = "Onyx"
        elseif Device and Device.isKobo and Device:isKobo() then vendor = "Kobo" end
        return { model = model:sub(1, 100), type = "E-Reader", vendor = vendor }
    end

    -- Posts unsent sessions for the given local books ({ [doc_id] = path }).
    -- Returns the number posted.
    function R:postSessionsFor(local_books, hold_open)
        if not self.books_sync_enabled or not self.sessions_from_device then return 0 end
        local gap = (self.sessions_gap_minutes or 5) * 60
        local options = { device = self:sessionDevice(), publish_to_feed = self.sessions_publish }
        local items, pending_by_item = {}, {}
        local first_run_books = {}
        for doc_id, filepath in pairs(local_books) do
            local book_id = self.books_ids[doc_id]
            if book_id then
                local ledger = self.books_sessions[book_id] or {}
                local since = (ledger.watermark or 0) - gap
                local sessions = Sessions.build(self:readStatsRows(filepath, since), {
                    gap = gap, min_seconds = (self.sessions_min_minutes or 2) * 60,
                })
                local hold_after = (hold_open and self:isDocumentOpen(filepath)) and (os.time() - gap) or nil
                local pending = Sessions.pending(sessions, ledger, hold_after)
                if #pending > 0 and not ledger.watermark then
                    table.insert(first_run_books, book_id)
                end
                for _, session in ipairs(pending) do
                    table.insert(items, Sessions.toItem(session, book_id, options))
                    table.insert(pending_by_item, { book_id = book_id, session = session })
                end
            end
        end
        if #items == 0 then return 0 end

        -- First time for a book: sessions may already be in Readwise from an
        -- earlier attempt whose answer was lost, so look before posting.
        if #first_run_books > 0 then
            local remote = self.books_api:listSessions(first_run_books)
            if remote then
                local by_book = {}
                for _, session in ipairs(remote) do
                    by_book[session.book_id] = by_book[session.book_id] or {}
                    table.insert(by_book[session.book_id], session)
                end
                local kept_items, kept_pending = {}, {}
                for i, entry in ipairs(pending_by_item) do
                    if Sessions.alreadyRemote(entry.session, by_book[entry.book_id], Progress.toEpoch) then
                        local ledger = self.books_sessions[entry.book_id] or {}
                        self.books_sessions[entry.book_id] = Sessions.record(ledger, entry.session)
                    else
                        table.insert(kept_items, items[i])
                        table.insert(kept_pending, entry)
                    end
                end
                items, pending_by_item = kept_items, kept_pending
            end
        end

        local results = self.books_api:createSessions(items)
        local posted = 0
        for i, entry in ipairs(pending_by_item) do
            local result = results[i]
            if result and result.ok then
                posted = posted + 1
                local ledger = self.books_sessions[entry.book_id] or {}
                self.books_sessions[entry.book_id] = Sessions.record(ledger, entry.session)
            elseif result and not BooksAPI.isRetryable(result) then
                -- e.g. a sample book: never accepted, so don't try forever
                local ledger = self.books_sessions[entry.book_id] or {}
                self.books_sessions[entry.book_id] = Sessions.record(ledger, entry.session)
                logger.warn("ReadwiseReader:postSessionsFor: rejected", entry.book_id, result.code, result.message)
            end
        end
        self:saveSettings()
        return posted
    end

    -- Sync: every local book; the open book's latest session waits.
    function R:syncSessions()
        if not self.books_sync_enabled or not self.sessions_from_device then return 0 end
        local posted = 0
        self:runAutomated("sessions", "Post reading sessions to Readwise Books?", function()
            posted = self:postSessionsFor(self:getLocalBooks(), true)
        end)
        return posted
    end

    -- Closing a book: just that book.
    function R:sessionsOnClose(filepath)
        if not self.books_sync_enabled or not self.sessions_from_device then return end
        if not NetworkMgr:isOnline() then return end
        local book_id, doc_id = self:getBooksIdForFile(filepath)
        if not book_id then return end
        self:runAutomated("sessions", "Post this reading session to Readwise Books?", function()
            local ok, err = pcall(function()
                self:withFastRequests(function()
                    self:postSessionsFor({ [doc_id] = filepath }, false)
                end)
            end)
            if not ok then logger.warn("ReadwiseReader:sessionsOnClose: failed", err) end
        end)
    end

    -- ------------------------------------------------------------------
    -- Uploading sideloaded EPUBs (D.8)
    -- ------------------------------------------------------------------

    -- EPUBs in the book folder that Readwise doesn't know: no Reader id, not
    -- linked, not uploaded or skipped.
    function R:findSideloadedEpubs()
        local found = {}
        local directory = self.book_directory or self.directory
        if type(directory) ~= "string" or lfs.attributes(directory, "mode") ~= "directory" then
            return found
        end
        if directory:sub(-1) ~= "/" then directory = directory .. "/" end
        for entry in lfs.dir(directory) do
            local filepath = directory .. entry
            if entry:lower():match("%.epub$") and entry:sub(1, 1) ~= "."
                and lfs.attributes(filepath, "mode") == "file"
                and not self:getReaderIdentity(filepath)
                and not self.books_upload_skip[filepath]
                and not self.books_uploads[filepath] then
                table.insert(found, filepath)
            end
        end
        table.sort(found)
        return found
    end

    -- Steps 1-3 for one file. Returns true or nil, reason.
    function R:uploadEpub(filepath)
        local size = lfs.attributes(filepath, "size")
        if not size or size <= 0 or size > EpubUpload.MAX_BYTES then
            return nil, "file size not accepted"
        end
        local created = self.books_api:createUploads({ { file_name = EpubUpload.fileName(filepath), size = size } })
        local result = created[1]
        local raw = result and result.raw
        if not (result and result.ok and raw and raw.upload and raw.upload_url) then
            return nil, "upload refused: " .. tostring(result and (result.code or result.message))
        end
        local put_ok, put_err = EpubUpload.put(raw.upload_url, raw.upload_headers, filepath, size)
        if not put_ok then
            return nil, put_err
        end
        local shelf = EpubUpload.shelfFor(self:readLocalBookStatus(filepath).status)
        local completed = self.books_api:completeUploads({ { id = raw.upload.id, status = shelf } })
        if not (completed[1] and completed[1].ok) then
            return nil, "complete failed: " .. tostring(completed[1] and completed[1].code)
        end
        self.books_uploads[filepath] = { upload_id = raw.upload.id, state = "processing", at = os.time() }
        self:saveSettings()
        return true
    end

    -- Uploads that finished processing get linked: the Readwise Books id is
    -- known, and the new Reader document is found by title and linked to the
    -- local file, so its position and highlights follow it.
    function R:checkUploads()
        local ids, by_id = {}, {}
        for filepath, upload in pairs(self.books_uploads) do
            if upload.state == "processing" then
                table.insert(ids, upload.upload_id)
                by_id[upload.upload_id] = filepath
            end
        end
        if #ids == 0 then return 0 end
        local uploads = self.books_api:getUploads(ids)
        if not uploads then return 0 end
        local linked, identities = 0, nil
        for _, upload in ipairs(uploads) do
            local filepath = by_id[upload.id]
            local record = filepath and self.books_uploads[filepath]
            if record and upload.upload_status == "failed" then
                record.state = "failed"
            elseif record and upload.upload_status == "ready" and type(upload.book) == "table" then
                record.book_id = upload.book.id
                record.state = "done"
                identities = identities or self.reader_api:listEpubIdentities() or {}
                local matches = BooksMap.matchBooks(identities, { upload.book })
                local doc_id
                for candidate, book_id in pairs(matches) do
                    if book_id == upload.book.id then doc_id = candidate end
                end
                if doc_id then
                    local document = self.reader_api:getDocument(doc_id, false)
                    if document and self:linkLocalBookToReader(filepath, document) then
                        self.books_ids[doc_id] = upload.book.id
                        linked = linked + 1
                    end
                end
            end
        end
        self:saveSettings()
        return linked
    end

    function R:syncUploads()
        if not self.books_sync_enabled then return 0 end
        local ok, err = pcall(function() self:checkUploads() end)
        if not ok then logger.warn("ReadwiseReader:syncUploads: check failed", err) end
        local files = self:findSideloadedEpubs()
        if not self.books_upload_baseline then
            for _, filepath in ipairs(files) do self.books_upload_skip[filepath] = true end
            self.books_upload_baseline = true
            self:saveSettings()
            return 0
        end
        if #files == 0 then return 0 end
        -- Readwise allows 10 uploads an hour.
        while #files > 10 do table.remove(files) end
        local names = {}
        for i, filepath in ipairs(files) do
            if i <= 5 then table.insert(names, "• " .. (filepath:match("([^/]+)$") or filepath)) end
        end
        if #files > 5 then table.insert(names, string.format("…and %d more", #files - 5)) end
        local uploaded = 0
        self:runAutomated("upload_epubs", string.format(
            "Upload %d book(s) from this device to Readwise?\n\n%s\n\nTo stop being asked about a book, "
                .. "open it and use Readwise Books → Never upload this book.",
            #files, table.concat(names, "\n")),
            function()
                for _, filepath in ipairs(files) do
                    self:showProgress("Uploading " .. (filepath:match("([^/]+)$") or filepath) .. "…")
                    local up_ok, up_err = self:uploadEpub(filepath)
                    if up_ok then
                        uploaded = uploaded + 1
                    else
                        logger.warn("ReadwiseReader:syncUploads: failed", filepath, up_err)
                    end
                end
                self:hideProgress()
            end)
        return uploaded
    end

    -- ------------------------------------------------------------------
    -- Menu
    -- ------------------------------------------------------------------

    function R:getAutomationMenuItems()
        local items = {}
        for _, action in ipairs(Automation.ACTIONS) do
            local sub = {}
            for _, mode in ipairs(Automation.MODES) do
                table.insert(sub, {
                    text = Automation.MODE_LABELS[mode],
                    radio = true,
                    checked_func = function() return self:automationMode(action.id) == mode end,
                    callback = function() self:setAutomationMode(action.id, mode) end,
                })
            end
            table.insert(items, {
                text_func = function()
                    return string.format("%s: %s", action.label,
                        Automation.MODE_LABELS[self:automationMode(action.id)])
                end,
                sub_item_table = sub,
            })
        end
        return items
    end

    local SHELF_LABELS = {
        { "want_to_read", "Want to read" },
        { "currently_reading", "Currently reading" },
        { "finished", "Finished" },
        { "did_not_finish", "Did not finish" },
    }

    function R:getBooksMenuItems()
        local items = {
            {
                text = "Sync with Readwise Books",
                help_text = "Opening a book marks it Currently reading in Readwise Books; finishing it, "
                    .. "putting it on hold, or rating it is sent too. Readwise Books changes reach "
                    .. "books on this device at sync. Each of these can be set to Automatic, Ask or "
                    .. "Manual under Automation.",
                checked_func = function() return self.books_sync_enabled end,
                callback = function()
                    self.books_sync_enabled = not self.books_sync_enabled
                    self:saveSettings()
                end,
            },
            {
                text = "Sync Readwise Books now",
                enabled_func = function() return self.books_sync_enabled end,
                callback = function()
                    self:runActionsNow({ "books_status", "books_remote" })
                end,
            },
        }
        local shelves = {}
        for _, pair in ipairs(SHELF_LABELS) do
            local shelf, label = pair[1], pair[2]
            table.insert(shelves, {
                text = label,
                checked_func = function() return self.books_download_shelves[shelf] == true end,
                callback = function()
                    self.books_download_shelves[shelf] = not self.books_download_shelves[shelf] or nil
                    self:saveSettings()
                end,
            })
        end
        table.insert(items, {
            text = "Download books on these shelves",
            help_text = "Only Reader books on the selected Readwise Books shelves are downloaded at sync. "
                .. "Books already on the device stay. Articles are not affected.",
            enabled_func = function() return self.books_sync_enabled end,
            sub_item_table = shelves,
        })
        table.insert(items, {
            text = "Add Want to read books to To Be Read",
            enabled_func = function() return self.books_sync_enabled end,
            checked_func = function() return self.books_tbr end,
            callback = function()
                self.books_tbr = not self.books_tbr
                self:saveSettings()
            end,
        })
        table.insert(items, {
            text = "Delete finished books automatically",
            help_text = "When off, books are never removed from this device by sync: not when "
                .. "finished, archived, or removed in Reader. Articles keep their current behaviour.",
            checked_func = function() return self.delete_finished_books end,
            callback = function()
                self.delete_finished_books = not self.delete_finished_books
                self:saveSettings()
            end,
        })
        table.insert(items, {
            text = "Keep current book on device",
            help_text = "This book is never deleted automatically, even when finished.",
            enabled_func = function()
                local book = self:getCurrentLocalBook()
                return book ~= nil and self:getReaderIdentity(book.filepath) ~= nil
            end,
            checked_func = function()
                local book = self:getCurrentLocalBook()
                local doc_id = book and self:getReaderIdentity(book.filepath)
                return doc_id ~= nil and self.books_keep[doc_id] == true
            end,
            callback = function()
                local book = self:getCurrentLocalBook()
                local doc_id = book and self:getReaderIdentity(book.filepath)
                if not doc_id then return end
                self.books_keep[doc_id] = not self.books_keep[doc_id] or nil
                self:saveSettings()
            end,
        })
        table.insert(items, {
            text_func = function()
                local count = 0
                for _ in pairs(self.books_keep) do count = count + 1 end
                return string.format("Books kept on device (%d)", count)
            end,
            sub_item_table_func = function()
                local list = {}
                for doc_id in pairs(self.books_keep) do
                    local meta = self.reader_metadata and self.reader_metadata[doc_id]
                    table.insert(list, {
                        text = (meta and meta.title or doc_id) .. "  (tap to stop keeping)",
                        callback = function()
                            self.books_keep[doc_id] = nil
                            self:saveSettings()
                        end,
                    })
                end
                if #list == 0 then
                    table.insert(list, { text = "No books kept", enabled = false })
                end
                return list
            end,
        })
        table.insert(items, {
            text = "Post reading sessions from this device",
            help_text = "Reading sessions come from KOReader's reading statistics. If several devices "
                .. "share statistics, turn this on for one device only, or sessions are counted twice.",
            enabled_func = function() return self.books_sync_enabled end,
            checked_func = function() return self.sessions_from_device end,
            callback = function()
                self.sessions_from_device = not self.sessions_from_device
                self:saveSettings()
            end,
        })
        table.insert(items, {
            text = "Share sessions to the Readwise Books feed",
            enabled_func = function() return self.books_sync_enabled and self.sessions_from_device end,
            checked_func = function() return self.sessions_publish end,
            callback = function()
                self.sessions_publish = not self.sessions_publish
                self:saveSettings()
            end,
        })
        table.insert(items, {
            text = "Upload current book to Readwise",
            enabled_func = function()
                local book = self:getCurrentLocalBook()
                return self.books_sync_enabled and book ~= nil and book.filepath:lower():match("%.epub$") ~= nil
                    and not self:getReaderIdentity(book.filepath)
            end,
            callback = function()
                local book = self:getCurrentLocalBook()
                if not book then return end
                NetworkMgr:runWhenOnline(function()
                    self:showProgress("Uploading to Readwise…")
                    local ok, err = self:uploadEpub(book.filepath)
                    self:hideProgress()
                    UIManager:show(InfoMessage:new{
                        text = ok and "Uploaded. It's linked to this file once Readwise finishes processing it (next sync)."
                            or ("Upload failed: " .. tostring(err)),
                    })
                end)
            end,
        })
        table.insert(items, {
            text = "Never upload this book",
            enabled_func = function()
                local book = self:getCurrentLocalBook()
                return book ~= nil and not self:getReaderIdentity(book.filepath)
            end,
            checked_func = function()
                local book = self:getCurrentLocalBook()
                return book ~= nil and self.books_upload_skip[book.filepath] == true
            end,
            callback = function()
                local book = self:getCurrentLocalBook()
                if not book then return end
                self.books_upload_skip[book.filepath] = not self.books_upload_skip[book.filepath] or nil
                self:saveSettings()
            end,
        })
        table.insert(items, {
            text = "Show Readwise Books entry for current book",
            enabled_func = function() return self:getCurrentLocalBook() ~= nil end,
            callback = function()
                local book = self:getCurrentLocalBook()
                local book_id, doc_id = self:getBooksIdForFile(book and book.filepath)
                local cached = book_id and self.books_cache[book_id]
                local text
                if not doc_id then
                    text = "This book isn't linked to Readwise Reader."
                elseif not book_id then
                    text = "No Readwise Books entry matched this book yet. Sync, or use Re-match books."
                else
                    text = string.format("Readwise Books id: %d\nShelf: %s\nRating: %s\nStarted: %s\nFinished: %s",
                        book_id, cached and cached.status or "?", cached and tostring(cached.rating or "-") or "?",
                        cached and (cached.started_reading_at or "-") or "?",
                        cached and (cached.finished_reading_at or "-") or "?")
                end
                UIManager:show(InfoMessage:new{ text = text })
            end,
        })
        table.insert(items, {
            text = "Re-match books",
            help_text = "Matches Reader books to Readwise Books entries again at the next sync.",
            callback = function()
                self.books_match_signature = nil
                self.books_ids = {}
                self:saveSettings()
                UIManager:show(InfoMessage:new{ text = "Books will be matched again at the next sync.", timeout = 3 })
            end,
        })
        return items
    end
end

return BooksSync
