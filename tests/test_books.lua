package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Books = require("api/books")
local BooksMap = require("library/books_map")
local Automation = require("library/automation")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-56s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-56s %s", name, tostring(got)))
    end
end

print("== query building ==")
check("sorted, arrays joined", Books.buildQuery({ limit = 5, ids = { 1, 2 } }), "?ids=1%2C2&limit=5")
check("empty", Books.buildQuery({}), "")
check("cursor from next", Books.cursorFromNext("https://x/books?limit=2&cursor=ab%3D%3D"), "ab==")
check("no next", Books.cursorFromNext(nil), nil)
check("chunks of 10", #Books.chunks({1,2,3,4,5,6,7,8,9,10,11}, 10), 2)

print("\n== ratings ==")
check("snap 4.1 -> 4", Books.snapRating(4.1), 4)
check("snap 4.2 -> 4.25", Books.snapRating(4.2), 4.25)
check("7 -> 5", Books.snapRating(7), 5)
check("0 -> nil", Books.snapRating(0), nil)
check("text -> nil", Books.snapRating("x"), nil)
check("string number", Books.snapRating("3.5"), 3.5)

print("\n== update validation ==")
check("bad shelf dropped", Books.validateUpdate({ id = 1, status = "unsorted" }), nil)
check("id only dropped", Books.validateUpdate({ id = 1 }), nil)
check("no id dropped", Books.validateUpdate({ status = "finished" }), nil)
local v = Books.validateUpdate({ id = 1, status = "finished", rating = 6, bogus = 1 })
check("status kept", v.status, "finished")
check("rating capped", v.rating, 5)
check("unknown field stripped", v.bogus, nil)
check("pages range", Books.validateUpdate({ id = 1, manual_total_pages = 6000 }), nil)

print("\n== batched update via stub transport ==")
local calls = {}
local api = Books:new{ request = function(method, endpoint, body)
    table.insert(calls, { method = method, endpoint = endpoint, body = body })
    local results = {}
    for _, item in ipairs(body.items) do
        if item.id == 404 then
            table.insert(results, { id = 404, status = "error", error = { code = "not_found", message = "x" } })
        else
            table.insert(results, { id = item.id, status = "updated", error = nil })
        end
    end
    return { results = results }
end }
local res = api:update({ { id = 1, status = "finished" }, { id = 2 }, { id = 404, status = "finished" } })
check("one request", #calls, 1)
check("body uses items", #calls[1].body.items, 2)
check("first ok", res[1].ok, true)
check("unsendable reported at its index", res[2].code, "invalid_value")
check("item error read", res[3].code, "not_found")
check("not_found not retryable", Books.isRetryable(res[3]), false)

local api_down = Books:new{ request = function() return nil, "network_error" end }
local down = api_down:update({ { id = 1, status = "finished" } })
check("network failure per item", down[1].code, "network_error")
check("network failure retryable", Books.isRetryable(down[1]), true)

print("\n== listAll follows cursors ==")
local pages = {
    ["/books?limit=1000"] = { results = { { id = 1 } }, next = "https://x/books?cursor=c2&limit=1000" },
    ["/books?cursor=c2&limit=1000"] = { results = { { id = 2 }, { id = 3 } }, next = nil },
}
local list_api = Books:new{ request = function(_, endpoint) return pages[endpoint] end }
local all = list_api:listAll()
check("all pages read", #all, 3)
local broken = Books:new{ request = function() return { oops = true } end }
check("bad shape is an error", select(2, broken:listAll()), "invalid_response")

print("\n== sessions validation ==")
check("ebook needs percents", Books.validateSession({ book_id = 1, started_at = "a", ended_at = "b", format = "ebook" }), nil)
check("ebook ok", Books.validateSession({ book_id = 1, started_at = "a", ended_at = "b", format = "ebook",
    percent_at_start = 0.1, percent_at_end = 0.2 }) ~= nil, true)
check("backwards percents rejected", Books.validateSession({ book_id = 1, started_at = "a", ended_at = "b",
    format = "ebook", percent_at_start = 0.3, percent_at_end = 0.2 }), nil)

print("\n== title keys ==")
local keys = BooksMap.titleKeys("The Great Mental Models: General Thinking Concepts")
check("full key", keys[1], "thegreatmentalmodelsgeneralthinkingconcepts")
check("subtitle stripped", keys[2], "thegreatmentalmodels")
check("article stripped", keys[3], "greatmentalmodelsgeneralthinkingconcepts")
check("accent folded", BooksMap.titleKeys("Ética a Nicômaco")[1], "eticaanicomaco")

print("\n== matching ==")
local docs = {
    { id = "r1", title = "Scientific Advertising", author = "Claude C. Hopkins", saved_at = "2026-11-21T00:47:40Z" },
    { id = "r2", title = "The Devil's Pulpit: A Novel", author = "X", saved_at = "2026-01-01T00:00:00Z" },
    { id = "r3", title = "Twin", author = "A", saved_at = "2026-01-01T00:00:00Z" },
    { id = "r4", title = "Unknown Book", author = "Nobody" },
    { id = "r5", title = "Same", author = "A", saved_at = "2026-03-01T00:00:00Z" },
}
local books = {
    { id = 10, title = "Scientific Advertising", author = "Claude C. Hopkins", created = "2026-11-21T00:47:42Z" },
    { id = 20, title = "Devil's Pulpit", author = "X", created = "2026-01-01T00:00:01Z" },
    { id = 30, title = "Twin", author = "A", created = "2025-01-01T00:00:00Z" },
    { id = 31, title = "Twin", author = "A", created = "2025-06-01T00:00:00Z" },
    { id = 50, title = "Same", author = "A", created = "2026-03-01T00:00:30Z" },
    { id = 51, title = "Same", author = "A", created = "2025-03-01T00:00:00Z" },
    { id = 60, title = "Scientific Advertising", author = "Claude C. Hopkins", status = "deleted" },
}
local m, unmatched = BooksMap.matchBooks(docs, books)
check("exact match", m.r1, 10)
check("article + subtitle stripped", m.r2, 20)
check("unbreakable tie left unmatched", m.r3, nil)
check("no match", m.r4, nil)
check("tie broken by created ~ saved_at", m.r5, 50)
check("unmatched listed", #unmatched, 2)

local m2 = BooksMap.matchBooks({
    { id = "h", title = "Scientific Advertising", author = "Claude Hopkins", saved_at = "2020-01-01T00:00:00Z" },
    { id = "k", title = "Magnetic Marketing: How To Attract", author = "Kennedy, Dan", saved_at = "2020-01-01T00:00:00Z" },
    { id = "p", title = "O Príncipe", author = "Nicolau Maquiavel", saved_at = "2026-11-21T00:47:10Z" },
    { id = "w1", title = "A Wild Sheep Chase", author = "Haruki Murakami", reading_progress = 0.77, saved_at = "2026-05-31T00:00:00Z" },
    { id = "w2", title = "A Wild Sheep Chase", author = "Haruki Murakami", reading_progress = 0.55, saved_at = "2025-10-28T00:00:00Z" },
    { id = "o1", title = "Ogilvy", author = "D", saved_at = "2026-04-30T00:00:00Z" },
    { id = "o2", title = "Ogilvy", author = "D", saved_at = "2026-11-21T00:00:00Z" },
}, {
    { id = 1, title = "Scientific Advertising", author = "Claude C. Hopkins", created = "2026-01-01T00:00:00Z" },
    { id = 2, title = "Magnetic Marketing", author = "Dan S. Kennedy", created = "2026-01-01T00:00:00Z" },
    { id = 3, title = "Príncipe", author = "Niccolo Machiavelli", created = "2026-11-21T00:47:19Z" },
    { id = 4, title = "A Wild Sheep Chase", author = "Haruki Murakami", progress = 0.55, created = "2026-10-28T00:00:00Z" },
    { id = 5, title = "A Wild Sheep Chase", author = "Haruki Murakami", progress = 0.77, created = "2026-10-28T00:00:01Z" },
    { id = 6, title = "Ogilvy", author = "D", created = "2026-10-28T00:00:00Z" },
})
check("middle initial ignored", m2.h, 1)
check("surname-first author", m2.k, 2)
check("Portuguese article + upload time", m2.p, 3)
check("duplicate split by progress (a)", m2.w1, 5)
check("duplicate split by progress (b)", m2.w2, 4)
check("oldest Reader copy wins", m2.o1, 6)
check("second copy unmatched", m2.o2, nil)

print("\n== status mapping ==")
check("reading", BooksMap.shelfForLocal("reading"), "currently_reading")
check("complete", BooksMap.shelfForLocal("complete"), "finished")
check("on hold", BooksMap.shelfForLocal("abandoned"), "did_not_finish")
check("new + TBR", BooksMap.shelfForLocal("new", true), "want_to_read")
check("new alone", BooksMap.shelfForLocal("new", false), nil)

print("\n== open ==")
local NOW = 1795000000
local open1 = BooksMap.planOpen({ id = 1, status = "want_to_read" }, NOW)
check("open moves to reading", open1.patch.status, "currently_reading")
check("open sets first start", open1.patch.started_reading_at, BooksMap.isoNow(NOW))
check("open of finished asks", BooksMap.planOpen({ id = 1, status = "finished" }).prompt, "reread")
check("already reading, dated", BooksMap.planOpen({ id = 1, status = "currently_reading", started_reading_at = "x" }), nil)
local reread = BooksMap.planReread({ id = 1, status = "finished", finished_reading_at = "f" })
check("re-read keeps dates", reread.patch.finished_reading_at, nil)
check("re-read status", reread.patch.status, "currently_reading")

print("\n== local changes ==")
local p = BooksMap.planLocalChange({ id = 1, status = "currently_reading" },
    { status = "complete", rating = 4 }, { local_status = "reading" }, NOW)
check("finish -> finished", p.status, "finished")
check("finish date filled", p.finished_reading_at, BooksMap.isoNow(NOW))
check("rating filled when empty", p.rating, 4)
p = BooksMap.planLocalChange({ id = 1, status = "currently_reading", finished_reading_at = "first", rating = 3 },
    { status = "complete", rating = 4 }, { local_status = "reading" }, NOW)
check("first finish date kept", p.finished_reading_at, nil)
check("existing rating not overwritten", p.rating, nil)
check("finished is sticky", BooksMap.planLocalChange({ id = 1, status = "finished" },
    { status = "reading" }, { local_status = "complete" }), nil)
check("TBR never pulls a started book back", BooksMap.planLocalChange({ id = 1, status = "currently_reading" },
    { status = "new", in_tbr = true }, { local_status = "new" }), nil)
p = BooksMap.planLocalChange({ id = 1, status = "currently_reading" }, { status = "abandoned" }, { local_status = "reading" })
check("on hold -> did_not_finish", p.status, "did_not_finish")
check("unchanged -> nothing", BooksMap.planLocalChange({ id = 1, status = "currently_reading" },
    { status = "reading" }, { local_status = "reading" }), nil)

print("\n== remote changes ==")
check("first sight: shelf without dates", (function()
    local fp = BooksMap.planLocalChange({ id = 1, status = "want_to_read" }, { status = "complete" }, {}, NOW)
    return fp.status == "finished" and fp.finished_reading_at == nil
end)(), true)
check("first sight is a baseline", select(2, BooksMap.planRemoteChange({ id = 1, status = "finished" },
    { status = "reading" }, {})), "baseline")
local a = BooksMap.planRemoteChange({ id = 1, status = "finished" }, { status = "reading" }, { remote_status = "currently_reading" })
check("finished -> complete", a.status, "complete")
a = BooksMap.planRemoteChange({ id = 1, status = "did_not_finish" }, { status = "reading" }, { remote_status = "currently_reading" })
check("dnf -> on hold", a.status, "abandoned")
a = BooksMap.planRemoteChange({ id = 1, status = "want_to_read" }, { status = "new" }, { remote_status = "unsorted" }, { tbr = true })
check("want_to_read -> TBR when enabled", a.add_tbr, true)
check("want_to_read ignored when disabled", BooksMap.planRemoteChange({ id = 1, status = "want_to_read" },
    { status = "new" }, { remote_status = "unsorted" }, { tbr = false }), nil)
a = BooksMap.planRemoteChange({ id = 1, status = "currently_reading", rating = 3.75 }, { status = "reading" },
    { remote_status = "currently_reading" })
check("rating filled on device, rounded", a.rating, 4)
check("device rating kept", BooksMap.planRemoteChange({ id = 1, status = "currently_reading", rating = 2 },
    { status = "reading", rating = 5 }, { remote_status = "currently_reading" }), nil)

print("\n== automation ==")
check("default", Automation.mode({}, "books_reread"), "ask")
check("override", Automation.mode({ books_reread = "manual" }, "books_reread"), "manual")
check("bad value falls back", Automation.mode({ books_open = "x" }, "books_open"), "auto")
check("manual trigger always runs", Automation.decide({ sessions = "manual" }, "sessions", "manual"), "run")
check("manual mode skips auto trigger", Automation.decide({ sessions = "manual" }, "sessions", "auto"), "skip")
check("ask mode asks", Automation.decide({ sessions = "ask" }, "sessions", "auto"), "ask")
local migrated = Automation.migrate(nil, { archive_finished = false, export_highlights_at_sync = true })
check("legacy archive off -> manual", migrated.archive_finished, "manual")
check("legacy export on -> auto", migrated.send_highlights, "auto")
check("existing mode not overwritten", Automation.migrate({ archive_finished = "ask" }, { archive_finished = true }).archive_finished, "ask")

print("\n== sessions ==")
local Sessions = require("library/sessions")
local T0 = 1795000000
local rows = {
    { page = 10, start_time = T0, duration = 60, total_pages = 100 },
    { page = 11, start_time = T0 + 60, duration = 60, total_pages = 100 },
    { page = 12, start_time = T0 + 240, duration = 60, total_pages = 100 }, -- 2 min pause
    { page = 13, start_time = T0 + 3600, duration = 30, total_pages = 100 }, -- new, too short
    { page = 50, start_time = T0 + 7200, duration = 100, total_pages = 200 },
    { page = 52, start_time = T0 + 7300, duration = 100, total_pages = 200 },
}
local ss = Sessions.build(rows, { gap = 300, min_seconds = 120 })
check("two sessions kept (short one dropped)", #ss, 2)
check("pause counted", ss[1].paused, 120)
check("start percent", ss[1].percent_start, 0.09)
check("end percent", ss[1].percent_end, 0.12)
check("repagination handled", ss[2].percent_start, 49 / 200)
local ledger = Sessions.record({}, ss[1])
check("watermark moves", ledger.watermark, T0)
check("sent not resent", #Sessions.pending(ss, ledger), 1)
check("open book holds latest", #Sessions.pending(ss, {}, T0 + 7300), 1)
local item = Sessions.toItem(ss[1], 7, { device = { model = "K", type = "E-Reader", vendor = "Amazon" } })
check("item valid", Books.validateSession(item) ~= nil, true)
check("item format", item.format, "ebook")
check("already remote by times", Sessions.alreadyRemote(ss[1], {
    { started_at = Sessions.iso(T0 + 30), ended_at = Sessions.iso(ss[1].ended) } },
    require("library/progress").toEpoch), true)

print(failures == 0 and "\nall passed" or string.format("\n%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
