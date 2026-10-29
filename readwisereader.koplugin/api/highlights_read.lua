-- Read-only Readwise v2 highlights adapter: paginated listing, local
-- metadata search (the v2 LIST endpoint has no documented full-text query
-- parameter, same limitation as api/reader.lua's Library search), a
-- lazily-fetched book title/author lookup, and the documented Daily Review
-- endpoint. Transport/authentication stay with main.lua's callAPI, mirroring
-- how api/reader.lua and api/highlights.lua defer to it.
local HighlightsRead = {}
HighlightsRead.__index = HighlightsRead

local PAGE_SIZE = 100

local function stringOrNil(value)
    return type(value) == "string" and value ~= "" and value or nil
end

-- v2 returns a highlight's tags as {id, name} objects. Names are what the UI
-- shows; ids are needed to delete one, so both are kept.
local function normalizeTagRecords(tags)
    local records = {}
    if type(tags) == "table" then
        for _, tag in ipairs(tags) do
            if type(tag) == "table" and type(tag.name) == "string" and tag.name ~= "" then
                table.insert(records, { id = tag.id, name = tag.name })
            end
        end
    end
    return records
end

function HighlightsRead:new(options)
    assert(type(options) == "table" and type(options.request) == "function",
        "HighlightsRead request adapter required")
    return setmetatable({ request = options.request }, self)
end

-- `title`/`author` are absent on the plain LIST endpoint (only book_id is
-- given there) and present on Daily Review's response, which nests them
-- directly on each highlight instead of requiring a book lookup.
function HighlightsRead.normalizeHighlight(highlight)
    if type(highlight) ~= "table" or highlight.id == nil then
        return nil
    end
    return {
        id = highlight.id,
        text = stringOrNil(highlight.text),
        note = stringOrNil(highlight.note),
        book_id = highlight.book_id,
        location = highlight.location,
        location_type = stringOrNil(highlight.location_type),
        highlighted_at = stringOrNil(highlight.highlighted_at),
        title = stringOrNil(highlight.title),
        author = stringOrNil(highlight.author),
        source_url = stringOrNil(highlight.source_url),
        tag_records = normalizeTagRecords(highlight.tags),
    }
end

-- GET /highlights/?page=&page_size=100. `page` is 1-based like the documented
-- v2 pagination; `next` in the response is the full next-page URL (or null),
-- so its presence, not its value, is what we act on.
function HighlightsRead:listPage(page_number)
    local page = type(page_number) == "number" and page_number or 1
    local endpoint = "/highlights/?page_size=" .. PAGE_SIZE .. "&page=" .. page
    local response, err, status = self.request(endpoint, "GET", nil)
    if not response then
        return nil, err or "request_failed", status
    end
    local highlights = {}
    if type(response.results) == "table" then
        for _, highlight in ipairs(response.results) do
            local normalized = HighlightsRead.normalizeHighlight(highlight)
            if normalized then
                table.insert(highlights, normalized)
            end
        end
    end
    local next_page = stringOrNil(response.next) and (page + 1) or nil
    return { highlights = highlights, next_page = next_page, result_count = #highlights }
end

local function contains(haystack, needle)
    return type(haystack) == "string"
        and string.find(string.lower(haystack), needle, 1, true) ~= nil
end

function HighlightsRead.highlightMatches(highlight, query)
    if type(highlight) ~= "table" or type(query) ~= "string" or query == "" then
        return false
    end
    local needle = string.lower(query)
    for _, value in pairs({ highlight.text, highlight.note, highlight.title, highlight.author }) do
        if contains(value, needle) then
            return true
        end
    end
    return false
end

-- No documented full-text query parameter exists on v2 LIST, so this scans
-- one page at a time and filters locally, the same pattern as Reader
-- metadata search. Book title/author only match when Daily Review supplied
-- them; a plain highlight's book has to be opened to search by title.
function HighlightsRead:searchHighlights(query, page_number)
    local page, err, status = self:listPage(page_number)
    if not page then
        return nil, err, status
    end
    local matches = {}
    for _, highlight in ipairs(page.highlights) do
        if HighlightsRead.highlightMatches(highlight, query) then
            table.insert(matches, highlight)
        end
    end
    return { highlights = matches, next_page = page.next_page, scanned = page.result_count }
end

-- GET /books/?category=&page=&page_size=100. `category` is one of the four
-- documented v2 categories (see api/highlights.lua's CATEGORY_MAP): books,
-- articles, tweets, podcasts. Used to group highlights by source for
-- browsing, the way Readwise's own highlights view does.
function HighlightsRead:listBooksPage(category, page_number)
    local page = type(page_number) == "number" and page_number or 1
    local endpoint = "/books/?page_size=" .. PAGE_SIZE .. "&page=" .. page
    if type(category) == "string" and category ~= "" then
        endpoint = endpoint .. "&category=" .. category
    end
    local response, err, status = self.request(endpoint, "GET", nil)
    if not response then
        return nil, err or "request_failed", status
    end
    local books = {}
    if type(response.results) == "table" then
        for _, book in ipairs(response.results) do
            if type(book) == "table" and book.id ~= nil then
                table.insert(books, {
                    id = book.id,
                    title = stringOrNil(book.title) or "Untitled",
                    author = stringOrNil(book.author),
                    category = stringOrNil(book.category),
                    num_highlights = book.num_highlights,
                })
            end
        end
    end
    local next_page = stringOrNil(response.next) and (page + 1) or nil
    return { books = books, next_page = next_page }
end

-- GET /highlights/?book_id=&page=&page_size=100. `book_id` is a documented
-- v2 LIST filter, so a book's highlights come straight from the server
-- instead of the local page-and-filter scan searchHighlights needs.
function HighlightsRead:listBookHighlightsPage(book_id, page_number)
    local page = type(page_number) == "number" and page_number or 1
    local endpoint = "/highlights/?page_size=" .. PAGE_SIZE .. "&page=" .. page
        .. "&book_id=" .. tostring(book_id)
    local response, err, status = self.request(endpoint, "GET", nil)
    if not response then
        return nil, err or "request_failed", status
    end
    local highlights = {}
    if type(response.results) == "table" then
        for _, highlight in ipairs(response.results) do
            local normalized = HighlightsRead.normalizeHighlight(highlight)
            if normalized then
                table.insert(highlights, normalized)
            end
        end
    end
    local next_page = stringOrNil(response.next) and (page + 1) or nil
    return { highlights = highlights, next_page = next_page }
end

-- GET /books/<id>/ -- fetched lazily, one book at a time, only when a
-- highlight's details are opened outside of its own book listing (search and
-- Daily Review results carry no title/author of their own). There is no bulk
-- join here: preloading every book behind a page of highlights would turn one
-- list request into dozens for a library this plugin does not otherwise need
-- to enumerate.
function HighlightsRead:getBook(book_id)
    if book_id == nil then
        return nil, "missing_book_id"
    end
    local response, err, status = self.request("/books/" .. tostring(book_id) .. "/", "GET", nil)
    if not response then
        return nil, err or "request_failed", status
    end
    return {
        id = response.id,
        title = stringOrNil(response.title),
        author = stringOrNil(response.author),
        category = stringOrNil(response.category),
        source_url = stringOrNil(response.source_url),
    }
end

-- GET /review/ -- the documented Daily Review endpoint. Returns today's
-- review highlights directly, each already carrying its own title/author, so
-- no book lookup is needed to display them.
function HighlightsRead:dailyReview()
    local response, err, status = self.request("/review/", "GET", nil)
    if not response then
        return nil, err or "request_failed", status
    end
    local highlights = {}
    if type(response.highlights) == "table" then
        for _, highlight in ipairs(response.highlights) do
            local normalized = HighlightsRead.normalizeHighlight(highlight)
            if normalized then
                table.insert(highlights, normalized)
            end
        end
    end
    return {
        highlights = highlights,
        review_id = response.review_id,
        review_url = stringOrNil(response.review_url),
    }
end

-- GET /highlights/<id>/tags/ -- the highlight's current tags, fetched fresh
-- before an edit so a tag added elsewhere is not mistaken for a removal.
function HighlightsRead:getHighlightTags(highlight_id)
    if highlight_id == nil then
        return nil, "missing_highlight_id"
    end
    local response, err, status = self.request("/highlights/" .. tostring(highlight_id) .. "/tags/", "GET", nil)
    if not response then
        return nil, err or "request_failed", status
    end
    return normalizeTagRecords(response.results)
end

-- Unlike Reader documents, v2 tags are added and removed one at a time
-- (POST /highlights/<id>/tags/ {name}, DELETE .../tags/<tag_id>/), so this
-- diffs against the fresh list and applies only the difference. Stops at the
-- first failure and returns the tags as they now stand.
function HighlightsRead:setHighlightTags(highlight_id, desired)
    local records, err, status = self:getHighlightTags(highlight_id)
    if not records then
        return nil, err, status
    end
    local wanted = {}
    for _, name in ipairs(desired) do wanted[name:lower()] = true end
    local present = {}
    for _, record in ipairs(records) do present[record.name:lower()] = true end

    local base = "/highlights/" .. tostring(highlight_id) .. "/tags/"
    local remaining = {}
    for _, record in ipairs(records) do
        if wanted[record.name:lower()] then
            table.insert(remaining, record)
        else
            local ok, delete_err, delete_status = self.request(base .. tostring(record.id) .. "/", "DELETE", nil)
            if not ok then
                return nil, delete_err or "request_failed", delete_status
            end
        end
    end
    for _, name in ipairs(desired) do
        if not present[name:lower()] then
            local created, create_err, create_status = self.request(base, "POST", { name = name })
            if not created then
                return nil, create_err or "request_failed", create_status
            end
            table.insert(remaining, {
                id = type(created) == "table" and created.id or nil,
                name = name,
            })
        end
    end
    return remaining
end

return HighlightsRead
