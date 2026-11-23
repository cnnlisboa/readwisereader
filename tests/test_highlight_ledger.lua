package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Ledger = require("library/highlight_ledger")
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

print("== send decisions ==")
local ledger = {}
local h1 = Ledger.hashFor("text", "note")
check("new is sent", Ledger.shouldSend(ledger, "k1", h1), true)
Ledger.recordSent(ledger, "k1", h1, 100)
check("unchanged not resent", Ledger.shouldSend(ledger, "k1", h1), false)
check("edited note resent", Ledger.shouldSend(ledger, "k1", Ledger.hashFor("text", "new note")), true)
Ledger.markDeleted(ledger, "k1", 200)
check("deleted never resent", Ledger.shouldSend(ledger, "k1", Ledger.hashFor("text", "edited")), false)
Ledger.recordSent(ledger, "k1", h1, 300)
check("record after delete keeps deleted", ledger.k1.state, "deleted_remotely")
check("keyless always sent", Ledger.shouldSend(ledger, nil, h1), true)
check("text key", Ledger.keyFor(nil, "Book", "Passage"):sub(1, 1), "t")
check("annotation key wins", Ledger.keyFor("123-abc", "Book", "Passage"), "123-abc")
check("key from url", Ledger.keyFromUrl("https://read.readwise.io/read/x#koreader-123-abc"), "123-abc")

print("\n== first-run fill from the export ==")
local export = {
    { title = "Book", source = "koreader", highlights = {
        { url = "https://r/x#koreader-a", text = "A", note = "n", is_deleted = false },
        { url = "https://r/x#koreader-b", text = "B", note = "", is_deleted = true },
        { url = nil, text = "Kindle passage", note = "", is_deleted = true },
    } },
}
local index = Ledger.indexExport(export)
local fresh = {}
local counts = Ledger.migrate(fresh, index, {
    { key = "a", annotation_key = "a", title = "Book", text = "A", note = "n" },
    { key = "b", annotation_key = "b", title = "Book", text = "B" },
    { key = "c", annotation_key = "c", title = "Book", text = "C" },
    { key = Ledger.keyFor(nil, "Book", "Kindle passage"), title = "Book", text = "Kindle passage" },
}, 1)
check("existing counted as sent", counts.sent, 1)
check("deleted remembered", counts.deleted, 2)
check("missing left to send", counts.new, 1)
check("existing not resent", Ledger.shouldSend(fresh, "a", Ledger.hashFor("A", "n")), false)
check("local edit since then is sent", Ledger.shouldSend(fresh, "a", Ledger.hashFor("A", "edited")), true)
check("deleted not resent", Ledger.shouldSend(fresh, "b", Ledger.hashFor("B", "")), false)
check("new one sent", Ledger.shouldSend(fresh, "c", Ledger.hashFor("C", "")), true)

print("\n== deletions found later ==")
local later = { a = { hash = "x" }, [Ledger.keyFor(nil, "Book", "K2")] = { hash = "y" } }
local marked = Ledger.applyRemoteDeletions(later, Ledger.indexExport({
    { title = "Book", source = "koreader", highlights = {
        { url = "https://r#koreader-a", text = "A", is_deleted = true },
        { text = "K2", is_deleted = true },
    } },
}))
check("both deletions marked", marked, 2)
check("keyed deletion", later.a.state, "deleted_remotely")

print("\n== chapter headings ==")
local booknotes = {
    { { text = "one", chapter = "Chapter 1", page = 5, time = 1000 } },
    { { text = "two", chapter = "Chapter 1", page = 6, time = 1001 } },
    { { text = "Chapter 2", note = ".h2", chapter = "Chapter 2", page = 9, time = 1002 } },
    { { text = "three", chapter = "Chapter 2", page = 10, time = 1003 } },
    { { text = "four", chapter = "  Chapter 3 ", page = 20, time = 1004 } },
}
local headings = Ledger.chapterHeadings(booknotes, "h2")
check("one per chapter, manual heading respected", #headings, 2)
check("first heading", headings[1].text, "Chapter 1")
check("heading note", headings[1].note, ".h2")
check("heading page", headings[1].page, 5)
check("trimmed title", headings[2].text, "Chapter 3")
check("stable key", headings[1].heading_key, "chapter-" .. Ledger.shortHash("Chapter 1"))
check("heading url uses its key", Highlights.buildHighlightUrl("https://r/x", headings[1]),
    "https://r/x#koreader-" .. headings[1].heading_key)

print("\n== exporter reports accepted highlights ==")
local api = Highlights:new{ request = function() return { { modified_highlights = { 1, 2 } } } end }
local report = api:export({ { context = {
    title = "Book",
    include = function(c) return c.text ~= "skip" end,
    meta = function(c) return { key = c.text } end,
}, booknotes = { { { text = "x" }, { text = "skip" }, { text = "y" } } } } })
check("two sent", report.sent, 2)
check("accepted reported", #report.accepted, 2)
check("accepted meta", report.accepted[2].key, "y")

print("\n== highlight tags ==")
package.loaded["api/highlights"] = Highlights
local HighlightTags = require("highlight_tags")
local epoch = HighlightTags.datetimeToEpoch("2026-11-23 10:20:30")
check("datetime parsed", os.date("%Y-%m-%d %H:%M:%S", epoch), "2026-11-23 10:20:30")
local key = HighlightTags.keyForAnnotation({ datetime = "2026-11-23 10:20:30", page = "/body/p[3]" })
check("same key as the exporter", key, Highlights.annotationKey({ time = epoch, pn_xp = "/body/p[3]" }))
local add, remove = HighlightTags.diff({ "reference/book", "h2" }, { "H2", "old" })
check("add", table.concat(add, ","), "reference/book")
check("remove", table.concat(remove, ","), "old")
local ids = { a = {}, ["t" .. Ledger.shortHash("Book\0K")] = {} }
Ledger.recordRemoteIds(ids, Ledger.indexExport({ { title = "Book", source = "koreader", highlights = {
    { id = 11, url = "https://r#koreader-a", text = "A" }, { id = 12, text = "K" } } } }))
check("v2 id by key", ids.a.v2_id, 11)
check("v2 id by text", ids["t" .. Ledger.shortHash("Book\0K")].v2_id, 12)

print(failures == 0 and "\nall passed" or string.format("\n%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
