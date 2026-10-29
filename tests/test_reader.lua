package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Reader = require("api/reader")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

print("== Reader document normalization ==")
local document = Reader.normalizeDocument({
    id = "reader-book-id",
    title = "Local Book",
    notes = "My Reader note",
    reading_progress = 0.42,
})
check("normalizes a document", document ~= nil, true)
check("keeps the top-level note", document.notes, "My Reader note")
check("keeps Reader progress", document.reading_progress, 0.42)
check("empty note stays absent", Reader.normalizeDocument({ id = "empty", notes = "" }).notes, nil)

local endpoints = {}
local api = Reader:new{
    request = function(_method, endpoint)
        table.insert(endpoints, endpoint)
        return { results = { { id = "reader-book-id", title = "Local Book" } } }
    end,
}
api:getDocument("reader-book-id", false)
api:getDocument("reader-book-id")
check("metadata fetch does not request HTML", endpoints[1]:find("withHtmlContent=false", 1, true) ~= nil, true)
check("download fetch still requests HTML", endpoints[2]:find("withHtmlContent=true", 1, true) ~= nil, true)

print("\n== Library search includes Feed ==")
local search_page = {
    { id = "1", title = "Feed item", location = "feed" },
    { id = "2", title = "Later item", location = "later" },
    { id = "3", title = "Child note", location = "later", parent_id = "2" },
}
local search_api = Reader:new{
    request = function() return { results = search_page } end,
}
local search_result = search_api:searchMetadata("item")
check("Feed and Later both match", #search_result.documents, 2)
local search_ids = {}
for _, document in ipairs(search_result.documents) do search_ids[document.id] = true end
check("Feed item is included", search_ids["1"], true)
check("child document is excluded", search_ids["3"], nil)

print("\n== Views ==")
local view_page = {
    { id = "quick", title = "Quick", location = "later", reading_time = 3 },
    { id = "long", title = "Long", location = "later", reading_time = 45 },
    { id = "mid", title = "Mid", location = "later", reading_time = 12 },
    { id = "started", title = "Started", location = "shortlist", reading_progress = 0.5 },
    { id = "finished", title = "Finished", location = "shortlist", reading_progress = 1 },
    { id = "unstarted", title = "Unstarted", location = "shortlist", reading_progress = 0 },
    { id = "feed-quick", title = "Feed quick", location = "feed", reading_time = 2 },
    { id = "child-quick", title = "Child quick", location = "later", reading_time = 2, parent_id = "quick" },
}
local view_api = Reader:new{
    request = function() return { results = view_page } end,
}

local function idsOf(documents)
    local ids = {}
    for _, document in ipairs(documents) do table.insert(ids, document.id) end
    table.sort(ids)
    return table.concat(ids, ",")
end

check("quick_reads matches short reading_time", idsOf(view_api:viewMetadata("quick_reads").documents), "quick")
check("long_reads matches long reading_time", idsOf(view_api:viewMetadata("long_reads").documents), "long")
check("in_progress matches partial progress only", idsOf(view_api:viewMetadata("in_progress").documents), "started")
check("unknown view is rejected", view_api:viewMetadata("nonsense"), nil)

print("\n== Tag editing ==")
local parsed = Reader.parseTags(" alpha, Beta ,, ALPHA\ngamma ,")
check("parseTags trims, drops empties and case-dupes", table.concat(parsed, "|"), "alpha|Beta|gamma")
check("parseTags of non-string is empty", #Reader.parseTags(nil), 0)

local sent
local tag_api = Reader:new{
    request = function(method, endpoint, body)
        sent = { method = method, endpoint = endpoint, body = body }
        return { id = "doc 1" }
    end,
}
local saved = tag_api:updateTags("doc 1", { "one", "Two", "one" })
check("updateTags uses PATCH", sent.method, "PATCH")
check("updateTags escapes the id in the endpoint", sent.endpoint, "/update/doc%201/")
check("updateTags sends the full deduped list", table.concat(sent.body.tags, "|"), "one|Two")
check("updateTags returns what it sent", table.concat(saved, "|"), "one|Two")
tag_api:updateTags("doc1", {})
check("empty list is sent to clear all tags", #sent.body.tags, 0)
check("updateTags rejects a bad id", select(2, tag_api:updateTags("", { "x" })), "invalid_document")
check("updateTags rejects a non-table", select(2, tag_api:updateTags("doc1", "x")), "invalid_tags")
local failing = Reader:new{ request = function() return nil, "network_error", 503 end }
local _, fail_err, fail_status = failing:updateTags("doc1", { "x" })
check("updateTags passes through the error", fail_err, "network_error")
check("updateTags passes through the status", fail_status, 503)

print("\n== Tag diffs, queue merging and the tag list ==")
local add, remove = Reader.diffTags({ "A", "b" }, { "a", "c" })
check("diffTags adds only new (case-insensitive)", table.concat(add, "|"), "c")
check("diffTags removes only missing", table.concat(remove, "|"), "b")
check("applyTagDiff on fresh tags", table.concat(Reader.applyTagDiff({ "x", "b", "y" }, { "c" }, { "B" }), "|"), "x|y|c")
local merged = Reader.mergeTagDiffs({ add = { "a" }, remove = { "b" } }, { add = { "b" }, remove = { "a", "z" } })
check("merge: later edit wins on add", table.concat(merged.add, "|"), "b")
check("merge: later edit wins on remove", table.concat(merged.remove, "|"), "a|z")
check("429 is retryable", Reader.isRetryable("http_error", 429), true)
check("503 is retryable", Reader.isRetryable("http_error", 503), true)
check("offline is retryable", Reader.isRetryable("network_error"), true)
check("401 is not retryable", Reader.isRetryable("http_error", 401), false)
check("404 is not retryable", Reader.isRetryable("not_found"), false)

local pages = {
    [""] = { results = { { key = "b", name = "Beta" }, { key = "a", name = "alpha" } }, nextPageCursor = "c2" },
    ["?pageCursor=c2"] = { results = { { key = "a2", name = "Alpha" }, { key = "g", name = "gamma" } } },
}
local list_api = Reader:new{
    request = function(_, endpoint) return pages[endpoint:gsub("^/tags/", "")] end,
}
check("listTags pages, dedupes and sorts", table.concat(list_api:listTags(), "|"), "alpha|Beta|gamma")

local calls = {}
local apply_api = Reader:new{
    request = function(method, endpoint, body)
        table.insert(calls, method .. " " .. endpoint)
        if method == "GET" then
            return { results = { { id = "d1", title = "T", tags = { "keep", "drop" } } } }
        end
        calls.body = body
        return { id = "d1" }
    end,
}
local applied = apply_api:applyTagChange("d1", { "new" }, { "drop" })
check("applyTagChange re-reads then patches", #calls, 2)
check("applyTagChange applies diff to fresh tags", table.concat(calls.body.tags, "|"), "keep|new")
check("applyTagChange returns the document", table.concat(applied.tags, "|"), "keep|new")
local gone = Reader:new{ request = function() return { results = {} } end }
check("applyTagChange on missing document", select(2, gone:applyTagChange("d1", { "x" }, {})), "not_found")

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
