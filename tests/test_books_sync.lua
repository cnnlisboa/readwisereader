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
    self:initFinishOptions({})
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

print("\n== finish options and keep on device ==")
local FinishOptions = require("finish_options")
p.document_categories = { r1 = "epub" }
check("default: articles only", p.finish_scope, "articles")
check("books kept by default", p:keepsOnDevice("r1", "/b/one.epub"), true)
check("articles deletable by default", p:keepsOnDevice("a1", "/x/article.html"), false)
p.saveSettings = function() end
p:setKeptOnDevice("a1", true, "Article")
check("kept article", p:keepsOnDevice("a1", "/x/article.html"), true)
p:setKeptOnDevice("a1", false)
p.finish_scope = "books"
check("books only: book deletable", p:keepsOnDevice("r1", "/b/one.epub"), false)
check("books only: article kept", p:keepsOnDevice("a2", "/x/other.html"), true)
p.finish_scope = "all"
p.finish_delete = false
check("delete off keeps everything", p:keepsOnDevice("a2", "/x/other.html"), true)
p.finish_scope, p.finish_delete = "articles", true
check("migrate: old delete-books on", FinishOptions.migrate({ delete_finished_books = true }).scope, "all")
check("migrate: old keep list", FinishOptions.migrate({ books_keep = { r9 = true } }).keep.r9 ~= nil, true)
local plan = FinishOptions.plan({ scope = "all", archive = true, delete = true }, true, true, false)
check("kept: archived, not deleted", plan.archive and not plan.delete, true)
plan = FinishOptions.plan({ scope = "all", archive = true, delete = true }, true, true, true)
check("kept and archived: nothing more", plan.archive or plan.delete, false)
plan = FinishOptions.plan({ scope = "articles", archive = true, delete = true }, true, false, false)
check("out of scope: untouched", plan.archive or plan.delete, false)
plan = FinishOptions.plan({ scope = "all", archive = false, delete = true }, false, false, false)
check("delete without archive", not plan.archive and plan.delete, true)

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

print("== shelves for the Library browser ==")
local SHELF_BOOKS = {
    { id = 21, title = "Reading Now", author = "Ann Writer", status = "currently_reading" },
    { id = 22, title = "Paper Only", author = "Cy Writer", status = "currently_reading" },
    { id = 23, title = "Someday", author = "Bob Writer", status = "want_to_read" },
    { id = 24, title = "Gone", author = "Dee Writer", status = "deleted" },
}
local s = newPlugin(SHELF_BOOKS, {})
s.reader_api = { listEpubIdentities = function()
    return {
        { id = "d1", title = "Reading Now", author = "Ann Writer", location = "later", reading_progress = 0.4 },
        { id = "d2", title = "Someday", author = "Bob Writer", location = "new" },
    }
end }
local shelves_view = s:loadBooksShelves()
check("reading shelf lists the Reader book", shelves_view.currently_reading.documents[1].id, "d1")
check("listed as an EPUB", shelves_view.currently_reading.documents[1].category, "epub")
check("keeps Reader location", shelves_view.currently_reading.documents[1].location, "later")
check("book not in Reader counted", shelves_view.currently_reading.not_in_reader, 1)
check("want to read shelf", shelves_view.want_to_read.documents[1].id, "d2")
check("deleted books left out", shelves_view.deleted, nil)
check("mapping remembered", s.books_ids.d1, 21)
local failing = newPlugin(SHELF_BOOKS, {})
failing.books_api.listAll = function() return nil, "network_error" end
local none, shelf_err = failing:loadBooksShelves()
check("list failure reported", none == nil and shelf_err, "network_error")

print("\n== positions: only what changed, books first ==")
local pos = newPlugin(BOOKS, {})
pos.sync_reading_progress = true
local asked_since
pos.reader_api = { listUpdatedSince = function(_, since)
    asked_since = since
    return {
        { id = "art1", category = "article" },
        { id = "bk1", category = "epub" },
        { id = "remote_only", category = "article" },
    }
end }
pos.getLocalDocumentPaths = function()
    return { art1 = "/a/[rw-id_art1] A.html", bk1 = "/b/B [rw-bk1].epub",
        art2 = "/a/C [rw-art2].html", bk2 = "/b/D [rw-bk2].epub" }
end
local reconciled, pushed_order = nil, {}
pos.reconcileReadingProgress = function(_, docs)
    reconciled = {}
    for _, d in ipairs(docs) do table.insert(reconciled, d.id) end
    return 1, 0
end
pos.readLocalProgressState = function() return 0.5, 0, false end
pos.pushReadingProgress = function(_, doc_id) table.insert(pushed_order, doc_id); return doc_id == "bk2" end
local result = pos:syncLocalPositions()
check("first check looks back 30 days", asked_since ~= nil, true)
check("changed: book first", table.concat(reconciled, ","), "bk1,art1")
check("unchanged: book first, changed ones skipped", table.concat(pushed_order, ","), "bk2,art2")
check("counts", result.seeded .. "/" .. result.pushed, "1/1")
check("checked time saved", pos.positions_checked_at ~= nil, true)
pushed_order = {}
pos:syncLocalPositions("books")
check("books only: articles left out", table.concat(reconciled, ",") .. "|" .. table.concat(pushed_order, ","), "bk1|bk2")
pos.sync_reading_progress = false
check("off: nothing asked", pos:syncLocalPositions().pushed, 0)

print("\n== sync reading data: order of steps ==")
local rd = newPlugin(BOOKS, {})
local order = {}
local function mark(name, value) return function() table.insert(order, name); return value end end
rd.flushPendingLinkSaves, rd.flushPendingTagUpdates, rd.flushPendingNoteUpdates = mark("queue"), function() end, function() end
rd.cleanupProgressNotes = function() end
rd.syncLocalPositions = mark("positions", { seeded = 0, pushed = 2 })
local device_runs = 0
rd.ui = { device_sync = { syncReadingDataQuietly = function()
    device_runs = device_runs + 1
    table.insert(order, "device" .. device_runs)
    return { sent = 1, received = 0 }
end } }
rd.automationMode = function() return "auto" end
rd.runAutomated = function(_, _, _, fn) fn() end
rd.exportHighlights = function(self_, only)
    table.insert(order, "highlights" .. (only and "(books)" or ""))
    self_.reader_ids_stamped = 1
    return 3, nil, 0
end
rd.highlight_tags = { k = { pending = true } }
rd.refreshReadwiseTagCache = function() end
rd.applyPendingHighlightTags = mark("tags", 1)
rd.syncBookNotes = mark("book notes", { sent = 1, received = 0, conflicts = 0 })
rd.syncReadwiseBooks = mark("books", { r1 = "currently_reading" })
rd.syncSessions = mark("sessions", 0)
rd.getLocalBooks = function() return { r1 = "/b/one.epub" } end
local reading = rd:syncReadingData()
check("order", table.concat(order, ","),
    "queue,positions,device1,highlights,tags,book notes,books,device2")
check("highlights counted", reading.highlights, 3)
check("summary lines", #reading.lines, 5)
order, device_runs = {}, 0
rd.reader_ids_stamped = 0
rd.exportHighlights = function(_, only) table.insert(order, "highlights" .. (only and "(books)" or "")); return 0, nil, 0 end
rd:syncReadingData("books")
check("books only: highlights limited, no second device pass", table.concat(order, ","),
    "queue,positions,device1,highlights(books),tags,book notes,books")

local SyncModes = require("sync_modes")
check("booksFirst keeps order", table.concat(SyncModes.booksFirst({ "a1", "b1", "a2", "b2" },
    function(x) return x:sub(1, 1) == "b" end), ","), "b1,b2,a1,a2")

print(failures == 0 and "\nall passed" or string.format("\n%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
