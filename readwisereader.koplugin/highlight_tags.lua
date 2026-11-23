-- Readwise tags on highlights, chosen while reading (PLAN D.7).
--
-- A "Readwise tags…" button in KOReader's highlight menu opens the tag
-- picker. The choice is stored per highlight (by annotation key) and applied
-- at sync, once the highlight exists in Readwise:
--   * placed in Reader: the Reader highlight document's tags (v3);
--   * sent through v2: the highlight's v2 tags.
-- Real tags are used rather than ".tag" text in the note (decided 2026-11-23).
local HighlightsAPI = require("api/highlights")
local Ledger = require("library/highlight_ledger")

local HighlightTags = {}

HighlightTags.DEFAULT_FAVOURITES = { "reference/book", "reference/person", "reference/research",
    "chapter", "h1", "h2", "h3" }

-- KOReader stores "YYYY-MM-DD HH:MM:SS"; clip.lua turns it into epoch the
-- same way, which is what the annotation key is built from.
function HighlightTags.datetimeToEpoch(datetime)
    if type(datetime) ~= "string" then return nil end
    local y, mo, d, h, mi, s = datetime:match("(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d+):(%d+):(%d+)")
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

function HighlightTags.keyForAnnotation(item)
    if type(item) ~= "table" then return nil end
    return HighlightsAPI.annotationKey({ time = HighlightTags.datetimeToEpoch(item.datetime), pn_xp = item.page })
end

-- Differences between what is wanted and what was applied.
function HighlightTags.diff(wanted, applied)
    local want, have = {}, {}
    for _, name in ipairs(wanted or {}) do want[name:lower()] = name end
    for _, name in ipairs(applied or {}) do have[name:lower()] = name end
    local add, remove = {}, {}
    for key, name in pairs(want) do if not have[key] then table.insert(add, name) end end
    for key, name in pairs(have) do if not want[key] then table.insert(remove, name) end end
    table.sort(add)
    table.sort(remove)
    return add, remove
end

function HighlightTags.install(R, deps)
    local logger = deps.logger
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage
    local TagPicker = deps.TagPicker
    local HIGHLIGHTS_API_ENDPOINT = deps.HIGHLIGHTS_API_ENDPOINT

    function R:initHighlightTags(settings)
        -- annotation key -> { tags = {...}, applied = {...}, pending = bool, title, created }
        self.highlight_tags = settings.highlight_tags or {}
        self.readwise_tag_cache = settings.readwise_tag_cache or {}
        self.highlight_tag_favourites = settings.highlight_tag_favourites or HighlightTags.DEFAULT_FAVOURITES
    end

    function R:highlightTagsSettingsForSave(settings)
        settings.highlight_tags = self.highlight_tags
        settings.readwise_tag_cache = self.readwise_tag_cache
        settings.highlight_tag_favourites = self.highlight_tag_favourites
        return settings
    end

    function R:registerHighlightTagsButton()
        local highlight = self.ui and self.ui.highlight
        if not (highlight and highlight.addToHighlightDialog) or self.highlight_tags_button then
            return
        end
        self.highlight_tags_button = true
        highlight:addToHighlightDialog("12_readwise_tags", function(this, index)
            return {
                text = "Readwise tags…",
                callback = function()
                    -- A fresh selection becomes a highlight first.
                    local idx = index or this:saveHighlight(true)
                    local item = idx and this.ui.annotation and this.ui.annotation.annotations[idx]
                    this:onClose()
                    if item then
                        self:showHighlightTagPicker(item)
                    end
                end,
            }
        end)
    end

    function R:allHighlightTagNames()
        local names = {}
        for _, list in ipairs({ self.highlight_tag_favourites, self.readwise_tag_cache, self:getKnownTagNames() }) do
            for _, name in ipairs(list or {}) do table.insert(names, name) end
        end
        return names
    end

    function R:showHighlightTagPicker(item)
        local key = HighlightTags.keyForAnnotation(item)
        if not key then
            UIManager:show(InfoMessage:new{ text = "This highlight can't be tagged (it has no date).", timeout = 3 })
            return
        end
        local entry = self.highlight_tags[key] or {}
        TagPicker.show{
            title = "Readwise tags",
            all_tags = self:allHighlightTagNames(),
            selected = entry.tags or {},
            parse = function(text)
                local names = {}
                for piece in tostring(text):gmatch("[^,\n]+") do
                    local name = piece:match("^%s*(.-)%s*$")
                    if name ~= "" then table.insert(names, name) end
                end
                return names
            end,
            on_save = function(names)
                entry.tags = names
                entry.pending = true
                entry.created = entry.created or os.time()
                entry.title = entry.title or (item.text and item.text:sub(1, 60))
                self.highlight_tags[key] = entry
                self:saveSettings()
                UIManager:show(InfoMessage:new{
                    text = "Tags saved. They reach Readwise at the next sync.",
                    timeout = 2,
                })
            end,
        }
    end

    -- Where a highlight lives in Readwise: { reader_id } or { v2_id } or nil.
    function R:findHighlightTarget(key)
        for _, records in pairs(self.reader_highlight_records or {}) do
            local record = records[key]
            if record and record.id and not record.gone and not record.fallback then
                return { reader_id = record.id }
            end
        end
        local entry = self.highlight_ledger and self.highlight_ledger[key]
        if entry and entry.v2_id then
            return { v2_id = entry.v2_id }
        end
        return nil
    end

    function R:v2TagRequest(method, endpoint, body)
        return self:callAPI(method, endpoint, body, true, HIGHLIGHTS_API_ENDPOINT)
    end

    function R:applyV2Tags(v2_id, add, remove)
        for _, name in ipairs(add) do
            local ok, err, code = self:v2TagRequest("POST", "/highlights/" .. v2_id .. "/tags/", { name = name })
            if not ok then return false, err, code end
        end
        if #remove > 0 then
            local list, err, code = self:v2TagRequest("GET", "/highlights/" .. v2_id .. "/tags/")
            if type(list) ~= "table" then return false, err, code end
            local by_name = {}
            for _, tag in ipairs(list.results or list) do
                if type(tag) == "table" and tag.name then by_name[tag.name:lower()] = tag.id end
            end
            for _, name in ipairs(remove) do
                local tag_id = by_name[name:lower()]
                if tag_id then
                    local ok, del_err, del_code = self:v2TagRequest("DELETE",
                        "/highlights/" .. v2_id .. "/tags/" .. tag_id .. "/")
                    if not ok then return false, del_err, del_code end
                end
            end
        end
        return true
    end

    -- Sync step, after highlights were sent. Returns the number applied.
    function R:applyPendingHighlightTags()
        local pending = {}
        for key, entry in pairs(self.highlight_tags) do
            if entry.pending then table.insert(pending, key) end
        end
        if #pending == 0 then return 0 end

        -- v2 ids of highlights sent moments ago come from a fresh export.
        local missing, oldest = false, os.time()
        for _, key in ipairs(pending) do
            if not self:findHighlightTarget(key) then
                missing = true
                oldest = math.min(oldest, self.highlight_tags[key].created or oldest)
            end
        end
        if missing and self.fetchV2Export then
            local since = os.date("!%Y-%m-%dT%H:%M:%SZ", oldest - 86400)
            local export = self:fetchV2Export(since)
            if export then
                Ledger.recordRemoteIds(self.highlight_ledger, Ledger.indexExport(export))
            end
        end

        local applied = 0
        for _, key in ipairs(pending) do
            local entry = self.highlight_tags[key]
            local target = self:findHighlightTarget(key)
            if target then
                local add, remove = HighlightTags.diff(entry.tags, entry.applied)
                local ok, err, code
                if #add == 0 and #remove == 0 then
                    ok = true
                elseif target.reader_id then
                    ok, err, code = self.reader_api:applyTagChange(target.reader_id, add, remove)
                else
                    ok, err, code = self:applyV2Tags(target.v2_id, add, remove)
                end
                if ok then
                    entry.applied = entry.tags
                    entry.pending = false
                    applied = applied + 1
                else
                    logger.warn("ReadwiseReader:applyPendingHighlightTags: failed", key, err, code)
                end
            elseif os.time() - (entry.created or 0) > 30 * 86400 then
                -- Never reached Readwise (deleted before sync?): stop trying.
                entry.pending = false
            end
        end
        self:saveSettings()
        return applied
    end

    -- Tag list for the picker, cached for offline use. Refreshed at sync.
    function R:refreshReadwiseTagCache()
        local names = self.reader_api:listTags()
        if type(names) == "table" and #names > 0 then
            self.readwise_tag_cache = names
        end
    end
end

return HighlightTags
