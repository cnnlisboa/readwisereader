-- Readwise Books API client (https://readwise.io/books_api, experimental).
-- Transport stays with main.lua's callAPI, called with the Books base URL, the
-- same way api/reader.lua defers to it.
--
-- Rules the API imposes and this module enforces (docs/books-api-contract.md):
--   * batches return 200 even when items fail, so every item's status is read;
--   * unknown parameters are silently ignored, so values are validated here
--     before anything is sent;
--   * PATCH takes up to 100 items, POST up to 10 (books, sessions, uploads).
local Books = {}
Books.__index = Books

Books.BASE_URL = "https://readwise.io/books/api/v1"

-- Shelves that can be written. `unsorted` exists but cannot be set.
Books.SHELVES = {
    want_to_read = true,
    currently_reading = true,
    finished = true,
    did_not_finish = true,
    deleted = true,
}

Books.SESSION_FORMATS = { paper = true, ebook = true, audiobook = true }

local PATCH_BATCH = 100
local POST_BATCH = 10
local LIST_LIMIT = 1000
-- A library over this many pages would be 50,000 books; the cap only exists so
-- a server that keeps returning `next` cannot loop forever.
local MAX_PAGES = 50

local function queryEscape(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function buildQuery(params)
    local keys = {}
    for key in pairs(params or {}) do table.insert(keys, key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = params[key]
        if type(value) == "table" then
            local items = {}
            for _, item in ipairs(value) do table.insert(items, tostring(item)) end
            value = #items > 0 and table.concat(items, ",") or nil
        end
        if value ~= nil and value ~= "" then
            table.insert(parts, key .. "=" .. queryEscape(value))
        end
    end
    return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end
Books.buildQuery = buildQuery

local function cursorFromNext(next_url)
    if type(next_url) ~= "string" then return nil end
    local cursor = next_url:match("[?&]cursor=([^&]+)")
    if not cursor then return nil end
    return (cursor:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end
Books.cursorFromNext = cursorFromNext

local function chunks(list, size)
    local out, current = {}, {}
    for _, item in ipairs(list) do
        table.insert(current, item)
        if #current == size then
            table.insert(out, current)
            current = {}
        end
    end
    if #current > 0 then table.insert(out, current) end
    return out
end
Books.chunks = chunks

function Books:new(options)
    assert(type(options) == "table" and type(options.request) == "function",
        "Books request adapter required")
    return setmetatable({ request = options.request }, self)
end

-- Ratings are 0.25-5 in quarter steps. Anything above 5 (a note's 6 or 7) is
-- sent as 5; anything that is not a positive number is nil (not sent).
function Books.snapRating(value)
    local number = tonumber(value)
    if not number or number <= 0 then return nil end
    if number > 5 then number = 5 end
    number = math.floor(number * 4 + 0.5) / 4
    if number < 0.25 then number = 0.25 end
    return number
end

-- Strips fields the API would reject or ignore, so a typo can't become a
-- silent no-op. Returns nil when the item is not sendable.
function Books.validateUpdate(item)
    if type(item) ~= "table" or type(item.id) ~= "number" then return nil end
    local clean = { id = item.id }
    if item.status ~= nil then
        if not Books.SHELVES[item.status] then return nil end
        clean.status = item.status
    end
    if item.rating ~= nil then
        clean.rating = Books.snapRating(item.rating)
        if not clean.rating then return nil end
    end
    for _, key in ipairs({ "started_reading_at", "finished_reading_at" }) do
        if type(item[key]) == "string" and item[key] ~= "" then
            clean[key] = item[key]
        end
    end
    local pages = tonumber(item.manual_total_pages)
    if pages then
        pages = math.floor(pages)
        if pages < 1 or pages > 5000 then return nil end
        clean.manual_total_pages = pages
    end
    if next(clean, nil) == "id" and next(clean, "id") == nil then
        return nil -- nothing to change
    end
    return clean
end

-- Reads a batch response into { [index] = { ok = bool, id, code, message, raw } }.
local function itemResults(response, count, ok_statuses)
    local results = {}
    local list = type(response) == "table" and response.results or nil
    for i = 1, count do
        local entry = type(list) == "table" and list[i] or nil
        if type(entry) ~= "table" then
            results[i] = { ok = false, code = "missing_result" }
        else
            local err = type(entry.error) == "table" and entry.error or nil
            results[i] = {
                ok = ok_statuses[entry.status] == true,
                status = entry.status,
                id = entry.id or entry.book_id or entry.session_id,
                code = err and err.code or nil,
                message = err and err.message or nil,
                raw = entry,
            }
        end
    end
    return results
end

-- Whether a failed item is worth sending again later.
function Books.isRetryable(result)
    if type(result) ~= "table" then return true end
    local code = result.code
    return code == "rate_limited" or code == "server_error" or code == "network_error"
        or code == "missing_result" or code == nil
end

local function sendBatches(self, method, endpoint, items, size, ok_statuses)
    local results = {}
    local offset = 0
    for _, batch in ipairs(chunks(items, size)) do
        local response, err, code = self.request(method, endpoint, { items = batch })
        local batch_results
        if response then
            batch_results = itemResults(response, #batch, ok_statuses)
        else
            batch_results = {}
            local failure = (code == 429 and "rate_limited")
                or ((code == nil or err == "network_error") and "network_error")
                or (code and code >= 500 and "server_error")
                or "invalid_request"
            for i = 1, #batch do
                batch_results[i] = { ok = false, code = failure, http = code }
            end
        end
        for i, result in ipairs(batch_results) do
            results[offset + i] = result
        end
        offset = offset + #batch
    end
    return results
end

-- All books on every shelf (including deleted), following `next`.
-- Returns list or nil, err, code.
function Books:listAll(params)
    local query = {}
    for key, value in pairs(params or {}) do query[key] = value end
    query.limit = query.limit or LIST_LIMIT
    local books = {}
    for _ = 1, MAX_PAGES do
        local response, err, code = self.request("GET", "/books" .. buildQuery(query))
        if type(response) ~= "table" then
            return nil, err or "invalid_response", code
        end
        if type(response.results) ~= "table" then
            return nil, "invalid_response"
        end
        for _, book in ipairs(response.results) do
            if type(book) == "table" and type(book.id) == "number" then
                table.insert(books, book)
            end
        end
        local cursor = cursorFromNext(response.next)
        if not cursor then
            return books
        end
        query.cursor = cursor
    end
    return books
end

-- Books by id, in chunks of 100. Returns { [id] = book } or nil, err, code.
function Books:getByIds(ids)
    local found = {}
    for _, batch in ipairs(chunks(ids or {}, 100)) do
        local list, err, code = self:listAll({ ids = batch })
        if not list then return nil, err, code end
        for _, book in ipairs(list) do found[book.id] = book end
    end
    return found
end

-- PATCH /books. `items` are validated first; dropped items come back as
-- { ok = false, code = "invalid_value" } at their index so callers can log
-- them. Returns results aligned with `items`.
function Books:update(items)
    local sendable, index_map, results = {}, {}, {}
    for i, item in ipairs(items or {}) do
        local clean = Books.validateUpdate(item)
        if clean then
            table.insert(sendable, clean)
            index_map[#sendable] = i
        else
            results[i] = { ok = false, code = "invalid_value", message = "not sendable", id = item and item.id }
        end
    end
    local sent = sendBatches(self, "PATCH", "/books", sendable, PATCH_BATCH, { updated = true })
    for j, result in ipairs(sent) do
        result.id = result.id or sendable[j].id
        results[index_map[j]] = result
    end
    return results
end

-- POST /books with { product = {isbn=..} | {title=..,author=..}, status = .. }.
function Books:create(items)
    return sendBatches(self, "POST", "/books", items or {}, POST_BATCH,
        { created = true, existing = true })
end

function Books.validateSession(item)
    if type(item) ~= "table" or type(item.book_id) ~= "number" then return nil end
    if type(item.started_at) ~= "string" or type(item.ended_at) ~= "string" then return nil end
    if not Books.SESSION_FORMATS[item.format] then return nil end
    if item.format == "ebook" then
        local a, b = tonumber(item.percent_at_start), tonumber(item.percent_at_end)
        if not a or not b or a < 0 or b > 1 or a > b then return nil end
    end
    return item
end

function Books:createSessions(items)
    local sendable, index_map, results = {}, {}, {}
    for i, item in ipairs(items or {}) do
        if Books.validateSession(item) then
            table.insert(sendable, item)
            index_map[#sendable] = i
        else
            results[i] = { ok = false, code = "invalid_value", message = "not sendable" }
        end
    end
    local sent = sendBatches(self, "POST", "/sessions", sendable, POST_BATCH,
        { created = true, existing = true })
    for j, result in ipairs(sent) do results[index_map[j]] = result end
    return results
end

-- Sessions for the given books started after `started_after` (ISO string).
function Books:listSessions(book_ids, started_after)
    local sessions = {}
    for _, batch in ipairs(chunks(book_ids or {}, 100)) do
        local query = { book_ids = batch, started_after = started_after, limit = LIST_LIMIT }
        for _ = 1, MAX_PAGES do
            local response, err, code = self.request("GET", "/sessions" .. buildQuery(query))
            if type(response) ~= "table" or type(response.results) ~= "table" then
                return nil, err or "invalid_response", code
            end
            for _, session in ipairs(response.results) do table.insert(sessions, session) end
            local cursor = cursorFromNext(response.next)
            if not cursor then break end
            query.cursor = cursor
        end
    end
    return sessions
end

-- Upload step 1: { file_name, size } -> results with upload, upload_url, upload_headers.
function Books:createUploads(items)
    return sendBatches(self, "POST", "/uploads", items or {}, POST_BATCH, { created = true })
end

-- Upload step 3: { id = upload id, status = shelf }.
function Books:completeUploads(items)
    return sendBatches(self, "POST", "/uploads/complete", items or {}, POST_BATCH,
        { processing = true, existing = true })
end

function Books:getUploads(ids)
    local response, err, code = self.request("GET", "/uploads" .. buildQuery({ ids = ids }))
    if type(response) ~= "table" or type(response.results) ~= "table" then
        return nil, err or "invalid_response", code
    end
    return response.results
end

return Books
