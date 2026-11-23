-- What happens when a document is finished on this device, and which
-- documents are never removed automatically.
--
--   finish_scope    "articles" | "books" | "all" | "none"
--   finish_archive  archive finished documents in Reader
--   finish_delete   delete finished documents from this device
--   keep_on_device  Reader id -> { title = ... }: never deleted automatically
--
-- Replaces delete_finished_books / books_keep (books only): finished books
-- that were kept become "articles", kept books stay kept.
local FinishOptions = {}

FinishOptions.SCOPES = {
    { "articles", "Articles only" },
    { "books", "Books only" },
    { "all", "All documents" },
    { "none", "Nothing" },
}

-- Whether the finish actions apply to a document of this kind.
function FinishOptions.inScope(scope, is_book)
    if scope == "all" then return true end
    if scope == "books" then return is_book == true end
    if scope == "articles" then return is_book ~= true end
    return false
end

-- What to do with one finished document: { archive = bool, delete = bool }.
-- `archived` says it was archived already (kept documents are archived once).
function FinishOptions.plan(options, is_book, kept, archived)
    if not FinishOptions.inScope(options.scope, is_book) then
        return { archive = false, delete = false }
    end
    local delete = options.delete == true and not kept
    return {
        archive = options.archive == true and not archived,
        delete = delete,
    }
end

function FinishOptions.migrate(settings)
    local scope = settings.finish_scope
    if scope == nil then
        scope = settings.delete_finished_books == true and "all" or "articles"
    end
    local keep = settings.keep_on_device
    if type(keep) ~= "table" then
        keep = {}
        for doc_id in pairs(settings.books_keep or {}) do keep[doc_id] = {} end
    end
    return {
        scope = scope,
        archive = settings.finish_archive ~= false,
        delete = settings.finish_delete ~= false,
        keep = keep,
    }
end

function FinishOptions.install(R, deps)
    local DocSettings = deps.DocSettings
    local FileManager = deps.FileManager
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage

    function R:initFinishOptions(settings)
        local migrated = FinishOptions.migrate(settings)
        self.finish_scope = migrated.scope
        self.finish_archive = migrated.archive
        self.finish_delete = migrated.delete
        self.keep_on_device = migrated.keep
        -- Kept documents already archived in Reader, so it happens once.
        self.books_archived_kept = settings.books_archived_kept or {}
    end

    function R:finishSettingsForSave(settings)
        settings.finish_scope = self.finish_scope
        settings.finish_archive = self.finish_archive
        settings.finish_delete = self.finish_delete
        settings.keep_on_device = self.keep_on_device
        settings.books_archived_kept = self.books_archived_kept
        -- Old keys, so a downgrade still finds something sensible.
        settings.delete_finished_books = self.finish_scope == "all" or self.finish_scope == "books"
        settings.books_keep = nil
        return settings
    end

    function R:finishOptions()
        return { scope = self.finish_scope, archive = self.finish_archive, delete = self.finish_delete }
    end

    function R:isKeptOnDevice(doc_id)
        return doc_id ~= nil and self.keep_on_device[doc_id] ~= nil
    end

    -- Never removed automatically: kept by hand, or the finish settings
    -- don't delete this kind of document. Also guards removal of documents
    -- archived or deleted in Reader.
    function R:keepsOnDevice(doc_id, filepath)
        if self:isKeptOnDevice(doc_id) then return true end
        local is_book = self:isBookFile(doc_id, filepath)
        return not (self.finish_delete and FinishOptions.inScope(self.finish_scope, is_book))
    end

    function R:setKeptOnDevice(doc_id, keep, title)
        if not doc_id then return end
        self.keep_on_device[doc_id] = keep and { title = title } or nil
        self:saveSettings()
    end

    -- Finished documents on this device. `kinds` limits it to "books" or
    -- "articles" (nil: both). Highlights go first: archiving drops the
    -- Reader metadata their export is placed with, and a file is deleted
    -- only when its highlights are safe. Returns archived, deleted.
    function R:processFinishedDocuments(kinds)
        local archived_count, deleted_count = 0, 0
        local options = self:finishOptions()
        self:forEachLocalDocument(function(doc_id, filepath)
            if not DocSettings:hasSidecarFile(filepath) then return end
            local summary = DocSettings:open(filepath):readSetting("summary")
            if not (summary and summary.status == "complete") then return end
            local is_book = self:isBookFile(doc_id, filepath)
            if kinds == "books" and not is_book then return end
            if kinds == "articles" and is_book then return end
            local plan = FinishOptions.plan(options, is_book, self:isKeptOnDevice(doc_id),
                self.books_archived_kept[doc_id] == true)
            if plan.delete then
                if not self:highlightsSafeToRemove(filepath) then return end
                if plan.archive then
                    if not self:archiveDocument(doc_id) then return end
                    archived_count = archived_count + 1
                end
                FileManager:deleteFile(filepath, true)
                deleted_count = deleted_count + 1
                self.books_archived_kept[doc_id] = nil
            elseif plan.archive and self:archiveDocument(doc_id) then
                self.books_archived_kept[doc_id] = true
                archived_count = archived_count + 1
            end
        end)
        self:saveSettings()
        return archived_count, deleted_count
    end

    -- The open document's Reader id and title, for "Keep on device".
    function R:currentReaderDocument()
        local filepath = self.ui and self.ui.document and self.ui.document.file
        local doc_id = filepath and self:getReaderIdentity(filepath)
        if not doc_id then return nil end
        local props = self.ui.doc_props or {}
        return doc_id, props.display_title or props.title or filepath:match("([^/]+)$")
    end

    function R:getFinishMenuItems()
        local items = {}
        local scopes = {}
        for _, pair in ipairs(FinishOptions.SCOPES) do
            local scope, label = pair[1], pair[2]
            table.insert(scopes, {
                text = label,
                radio = true,
                checked_func = function() return self.finish_scope == scope end,
                callback = function()
                    self.finish_scope = scope
                    self:saveSettings()
                end,
            })
        end
        table.insert(items, {
            text_func = function()
                for _, pair in ipairs(FinishOptions.SCOPES) do
                    if pair[1] == self.finish_scope then return "When I finish: " .. pair[2] end
                end
                return "When I finish"
            end,
            help_text = "Which finished documents are archived in Reader and deleted from this device. "
                .. "Documents archived or removed in Reader follow the same choice.",
            sub_item_table = scopes,
        })
        table.insert(items, {
            text = "Archive in Reader",
            enabled_func = function() return self.finish_scope ~= "none" end,
            checked_func = function() return self.finish_archive end,
            callback = function()
                self.finish_archive = not self.finish_archive
                self:saveSettings()
            end,
        })
        table.insert(items, {
            text = "Delete from this device",
            enabled_func = function() return self.finish_scope ~= "none" end,
            checked_func = function() return self.finish_delete end,
            callback = function()
                self.finish_delete = not self.finish_delete
                self:saveSettings()
            end,
            separator = true,
        })
        table.insert(items, {
            text = "Keep this document on device",
            help_text = "Never deleted automatically: not when finished, archived, or removed in Reader.",
            enabled_func = function() return self:currentReaderDocument() ~= nil end,
            checked_func = function()
                local doc_id = self:currentReaderDocument()
                return self:isKeptOnDevice(doc_id)
            end,
            callback = function()
                local doc_id, title = self:currentReaderDocument()
                if doc_id then self:setKeptOnDevice(doc_id, not self:isKeptOnDevice(doc_id), title) end
            end,
        })
        table.insert(items, {
            text_func = function()
                local count = 0
                for _ in pairs(self.keep_on_device) do count = count + 1 end
                return string.format("Kept on device (%d)", count)
            end,
            sub_item_table_func = function()
                local list = {}
                for doc_id, entry in pairs(self.keep_on_device) do
                    local meta = self.reader_metadata and self.reader_metadata[doc_id]
                    local title = (type(entry) == "table" and entry.title) or (meta and meta.title) or doc_id
                    table.insert(list, {
                        text = title .. "  (tap to stop keeping)",
                        callback = function()
                            self:setKeptOnDevice(doc_id, false)
                            UIManager:show(InfoMessage:new{ text = "No longer kept: " .. title, timeout = 2 })
                        end,
                    })
                end
                table.sort(list, function(a, b) return a.text < b.text end)
                if #list == 0 then
                    table.insert(list, { text = "Nothing kept", enabled = false })
                end
                return list
            end,
        })
        return items
    end
end

return FinishOptions
