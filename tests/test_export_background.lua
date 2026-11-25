package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local RateLimit = require("library/rate_limit")
local Job = require("library/background_job")
local Journal = require("library/export_journal")
local ReaderHighlights = require("api/reader_highlights")
local Highlights = require("api/highlights")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-56s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-56s %s", name, tostring(got)))
    end
end

print("== rate limit ==")
RateLimit.reset()
check("reader write bucket", RateLimit.bucket("POST", "https://readwise.io/api/v3/save/"), "reader_write")
check("reader read bucket", RateLimit.bucket("GET", "https://readwise.io/api/v3/list/"), "reader_read")
check("v2 write bucket", RateLimit.bucket("POST", "https://readwise.io/api/v2/highlights"), "v2_write")
check("v2 read bucket", RateLimit.bucket("GET", "https://readwise.io/api/v2/export/"), "v2_read")
-- 12 placements in a row (the Boox case) never wait.
local waited = 0
for i = 1, 12 do
    waited = waited + RateLimit.delay("reader_write", 1000 + i)
    RateLimit.record("reader_write", 1000 + i)
end
check("12 placements: no waiting", waited, 0)
for i = 13, 45 do RateLimit.record("reader_write", 1000 + i) end
check("budget full: waits for the oldest to age out", RateLimit.delay("reader_write", 1046), 15)
check("a minute later: free", RateLimit.delay("reader_write", 1106), 0)
RateLimit.block("reader_read", 30, 2000)
check("after 429: blocked for Retry-After", RateLimit.delay("reader_read", 2000), 30)
check("after Retry-After: free", RateLimit.delay("reader_read", 2030), 0)

print("\n== background job ==")
local queue = {}
local fake = {
    scheduleIn = function(seconds, fn) table.insert(queue, { at = seconds, fn = fn }) end,
    nextTick = function(fn) table.insert(queue, { at = 0, fn = fn }) end,
    unschedule = function(fn)
        for i = #queue, 1, -1 do if queue[i].fn == fn then table.remove(queue, i) end end
    end,
}
Job.setup{ scheduler = fake, logger = { warn = function() end } }
local function runQueue(limit)
    local ran = 0
    while #queue > 0 and ran < (limit or 100) do
        local item = table.remove(queue, 1)
        item.fn()
        ran = ran + 1
    end
    return ran
end
local steps, done = {}, nil
check("start", Job.start("t", function()
    table.insert(steps, "a")
    check("inside the task", Job.inside(), true)
    Job.wait(0)
    table.insert(steps, "b")
    Job.wait(5)
    table.insert(steps, "c")
end, function(ok) done = ok end), true)
check("second start refused", Job.start("u", function() end), false)
check("outside the task", Job.inside(), false)
runQueue(1)
check("ran to first yield", table.concat(steps), "a")
check("next step on nextTick", queue[1] and queue[1].at, 0)
runQueue(1)
check("rate wait is a timer", queue[1] and queue[1].at, 5)
Job.pause()
check("pause drops the timer", #queue, 0)
Job.resume(function() return false end, 4)
check("resume waits for network", queue[1] and queue[1].at, 2)
runQueue(1)
check("still waiting", queue[1] and queue[1].at, 2)
runQueue(1) -- gives up waiting after 4 s
runQueue()
check("finished", table.concat(steps), "abc")
check("done callback ok", done, true)
check("not running", Job.running(), false)
-- Outside a task, wait sleeps like before.
local slept
Job.wait(3, function(s) slept = s end)
check("outside: sleeps", slept, 3)
-- An error ends the task and reports it.
local failed_ok, failed_err
Job.start("bad", function() error("boom") end, function(ok, err) failed_ok, failed_err = ok, err end)
runQueue()
check("error reported", failed_ok, false)
check("error message", tostring(failed_err):match("boom"), "boom")

print("\n== journal merge ==")
local plugin = {
    highlight_ledger = {
        a = { hash = "old", sent_at = 1 },
        b = { hash = "x", sent_at = 1, state = "processed" },
        c = { hash = "y", sent_at = 1, v2_id = 9 },
    },
    reader_highlight_records = { doc1 = { k1 = { id = "r1", note = "" } } },
    highlight_ledger_migrated = false,
    highlight_deletions_checked_at = "2026-11-25T10:00:00Z",
}
Journal.merge(plugin, {
    ledger = { a = { hash = "new", sent_at = 2 }, b = { hash = "x2", sent_at = 2 }, c = { hash = "y2", sent_at = 2 },
        d = { hash = "z", sent_at = 2 } },
    records = { doc1 = { k2 = { id = "r2", note = "" } }, doc2 = { k3 = { fallback = true } } },
    ledger_migrated = true,
    deletions_checked_at = "2026-11-25T11:00:00Z",
})
check("journal entry wins", plugin.highlight_ledger.a.hash, "new")
check("processed state kept", plugin.highlight_ledger.b.state, "processed")
check("v2 id kept", plugin.highlight_ledger.c.v2_id, 9)
check("new entry added", plugin.highlight_ledger.d.hash, "z")
check("records kept", plugin.reader_highlight_records.doc1.k1.id, "r1")
check("records added", plugin.reader_highlight_records.doc1.k2.id, "r2")
check("new doc records", plugin.reader_highlight_records.doc2.k3.fallback, true)
check("migrated", plugin.highlight_ledger_migrated, true)
check("later check time", plugin.highlight_deletions_checked_at, "2026-11-25T11:00:00Z")
Journal.merge(plugin, { deletions_checked_at = "2026-11-25T09:00:00Z" })
check("older check time ignored", plugin.highlight_deletions_checked_at, "2026-11-25T11:00:00Z")

print("\n== reconcile interrupted placements ==")
check("normalize", Journal.normalize("<p>Tom &amp; Jerry\n  run</p>"), "Tom & Jerry run")
local records = {}
local inflight = {
    [Journal.inflightKey("doc", "k1")] = { doc = "doc", key = "k1", text = "Tom & Jerry run", note = "n" },
    [Journal.inflightKey("doc", "k2")] = { doc = "doc", key = "k2", text = "Never arrived" },
}
local found = Journal.reconcile(records, inflight, {
    { id = "h1", parent_id = "doc", content = "<p>Tom &amp; Jerry run</p>" },
    { id = "h2", parent_id = "other", content = "Never arrived" },
})
check("arrived one found", found, 1)
check("recorded with its id", records.doc and records.doc.k1 and records.doc.k1.id, "h1")
check("note kept", records.doc.k1.note, "n")
check("other parent not matched", records.doc.k2, nil)

print("\n== placement hooks ==")
local calls = {}
local api = ReaderHighlights:new{ request = function(method, endpoint)
    table.insert(calls, method .. " " .. endpoint)
    if method == "GET" then
        if endpoint:find("pageCursor") then return { results = { { id = "p2" } } } end
        return { results = { { id = "p1" } }, nextPageCursor = "c" }
    end
    return { id = "new" }
end }
local since = 100
local booknotes = { {
    { text = "one", time = 200, pn_xp = "a" },
    { text = "two", time = 201, pn_xp = "b" },
} }
local blocked_key = Highlights.annotationKey(booknotes[1][2])
local events = {}
local recs = {}
local report = api:exportBook("doc", "Book", booknotes, recs, since, {
    blocked = { [blocked_key] = true },
    before = function(key) table.insert(events, "before " .. key) end,
    after = function(key) table.insert(events, "after " .. key) end,
})
check("only the unblocked one placed", report.placed, 1)
check("one request", #calls, 1)
check("before then after", #events, 2)
check("before first", events[1]:sub(1, 6), "before")
check("blocked one left for later", recs[blocked_key], nil)
check("blocked one stays off v2 via caller", ReaderHighlights.sendsToV2(booknotes[1][2], recs, since), false)
calls = {}
local listed = api:listSince("2026-11-25T00:00:00Z")
check("list pages followed", listed and #listed, 2)
check("list asks for highlights", calls[1]:find("category=highlight", 1, true) ~= nil, true)

print("\n== v2 progress after every request ==")
local posts = 0
local v2 = Highlights:new{ request = function()
    posts = posts + 1
    return { { modified_highlights = { 1 } } }
end }
local flushes = {}
local books = { { context = { title = "T", meta = function(c) return { key = c.text } end }, booknotes = { {} } } }
for i = 1, 150 do table.insert(books[1].booknotes[1], { text = "h" .. i }) end
v2:export(books, function(accepted) table.insert(flushes, #accepted) end)
check("two batches", posts, 2)
check("flush per batch", #flushes, 2)
check("first batch accepted", flushes[1], 100)
check("second batch accepted", flushes[2], 50)

if failures > 0 then
    print(string.format("\n%d failure(s)", failures))
    os.exit(1)
end
print("\nall passed")
