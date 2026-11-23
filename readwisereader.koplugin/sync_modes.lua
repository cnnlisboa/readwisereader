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

SyncModes.AUTO_MODES = {
    { "off", "Off" },
    { "reading", "Reading data" },
    { "all", "Everything (Sync all)" },
}

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

    local function step(name, fn)
        local ok, result, extra = pcall(fn)
        if not ok then
            logger.warn("ReadwiseReader: sync step failed:", name, result)
            return nil
        end
        return result, extra
    end

    function R:initSyncModes(settings)
        -- When Reader positions were last checked; documents changed in
        -- Reader since then are the only ones fetched.
        self.positions_checked_at = settings.positions_checked_at
        self.auto_sync_mode = settings.auto_sync_mode or "all"
    end

    function R:syncModesSettingsForSave(settings)
        settings.positions_checked_at = self.positions_checked_at
        settings.auto_sync_mode = self.auto_sync_mode
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
        local changed, err, status = self.reader_api:listUpdatedSince(since)
        if not changed then
            logger.warn("ReadwiseReader:syncLocalPositions: list failed", err, status)
            return nil, err
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
            local exported, parse_err, failures = self:exportHighlights(only)
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
                    self:refreshReadwiseTagCache()
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

        -- Readwise Books: status, rating and dates of books here.
        local shelves, books_report = step("Readwise Books", function() return self:syncReadwiseBooks() end)
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

    -- After a book closes, once the file browser is back: the automatic sync,
    -- only when already online (never turns Wi-Fi on). The reader's plugin
    -- instance goes away with the book, so the file browser's instance runs it.
    function R:scheduleAutoSync()
        local mode = self.auto_sync_mode
        if mode == "off" or not self:hasAccessToken() then return end
        UIManager:scheduleIn(4, function()
            local ReaderUI = require("apps/reader/readerui")
            if ReaderUI.instance or not NetworkMgr:isOnline() then return end
            local plugin = FileManager.instance and FileManager.instance.readwisereader
            if not plugin or plugin.sync_running then return end
            Trapper:wrap(function()
                plugin:synchronize(mode == "reading" and "reading" or "all", true)
            end)
        end)
    end

    function R:getAutoSyncMenuItem()
        local modes = {}
        for _, pair in ipairs(SyncModes.AUTO_MODES) do
            local mode, label = pair[1], pair[2]
            table.insert(modes, {
                text = label,
                radio = true,
                checked_func = function() return self.auto_sync_mode == mode end,
                callback = function()
                    self.auto_sync_mode = mode
                    self:saveSettings()
                end,
            })
        end
        return {
            text_func = function()
                for _, pair in ipairs(SyncModes.AUTO_MODES) do
                    if pair[1] == self.auto_sync_mode then return "Sync after closing a book: " .. pair[2] end
                end
                return "Sync after closing a book"
            end,
            help_text = "Runs a few seconds after you close a book, only when Wi-Fi is already on. "
                .. "A summary shows only when something changed.",
            sub_item_table = modes,
        }
    end
end

return SyncModes
