-- The three syncs (decided 2026-11-23). Reading positions always come first,
-- then highlights and notes, then books, then articles:
--
--   Sync reading data  documents already on the device, books first:
--                      positions, highlights between readers (Device Sync),
--                      highlights and notes to Readwise, highlight tags,
--                      the Writer Deck book note, Readwise Books status and
--                      rating, reading sessions. Nothing is downloaded,
--                      uploaded, archived or deleted.
--   Sync books         reading data for books, then books from the chosen
--                      Readwise Books shelves, uploads, finished books.
--   Sync all           reading data, then the full sync (books before
--                      articles): downloads, removals, finished documents.
--
-- Each step runs on its own: one that fails is logged and the next runs.
local SyncModes = {}

-- What runs a few seconds after a book closes.
SyncModes.AUTO_MODES = {
    { "book", "That book only (quick)" },
    { "reading", "Reading data" },
    { "all", "Everything (Sync all)" },
    { "off", "Off" },
}

SyncModes.PAGE_SYNC_EVERY = 10
SyncModes.PAGE_SYNC_MIN_SECONDS = 60
SyncModes.TAG_CACHE_SECONDS = 24 * 3600
SyncModes.BOOKS_MIN_SECONDS = 5 * 60
-- Reader locations positions are checked in. Feed is left out: it changes
-- constantly and nothing there is downloaded.
SyncModes.POSITION_LOCATIONS = { "new", "later", "shortlist", "archive" }

-- Documents first by kind: books, then the rest, each in a stable order.
function SyncModes.booksFirst(list, is_book)
    local books, rest = {}, {}
    for _, item in ipairs(list) do
        table.insert(is_book(item) and books or rest, item)
    end
    for _, item in ipairs(rest) do table.insert(books, item) end
    return books
end

local function iso(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

function SyncModes.install(R, deps)
    local logger = deps.logger
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage
    local NetworkMgr = deps.NetworkMgr
    local Trapper = deps.Trapper
    local FileManager = deps.FileManager

    -- One step of a sync: errors are logged and the next step runs. How
    -- long each step took goes to the log, to find what is slow on a device.
    local function step(name, fn)
        local started = os.time()
        local results = { pcall(fn) }
        logger.info("ReadwiseReader: sync step", name, "took", os.time() - started, "s")
        if not results[1] then
            logger.warn("ReadwiseReader: sync step failed:", name, results[2])
            return nil
        end
        return unpack(results, 2, table.maxn(results))
    end

    function R:initSyncModes(settings)
        -- When Reader positions were last checked; documents changed in
        -- Reader since then are the only ones fetched.
        self.positions_checked_at = settings.positions_checked_at
        -- When highlights were last exported in full: only sidecars changed
        -- since are read next time.
        self.highlights_parsed_at = settings.highlights_parsed_at
        self.tag_cache_refreshed_at = settings.tag_cache_refreshed_at
        self.books_synced_at = settings.books_synced_at
        -- "book" (default), "reading", "all" or "off". A new key: an earlier
        -- build saved "all" as auto_sync_mode.
        self.close_sync_mode = settings.close_sync_mode or "book"
        self.page_sync = settings.page_sync ~= false
    end

    function R:syncModesSettingsForSave(settings)
        settings.positions_checked_at = self.positions_checked_at
        settings.highlights_parsed_at = self.highlights_parsed_at
        settings.tag_cache_refreshed_at = self.tag_cache_refreshed_at
        settings.books_synced_at = self.books_synced_at
        settings.close_sync_mode = self.close_sync_mode
        settings.page_sync = self.page_sync
        settings.auto_sync_mode = nil
        return settings
    end

    -- ------------------------------------------------------------------
    -- Positions
    -- ------------------------------------------------------------------

    -- Positions of documents on this device (kinds: "books" or nil for all),
    -- books first. Reader is asked only for documents changed since the last
    -- check; a document that moved here is pushed after a fresh read.
    -- Returns { seeded, pushed } or nil, err.
    function R:syncLocalPositions(kinds)
        if not self.sync_reading_progress then return { seeded = 0, pushed = 0 } end
        local started = os.time()
        local since = self.positions_checked_at or iso(started - 30 * 86400)
        local changed, seen = {}, {}
        for _, location in ipairs(SyncModes.POSITION_LOCATIONS) do
            local list, err, status = self.reader_api:listUpdatedSince(since, nil, location)
            if not list then
                logger.warn("ReadwiseReader:syncLocalPositions: list failed", location, err, status)
                return nil, err
            end
            for _, document in ipairs(list) do
                if not seen[document.id] then
                    seen[document.id] = true
                    table.insert(changed, document)
                end
            end
        end
        local local_paths = self:getLocalDocumentPaths()
        local function isBook(doc_id) return self:isBookFile(doc_id, local_paths[doc_id]) end

        local here, changed_ids = {}, {}
        for _, document in ipairs(changed) do
            if local_paths[document.id] and (kinds ~= "books" or isBook(document.id)) then
                table.insert(here, document)
                changed_ids[document.id] = true
            end
        end
        here = SyncModes.booksFirst(here, function(document) return isBook(document.id) end)
        local seeded, pushed = self:reconcileReadingProgress(here)

        -- Unchanged in Reader: push only what moved here (checked without
        -- the network first by pushReadingProgress).
        local ids = {}
        for doc_id in pairs(local_paths) do
            if not changed_ids[doc_id] and (kinds ~= "books" or isBook(doc_id)) then table.insert(ids, doc_id) end
        end
        table.sort(ids)
        ids = SyncModes.booksFirst(ids, isBook)
        for _, doc_id in ipairs(ids) do
            local ok, moved = pcall(function()
                local percent, _, finished = self:readLocalProgressState(local_paths[doc_id])
                return self:pushReadingProgress(doc_id, percent, nil, nil, finished)
            end)
            if ok and moved then pushed = (pushed or 0) + 1 end
        end
        -- A minute of overlap: a change made while this ran is seen next time.
        self.positions_checked_at = iso(started - 60)
        self:saveSettings()
        return { seeded = seeded or 0, pushed = pushed or 0 }
    end

    -- ------------------------------------------------------------------
    -- Device Sync
    -- ------------------------------------------------------------------

    -- Highlights, notes and bookmarks between readers, plus Writer Deck
    -- notes, through the Device Sync plugin when it is installed. Returns its
    -- report or nil.
    function R:runDeviceSync()
        local device_sync = self.ui and self.ui.device_sync
        if type(device_sync) ~= "table" or type(device_sync.syncReadingDataQuietly) ~= "function" then
            return nil
        end
        local ok, report, err = pcall(device_sync.syncReadingDataQuietly, device_sync)
        if not ok then
            logger.warn("ReadwiseReader:runDeviceSync: failed", report)
            return nil
        end
        if not report then logger.dbg("ReadwiseReader:runDeviceSync: skipped", err) end
        return report
    end

    -- ------------------------------------------------------------------
    -- Reading data
    -- ------------------------------------------------------------------

    -- Local book ids (downloaded EPUBs and linked books) as a set.
    function R:localBookIds()
        local ids = {}
        for doc_id in pairs(self:getLocalBooks()) do ids[doc_id] = true end
        return ids
    end

    -- Runs inside a sync coroutine. kinds = "books" limits positions and
    -- highlights to books. Returns a report the callers turn into lines.
    function R:syncReadingData(kinds)
        local report = { highlights = 0, tags = 0, lines = {} }

        self:flushPendingLinkSaves(false)
        self:flushPendingTagUpdates(false)
        self:flushPendingNoteUpdates(false)
        step("progress notes", function() self:cleanupProgressNotes() end)

        self:showProgress("Syncing reading positions…")
        local positions = step("positions", function() return self:syncLocalPositions(kinds) end)
        if positions and positions.seeded + positions.pushed > 0 then
            table.insert(report.lines, string.format("Reading positions: %d updated here, %d sent",
                positions.seeded, positions.pushed))
        end

        -- Highlights from the other reader first, so one that already
        -- reached Reader from there is recognised, not placed again.
        self:showProgress("Syncing highlights between your readers…")
        local device = self:runDeviceSync()
        if device and ((device.sent or 0) + (device.received or 0)) > 0 then
            table.insert(report.lines, string.format("Between readers: %d sent, %d updated here",
                device.sent or 0, device.received or 0))
        end

        self.export_highlights_at_sync = self:automationMode("send_highlights") ~= "manual"
        local export_now = false
        self:runAutomated("send_highlights", "Send highlights to Readwise now?", function() export_now = true end)
        if export_now then
            self.reader_ids_stamped = 0
            local only = kinds == "books" and self:localBookIds() or nil
            -- Only sidecars changed since the last full export are read; a
            -- books-only export reads them too but doesn't move the mark.
            local started = os.time()
            local options = {
                since = self.highlights_parsed_at and (self.highlights_parsed_at - 5) or nil,
                checkpoint = not only and started or nil,
            }
            local exported, parse_err, failures = step("highlights", function()
                return self:exportHighlights(only, options)
            end)
            report.highlights = exported or 0
            self.sync_highlights_ok = not parse_err and failures == 0
            if parse_err then
                table.insert(report.lines, "Highlights: not sent (" .. tostring(parse_err) .. ")")
            elseif report.highlights > 0 then
                table.insert(report.lines, string.format("Highlights sent: %d", report.highlights))
            end
        end

        local has_pending_tags = false
        for _, entry in pairs(self.highlight_tags) do
            if entry.pending then has_pending_tags = true break end
        end
        if has_pending_tags then
            self:runAutomated("highlight_tags", "Apply highlight tags in Readwise?", function()
                report.tags = step("highlight tags", function()
                    -- The tag list is for the picker: once a day is enough.
                    if os.time() - (self.tag_cache_refreshed_at or 0) > SyncModes.TAG_CACHE_SECONDS then
                        self:refreshReadwiseTagCache()
                        self.tag_cache_refreshed_at = os.time()
                    end
                    return self:applyPendingHighlightTags()
                end) or 0
            end)
            if report.tags > 0 then
                table.insert(report.lines, string.format("Highlight tags applied: %d", report.tags))
            end
        end

        if self.syncBookNotes then
            local notes = step("book notes", function() return self:syncBookNotes(kinds) end)
            if notes and (notes.sent + notes.received) > 0 then
                table.insert(report.lines, string.format("Book notes: %d sent, %d updated here",
                    notes.sent, notes.received))
            end
            if notes and notes.conflicts > 0 then
                table.insert(report.lines, string.format("Book notes changed on both sides (look for ⚠): %d",
                    notes.conflicts))
            end
        end

        -- Readwise Books: status, rating and dates of books here. Opening and
        -- closing a book already sends its own changes, so a sync within a
        -- few minutes of the last one skips the full library request.
        local shelves, books_report
        -- Sync books and Sync all always fetch it: their downloads need the shelves.
        if kinds == "all" or kinds == "books"
            or os.time() - (self.books_synced_at or 0) >= SyncModes.BOOKS_MIN_SECONDS then
            shelves, books_report = step("Readwise Books", function() return self:syncReadwiseBooks() end)
            if books_report then self.books_synced_at = os.time() end
        end
        report.books_shelves, report.books_report = shelves, books_report
        if books_report then
            books_report.sessions = step("sessions", function() return self:syncSessions() end) or 0
        end

        -- Reader ids written onto highlights travel to the other reader now.
        if (self.reader_ids_stamped or 0) > 0 and device then
            self:runDeviceSync()
        end
        self:hideProgress()
        return report
    end

    local function booksLine(books_report)
        if books_report and (books_report.sent > 0 or books_report.applied > 0 or books_report.queued > 0
            or (books_report.sessions or 0) > 0 or (books_report.uploaded or 0) > 0) then
            return string.format("Readwise Books: %d sent, %d applied here%s%s%s",
                books_report.sent, books_report.applied,
                (books_report.sessions or 0) > 0 and string.format(", %d session(s)", books_report.sessions) or "",
                (books_report.uploaded or 0) > 0 and string.format(", %d uploaded", books_report.uploaded) or "",
                books_report.queued > 0 and string.format(", %d waiting", books_report.queued) or "")
        end
    end
    R.readingBooksLine = booksLine

    function R:showSyncSummary(title, lines)
        if #lines == 0 then
            if self.sync_quiet then return end
            lines = { "Nothing new." }
        end
        UIManager:show(InfoMessage:new{ text = title .. "\n" .. table.concat(lines, "\n") })
        if FileManager.instance then FileManager.instance:onRefresh() end
    end

    function R:runReadingDataSync()
        if not self:validateSettings() then return end
        self.api_call_count, self.sync_start_time, self.needs_rate_limiting = 0, nil, false
        local reading = self:syncReadingData()
        local lines = reading.lines
        local books_line = booksLine(reading.books_report)
        if books_line then table.insert(lines, books_line) end
        self:showSyncSummary("Reading data synced:", lines)
    end

    -- ------------------------------------------------------------------
    -- Books
    -- ------------------------------------------------------------------

    -- Reader books on the chosen Readwise Books shelves that aren't on the
    -- device yet. Returns { downloaded, failed, held } or nil.
    function R:downloadShelfBooks()
        if not self.books_sync_enabled then return nil end
        local shelves = self:loadBooksShelves()
        if not shelves then return nil end
        local here = self:getLocalDocumentPaths()
        for doc_id in pairs(self:getLinkedReaderIds()) do here[doc_id] = true end
        local wanted = {}
        for shelf, on in pairs(self.books_download_shelves) do
            if on and shelves[shelf] then
                for _, document in ipairs(shelves[shelf].documents) do
                    if not here[document.id] and document.location ~= "feed" then
                        table.insert(wanted, document)
                    end
                end
            end
        end
        if #wanted == 0 then return { downloaded = 0, failed = 0, held = 0 } end
        local go = false
        self:runAutomated("download_books", string.format("Download %d book(s) from Readwise?", #wanted),
            function() go = true end)
        if not go then return { downloaded = 0, failed = 0, held = #wanted } end
        local result = self:downloadReaderDocuments(wanted)
        return { downloaded = result.downloaded or 0, failed = result.failed or 0, held = 0 }
    end

    function R:runBooksSync()
        if not self:validateSettings() then return end
        self.api_call_count, self.sync_start_time, self.needs_rate_limiting = 0, nil, false
        local reading = self:syncReadingData("books")
        local lines = reading.lines

        if not self.books_sync_enabled then
            table.insert(lines, "Turn on Readwise Books sync to get books from your shelves.")
        else
            local got = step("shelf downloads", function() return self:downloadShelfBooks() end)
            if got and got.downloaded > 0 then table.insert(lines, string.format("Books downloaded: %d", got.downloaded)) end
            if got and got.failed > 0 then table.insert(lines, string.format("Books not downloaded: %d", got.failed)) end
            if got and got.held > 0 then
                table.insert(lines, string.format("Books waiting to be downloaded (Automation): %d", got.held))
            end
            if reading.books_report then
                reading.books_report.uploaded = step("uploads", function() return self:syncUploads() end) or 0
            end
        end
        local books_line = booksLine(reading.books_report)
        if books_line then table.insert(lines, books_line) end

        local archive_now = false
        self:runAutomated("archive_finished", "Archive and delete finished books now?",
            function() archive_now = true end)
        if archive_now then
            local archived, deleted = step("finished books", function() return self:processFinishedDocuments("books") end)
            if archived and archived > 0 then table.insert(lines, string.format("Archived in Readwise: %d", archived)) end
            if deleted and deleted > 0 then table.insert(lines, string.format("Deleted locally: %d", deleted)) end
        end
        self:showSyncSummary("Books synced:", lines)
    end

    -- ------------------------------------------------------------------
    -- Entry points
    -- ------------------------------------------------------------------

    -- mode: "reading", "books" or "all" (default). quiet: no summary when
    -- nothing changed (automatic syncs).
    function R:startSync(mode, quiet)
        if self.sync_running then
            if not quiet then
                UIManager:show(InfoMessage:new{ text = "A sync is already running.", timeout = 2 })
            end
            return
        end
        NetworkMgr:runWhenOnline(function()
            self:synchronize(mode, quiet)
        end)
    end

    -- ------------------------------------------------------------------
    -- Automatic: closing a book, every few pages
    -- ------------------------------------------------------------------

    -- One closed book, a few requests and no library scan. Its position,
    -- Readwise Books status and session, and Device Sync's record were
    -- already sent when it closed; this adds its highlights and notes, tags,
    -- its book note, and passes new Reader ids on to the other readers.
    function R:quickBookSync(filepath)
        local doc_id = self:getReaderIdentity(filepath)
        local lines = {}
        self.reader_ids_stamped = 0
        if self:automationMode("send_highlights") == "auto" then
            local exported = step("highlights (one book)", function()
                return self:exportHighlights(nil, { files = { [filepath] = true } })
            end)
            if exported and exported > 0 then table.insert(lines, string.format("Highlights sent: %d", exported)) end
        end
        if self:automationMode("highlight_tags") == "auto" then
            local tags = step("highlight tags", function() return self:applyPendingHighlightTags() end)
            if tags and tags > 0 then table.insert(lines, string.format("Highlight tags applied: %d", tags)) end
        end
        if doc_id and self.syncBookNotes then
            local notes = step("book note", function() return self:syncBookNotes(nil, doc_id) end)
            if notes and notes.sent + notes.received > 0 then table.insert(lines, "Book note synced") end
        end
        if (self.reader_ids_stamped or 0) > 0 then
            local device_sync = self.ui and self.ui.device_sync
            if device_sync and device_sync.syncPathQuietly then
                step("Device Sync (one book)", function() return device_sync:syncPathQuietly(filepath) end)
            end
        end
        self:hideProgress()
        if #lines > 0 then
            UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), timeout = 2 })
        end
    end

    -- After a book closes, once the file browser is back, only when already
    -- online (never turns Wi-Fi on). The reader's plugin instance goes away
    -- with the book, so the file browser's instance runs it.
    function R:scheduleAutoSync(filepath)
        local mode = self.close_sync_mode
        if mode == "off" or not self:hasAccessToken() then return end
        UIManager:scheduleIn(4, function()
            local ReaderUI = require("apps/reader/readerui")
            if ReaderUI.instance or not NetworkMgr:isOnline() then return end
            local plugin = FileManager.instance and FileManager.instance.readwisereader
            if not plugin or plugin.sync_running then return end
            Trapper:wrap(function()
                if mode == "book" then
                    if not filepath then return end
                    plugin.sync_running = true
                    local ok, err = pcall(plugin.quickBookSync, plugin, filepath)
                    plugin.sync_running = false
                    if not ok then logger.warn("ReadwiseReader: quick sync failed", err) end
                else
                    plugin:synchronize(mode == "reading" and "reading" or "all", true)
                end
            end)
        end)
    end

    -- Every PAGE_SYNC_EVERY page turns (and at most once a minute), the open
    -- document's position goes to Reader. Only when already online, never
    -- with a question.
    function R:onPageUpdate()
        if not self.page_sync or not self.sync_reading_progress then return end
        self.pages_since_sync = (self.pages_since_sync or 0) + 1
        if self.pages_since_sync < SyncModes.PAGE_SYNC_EVERY then return end
        if os.time() - (self.page_synced_at or 0) < SyncModes.PAGE_SYNC_MIN_SECONDS then return end
        if not NetworkMgr:isOnline() then return end
        self.pages_since_sync, self.page_synced_at = 0, os.time()
        UIManager:nextTick(function()
            local ok, err = pcall(self.pushOpenDocumentProgress, self, "pages")
            if not ok then logger.warn("ReadwiseReader: page position push failed", err) end
        end)
    end

    function R:getAutoSyncMenuItem(separator)
        local modes = {}
        for _, pair in ipairs(SyncModes.AUTO_MODES) do
            local mode, label = pair[1], pair[2]
            table.insert(modes, {
                text = label,
                radio = true,
                checked_func = function() return self.close_sync_mode == mode end,
                callback = function()
                    self.close_sync_mode = mode
                    self:saveSettings()
                end,
            })
        end
        modes[#modes].separator = true
        table.insert(modes, {
            text = string.format("Send position every %d pages", SyncModes.PAGE_SYNC_EVERY),
            help_text = "While reading, sends your position to Readwise Reader every few pages (at most "
                .. "once a minute), only when Wi-Fi is already on. Opening, closing and sleep always send it.",
            checked_func = function() return self.page_sync end,
            callback = function()
                self.page_sync = not self.page_sync
                self:saveSettings()
            end,
        })
        return {
            text_func = function()
                for _, pair in ipairs(SyncModes.AUTO_MODES) do
                    if pair[1] == self.close_sync_mode then return "Automatic sync: " .. pair[2] end
                end
                return "Automatic sync"
            end,
            help_text = "What syncs on its own a few seconds after you close a book (only when Wi-Fi is "
                .. "already on), and the position while you read.",
            sub_item_table = modes,
            separator = separator,
        }
    end
end

return SyncModes
