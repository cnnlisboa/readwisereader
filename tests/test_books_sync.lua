-- Drives books_sync.lua through main.lua with KOReader stubbed out: one sync
-- against a fake Readwise Books library, sidecars kept in memory.
local plugin = os.getenv("PLUGIN_PATH") or "readwisereader.koplugin"
package.path = plugin .. "/?.lua;" .. package.path

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-56s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-56s %s", name, tostring(got)))
    end
end

local inert
inert = function()
    return setmetatable({}, {
        __index = function() return inert() end,
        __call = function() return inert() end,
    })
end

-- In-memory sidecars: path -> { summary = {...} }
local sidecars = {}
local DocSettings = {
    hasSidecarFile = function(_, path) return sidecars[path] ~= nil end,
    open = function(_, path)
        sidecars[path] = sidecars[path] or {}
        local data = sidecars[path]
        return {
            readSetting = function(_, key) return data[key] end,
            saveSetting = function(_, key, value) data[key] = value end,
            flush = function() end,
        }
    end,
}
local confirms = {}
local Trapper = {
    confirm = function(_, text) table.insert(confirms, text); return true end,
    wrap = function(_, fn) fn() end,
}
local collections = { coll = {} }
function collections:isFileInCollection(file, name) return self.coll[name] and self.coll[name][file] or false end
function collections:addCollection(name) self.coll[name] = {} end
function collections:addItem(file, name) self.coll[name][file] = true end
function collections:write() end

local overrides = {
    ["docsettings"] = DocSettings,
    ["ui/trapper"] = Trapper,
    ["readcollection"] = collections,
    ["ui/widget/container/widgetcontainer"] = {
        extend = function(_, class) return setmetatable(class, { __index = {} }) end,
    },
    ["ui/network/manager"] = { isOnline = function() return true end, runWhenOnline = function(_, fn) fn() end },
    ["libs/libkoreader-lfs"] = { attributes = function() return "file" end, dir = function() return function() end end },
    ["ffi/util"] = { template = function(s) return s end },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
}
table.insert(package.loaders, function(name)
    return function() return overrides[name] or inert() end
end)
for name, module in pairs(overrides) do package.loaded[name] = module end

local ReadwiseReader = require("main")

-- Fake Books API: a library plus a log of PATCHes.
local function newBooksApi(books)
    local api = { patches = {} }
    function api.listAll() return books end
    function api.update(_, items)
        local results = {}
        for _, item in ipairs(items) do
            table.insert(api.patches, item)
            table.insert(results, { ok = true, id = item.id })
        end
        return results
    end
    function api.getByIds(_, ids)
        local found = {}
        for _, book in ipairs(books) do
            for _, id in ipairs(ids) do if book.id == id then found[id] = book end end
        end
        return found
    end
    return api
end

local function newPlugin(books, local_books)
    local self = setmetatable({}, { __index = ReadwiseReader })
    self:initBooks({ books_sync_enabled = true })
    self.books_api = newBooksApi(books)
    self.reader_api = { listEpubIdentities = function() return {} end }
    self.document_categories = {}
    self.local_book_links = {}
    self.ui = {}
    self.saveSettings = function() end
    self.showProgress = function() end
    self.hideProgress = function() end
    self.isDocumentOpen = function() return false end
    self.getLocalBooks = function() return local_books end
    self.withFastRequests = function(_, fn) return fn() end
    self.hasAccessToken = function() return true end
    return self
end

local BOOKS = {
    { id = 1, title = "Finishing", status = "currently_reading" },
    { id = 2, title = "Finished elsewhere", status = "currently_reading" },
    { id = 3, title = "Old finished", status = "finished", finished_reading_at = "2025-01-01T00:00:00Z" },
}
local LOCAL = { r1 = "/b/one.epub", r2 = "/b/two.epub", r3 = "/b/three.epub" }

print("== first sync: baseline only ==")
sidecars = {
    ["/b/one.epub"] = { summary = { status = "reading" } },
    ["/b/two.epub"] = { summary = { status = "reading" } },
    ["/b/three.epub"] = { summary = { status = "reading" } },
}
local p = newPlugin(BOOKS, LOCAL)
p.books_ids = { r1 = 1, r2 = 2, r3 = 3 }
local shelves, report = p:syncReadwiseBooks()
check("shelves returned", shelves.r3, "finished")
check("first sync sends no dates", #p.books_api.patches, 0)
check("old finished book not marked complete", sidecars["/b/three.epub"].summary.status, "reading")
check("baseline recorded", p.books_state[3].remote_status, "finished")

print("\n== device finishes book 1, Readwise finishes book 2 ==")
sidecars["/b/one.epub"].summary = { status = "complete", rating = 4 }
BOOKS[2].status = "finished"
shelves, report = p:syncReadwiseBooks()
check("one patch", #p.books_api.patches, 1)
check("book 1 finished", p.books_api.patches[1].status, "finished")
check("rating sent", p.books_api.patches[1].rating, 4)
check("finish date sent", p.books_api.patches[1].finished_reading_at ~= nil, true)
check("book 2 complete on device", sidecars["/b/two.epub"].summary.status, "complete")
check("report applied", report.applied, 1)

print("\n== next sync: nothing repeats ==")
p.books_api.patches = {}
BOOKS[1].status = "finished"
shelves, report = p:syncReadwiseBooks()
check("no repeat patches", #p.books_api.patches, 0)
check("no repeat device changes", report.applied, 0)

print("\n== manual mode holds changes until run by hand ==")
p:setAutomationMode("books_status", "manual")
sidecars["/b/one.epub"].summary.status = "abandoned"
BOOKS[1].status = "currently_reading"
p.books_state[1].remote_status = "currently_reading"
p:syncReadwiseBooks()
check("manual: nothing sent", #p.books_api.patches, 0)
p.manual_actions = { books_status = true }
p:syncReadwiseBooks()
p.manual_actions = nil
check("run now: sent", #p.books_api.patches, 1)
check("on hold -> did_not_finish", p.books_api.patches[1].status, "did_not_finish")

print("\n== ask mode confirms once per sync ==")
p:setAutomationMode("books_status", "ask")
p.books_api.patches = {}
sidecars["/b/one.epub"].summary.status = "reading"
p.books_state[1].remote_status = "did_not_finish"
BOOKS[1].status = "did_not_finish"
confirms = {}
coroutine.wrap(function() p:syncReadwiseBooks() end)()
check("asked once", #confirms, 1)
check("sent after yes", p.books_api.patches[1] and p.books_api.patches[1].status, "currently_reading")

print("\n== keep on device ==")
p.document_categories = { r1 = "epub" }
check("books deleted by default", p:keepsOnDevice("a1", "/x/article.html"), false)
check("book not kept by default", p:keepsOnDevice("r1", "/b/one.epub"), false)
p.books_keep.r1 = true
check("kept book", p:keepsOnDevice("r1", "/b/one.epub"), true)
p.books_keep.r1 = nil
p.delete_finished_books = false
check("global off keeps every book", p:keepsOnDevice("r9", "/b/nine.epub"), true)
check("articles still deletable", p:keepsOnDevice("a1", "/x/article.html"), false)

print("\n== open ==")
local q = newPlugin({ { id = 5, status = "want_to_read" }, { id = 6, status = "finished" } }, {})
q.getBooksIdForFile = function(_, path) return path == "/b/five.epub" and 5 or 6 end
q.isDocumentOpen = function() return true end
q:booksOnOpen("/b/five.epub")
check("open -> currently_reading", q.books_api.patches[1].status, "currently_reading")
check("open -> first start date", q.books_api.patches[1].started_reading_at ~= nil, true)
q.ui.doc_settings = DocSettings:open("/b/six.epub")
q:booksOnOpen("/b/six.epub")
-- default for books_reread is Ask; outside a coroutine that is a dialog,
-- so nothing is sent until it's answered.
check("finished book: no silent re-read", #q.books_api.patches, 1)
q:setAutomationMode("books_reread", "auto")
q:booksOnOpen("/b/six.epub")
check("re-read moves back to reading", q.books_api.patches[2].status, "currently_reading")
check("open book marked reading", sidecars["/b/six.epub"].summary.status, "reading")

print("== new Reader books get their shelf before download ==")
local NEW_BOOKS = {
    { id = 11, title = "Reading Now", author = "Ann Writer", status = "currently_reading" },
    { id = 12, title = "Someday", author = "Bob Writer", status = "want_to_read" },
}
local n = newPlugin(NEW_BOOKS, {})
local list_calls = 0
n.reader_api = { listEpubIdentities = function()
    list_calls = list_calls + 1
    return {
        { id = "new1", title = "Reading Now", author = "Ann Writer" },
        { id = "new2", title = "Someday", author = "Bob Writer" },
        { id = "new3", title = "Not in Books", author = "Nobody" },
    }
end }
local new_shelves = n:syncReadwiseBooks()
check("nothing local: no Reader list during the Books step", list_calls, 0)
n:addCandidateShelves(new_shelves, { "new1", "new2", "new3" })
check("new book matched", new_shelves.new1, "currently_reading")
check("other shelf matched", new_shelves.new2, "want_to_read")
check("unknown book has no shelf", new_shelves.new3, nil)
check("one Reader list", list_calls, 1)
new_shelves = n:syncReadwiseBooks()
n:addCandidateShelves(new_shelves, { "new3" })
check("known-unmatched book: no new list", list_calls, 1)
check("mapped book shelf comes from the Books step", new_shelves.new1, "currently_reading")

print(failures == 0 and "\nall passed" or string.format("\n%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
