-- Reader list adapter for metadata-only UI flows. Transport/authentication stay
-- with main.lua's established callAPI implementation.
local Reader = {}
Reader.__index = Reader

local PAGE_SIZE = 25

local function queryEscape(value)
    return tostring(value):gsub("([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
end

local function stringOrNil(value)
    return type(value) == "string" and value ~= "" and value or nil
end

local function normalizeTags(tags)
    if type(tags) ~= "table" then
        return nil
    end
    local normalized = {}
    for _, tag in pairs(tags) do
        local name = type(tag) == "table" and (tag.name or tag.key) or tag
        if type(name) == "string" and name ~= "" then
            table.insert(normalized, name)
        end
    end
    table.sort(normalized)
    return #normalized > 0 and normalized or nil
end

local function readingTimeOrNil(value)
    if type(value) == "number" and value >= 0 then
        return tostring(math.floor(value + 0.5)) .. " min"
    end
    return stringOrNil(value)
end

function Reader:new(options)
    assert(type(options) == "table" and type(options.request) == "function", "Reader request adapter required")
    return setmetatable({ request = options.request }, self)
end

function Reader.normalizeDocument(document)
    if type(document) ~= "table" or not stringOrNil(document.id) then
        return nil
    end
    return {
        id = document.id,
        title = stringOrNil(document.title) or "Untitled",
        author = stringOrNil(document.author),
        site_name = stringOrNil(document.site_name),
        category = stringOrNil(document.category),
        location = stringOrNil(document.location),
        reading_time = readingTimeOrNil(document.reading_time),
        reading_progress = type(document.reading_progress) == "number" and document.reading_progress or nil,
        image_url = stringOrNil(document.image_url),
        source_url = stringOrNil(document.source_url),
        -- The document note is used only to preserve unrelated user text while
        -- a manual KOReader progress action replaces its own marked line.
        notes = stringOrNil(document.notes),
        summary = stringOrNil(document.summary),
        updated_at = stringOrNil(document.updated_at),
        -- Reader read-only activity timestamps. last_opened_at is the freshness
        -- signal the progress reconciler compares against local sidecar mtime;
        -- Reader returns null for a document that was never opened.
        first_opened_at = stringOrNil(document.first_opened_at),
        last_opened_at = stringOrNil(document.last_opened_at),
        saved_at = stringOrNil(document.saved_at),
        last_moved_at = stringOrNil(document.last_moved_at),
        tags = normalizeTags(document.tags),
        url = stringOrNil(document.url),
        parent_id = stringOrNil(document.parent_id),
        html_content = stringOrNil(document.html_content),
    }
end

-- Turns what a user typed ("a, b,, A") into a clean tag list: split on commas
-- or newlines, trimmed, empties dropped, and case-insensitive duplicates
-- collapsed (the first spelling wins), keeping the order given.
function Reader.parseTags(text)
    local tags, seen = {}, {}
    if type(text) ~= "string" then
        return tags
    end
    for piece in text:gmatch("[^,\n]+") do
        local name = piece:match("^%s*(.-)%s*$")
        local key = name:lower()
        if name ~= "" and not seen[key] then
            seen[key] = true
            table.insert(tags, name)
        end
    end
    return tags
end

-- PATCH /update/<id>/ REPLACES the document's whole tag list, so callers must
-- pass the complete list they want it to end up with (an empty list clears all
-- tags). Returns the normalized list that was sent.
function Reader:updateTags(document_id, tags)
    if type(document_id) ~= "string" or document_id == "" then
        return nil, "invalid_document"
    end
    if type(tags) ~= "table" then
        return nil, "invalid_tags"
    end
    local payload = Reader.parseTags(table.concat(tags, ","))
    local response, err, status = self.request("PATCH", "/update/" .. queryEscape(document_id) .. "/", {
        tags = payload,
    })
    if not response then
        return nil, err or "request_failed", status
    end
    return payload
end

local function lowerSet(tags)
    local set = {}
    for _, tag in ipairs(tags or {}) do
        set[tag:lower()] = true
    end
    return set
end

-- What changed between two tag lists, compared case-insensitively. Queued
-- edits store this instead of the full list: Reader replaces the whole list on
-- save, so a diff can be re-applied to whatever the tags are by the time the
-- device is back online without undoing changes made elsewhere in between.
function Reader.diffTags(old_tags, new_tags)
    local had, has = lowerSet(old_tags), lowerSet(new_tags)
    local add, remove = {}, {}
    for _, tag in ipairs(new_tags or {}) do
        if not had[tag:lower()] then table.insert(add, tag) end
    end
    for _, tag in ipairs(old_tags or {}) do
        if not has[tag:lower()] then table.insert(remove, tag) end
    end
    return add, remove
end

function Reader.applyTagDiff(tags, add, remove)
    local removed = lowerSet(remove)
    local result = {}
    for _, tag in ipairs(tags or {}) do
        if not removed[tag:lower()] then table.insert(result, tag) end
    end
    for _, tag in ipairs(add or {}) do
        table.insert(result, tag)
    end
    return Reader.parseTags(table.concat(result, ","))
end

-- Folds a newer edit into an older queued one for the same document: the
-- newer edit wins wherever the two disagree about a tag.
function Reader.mergeTagDiffs(older, newer)
    local newer_add, newer_remove = lowerSet(newer.add), lowerSet(newer.remove)
    local add, remove = {}, {}
    for _, tag in ipairs(older.add or {}) do
        if not newer_remove[tag:lower()] then table.insert(add, tag) end
    end
    for _, tag in ipairs(newer.add or {}) do table.insert(add, tag) end
    for _, tag in ipairs(older.remove or {}) do
        if not newer_add[tag:lower()] then table.insert(remove, tag) end
    end
    for _, tag in ipairs(newer.remove or {}) do table.insert(remove, tag) end
    return { add = Reader.parseTags(table.concat(add, ",")), remove = Reader.parseTags(table.concat(remove, ",")) }
end

-- A failure worth retrying later (offline, throttled, server trouble) as
-- opposed to one a retry cannot fix (bad token, document gone).
function Reader.isRetryable(err, status)
    return err == "network_error" or status == 429 or (type(status) == "number" and status >= 500)
end

-- GET /tags/ -- every tag name in the account, for the tag picker. Bounded to a
-- few pages so a huge tag set cannot stall the device.
function Reader:listTags()
    local names, seen, cursor = {}, {}, nil
    for _ = 1, 10 do
        local endpoint = "/tags/"
        if cursor then endpoint = endpoint .. "?pageCursor=" .. queryEscape(cursor) end
        local response, err, status = self.request("GET", endpoint)
        if not response then
            return nil, err or "request_failed", status
        end
        for _, tag in ipairs(normalizeTags(response.results) or {}) do
            if not seen[tag:lower()] then
                seen[tag:lower()] = true
                table.insert(names, tag)
            end
        end
        cursor = stringOrNil(response.nextPageCursor)
        if not cursor then break end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- Re-applies a queued tag diff to the document's CURRENT tags. Returns the
-- fresh document (with its new tags) so callers can refresh local metadata.
function Reader:applyTagChange(document_id, add, remove)
    local document, err, status = self:getDocument(document_id, false)
    if not document then
        return nil, err, status
    end
    local tags = Reader.applyTagDiff(document.tags, add, remove)
    local saved, update_err, update_status = self:updateTags(document_id, tags)
    if not saved then
        return nil, update_err, update_status
    end
    document.tags = #saved > 0 and saved or nil
    return document
end

function Reader:listMetadata(location, cursor)
    local endpoint = "/list/?withHtmlContent=false&withTags=true&limit=" .. PAGE_SIZE
    if type(location) == "string" and location ~= "" then
        endpoint = endpoint .. "&location=" .. queryEscape(location)
    end
    if type(cursor) == "string" and cursor ~= "" then
        endpoint = endpoint .. "&pageCursor=" .. queryEscape(cursor)
    end

    local response, err, status = self.request("GET", endpoint)
    if not response then
        return nil, err or "request_failed", status
    end

    local documents = {}
    local result_count = type(response.results) == "table" and #response.results or 0
    if type(response.results) == "table" then
        for _, document in ipairs(response.results) do
            local normalized = Reader.normalizeDocument(document)
            if normalized then
                table.insert(documents, normalized)
            end
        end
    end
    local next_cursor = stringOrNil(response.nextPageCursor)
    return { documents = documents, next_cursor = next_cursor, result_count = result_count }
end

-- Locations scanned by search and by views (below). Feed is included: it is a
-- documented, listable location and a user may reasonably want to search it,
-- unlike views, which stay closer to "things you might download" and leave
-- Feed out. Child highlight/note documents are excluded from both by their
-- own parent_id check.
local SEARCH_LOCATIONS = {
    new = true,
    later = true,
    shortlist = true,
    archive = true,
    feed = true,
}

local VIEW_LOCATIONS = {
    new = true,
    later = true,
    shortlist = true,
    archive = true,
}

local function contains(haystack, needle)
    return type(haystack) == "string"
        and string.find(string.lower(haystack), needle, 1, true) ~= nil
end

function Reader.documentMatches(document, query)
    if type(document) ~= "table" or type(query) ~= "string" or query == "" then
        return false
    end
    local needle = string.lower(query)
    for _, value in pairs({
        document.title,
        document.author,
        document.site_name,
        document.summary,
    }) do
        if contains(value, needle) then
            return true
        end
    end
    for _, tag in ipairs(document.tags or {}) do
        if contains(tag, needle) then
            return true
        end
    end
    return false
end

-- One metadata-only list page, filtered locally by `predicate`. Shared by
-- search and views since neither has a documented server-side parameter to
-- ask for instead. Callers retain next_cursor and explicitly request more
-- pages, keeping Kindle memory and network use bounded.
function Reader:scanMetadata(cursor, predicate)
    local page, err, status = self:listMetadata(nil, cursor)
    if not page then
        return nil, err, status
    end

    local matches = {}
    for _, document in ipairs(page.documents) do
        if predicate(document) then
            table.insert(matches, document)
        end
    end
    return {
        documents = matches,
        next_cursor = page.next_cursor,
        scanned = page.result_count,
    }
end

-- The public v3 REST API has no documented search parameter.
function Reader:searchMetadata(query, cursor)
    return self:scanMetadata(cursor, function(document)
        return SEARCH_LOCATIONS[document.location]
            and not document.parent_id
            and Reader.documentMatches(document, query)
    end)
end

-- Reader's own `reading_time` is normalized to a "<int> min" string once in
-- normalizeDocument; views need the raw minutes back to threshold against.
local function readingTimeMinutes(document)
    local text = document and document.reading_time
    return type(text) == "string" and tonumber(text:match("%d+")) or nil
end

-- Approximate thresholds mirroring Readwise Reader's own "Quick reads" /
-- "Longreads" smart views. The public API documents no such filter, so these
-- are reproduced locally against fields the LIST endpoint already returns.
local QUICK_READ_MAX_MINUTES = 5
local LONG_READ_MIN_MINUTES = 20

local VIEW_PREDICATES = {
    quick_reads = function(document)
        local minutes = readingTimeMinutes(document)
        return minutes ~= nil and minutes <= QUICK_READ_MAX_MINUTES
    end,
    long_reads = function(document)
        local minutes = readingTimeMinutes(document)
        return minutes ~= nil and minutes >= LONG_READ_MIN_MINUTES
    end,
    in_progress = function(document)
        local progress = document.reading_progress
        return type(progress) == "number" and progress > 0 and progress < 1
    end,
}

-- Virtual views: there is no documented view/filter parameter, so this scans
-- Library metadata the same way search does and filters it against one of the
-- predicates above.
function Reader:viewMetadata(view_key, cursor)
    local predicate = VIEW_PREDICATES[view_key]
    if not predicate then
        return nil, "invalid_view"
    end
    return self:scanMetadata(cursor, function(document)
        return VIEW_LOCATIONS[document.location]
            and not document.parent_id
            and predicate(document)
    end)
end

-- `id` and `withHtmlContent` are documented LIST parameters. This is the only
-- full-content request made by picker/search flows, and only happens after the
-- user asks to download a document.
function Reader:getDocument(document_id, with_html_content)
    if type(document_id) ~= "string" or document_id == "" then
        return nil, "invalid_document"
    end
    if with_html_content == nil then
        with_html_content = true
    end
    local endpoint = "/list/?id=" .. queryEscape(document_id)
        .. "&withHtmlContent=" .. (with_html_content and "true" or "false")
        .. "&withTags=true&limit=1"
    local response, err, status = self.request("GET", endpoint)
    if not response then
        return nil, err or "request_failed", status
    end
    if type(response.results) ~= "table" then
        return nil, "malformed_response"
    end
    for _, document in ipairs(response.results) do
        local normalized = Reader.normalizeDocument(document)
        if normalized and normalized.id == document_id then
            return normalized
        end
    end
    return nil, "not_found"
end

return Reader
