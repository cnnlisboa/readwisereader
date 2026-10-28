package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local H = require("api/highlights")
local RH = require("api/reader_highlights")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

-- A fake transport answering the way Reader v3 documents: 201 with the new
-- document's id for a placed highlight, 400 when the passage is not found.
-- `opts.status(method, endpoint, body)` returns an error code to simulate.
local function fakeApi(opts)
    opts = opts or {}
    local log = {}
    local next_id = 0
    local api = RH:new{
        request = function(method, endpoint, body)
            table.insert(log, { method = method, endpoint = endpoint, body = body })
            local code = opts.status and opts.status(method, endpoint, body)
            if code then
                return nil, code == "network" and "network_error" or "http_error",
                    code ~= "network" and code or nil
            end
            if method == "POST" then
                next_id = next_id + 1
                return { id = "hl" .. next_id, url = "https://read.readwise.io/read/hl" .. next_id }
            end
            return { id = endpoint:match("/update/([^/]+)/") }
        end,
    }
    return api, log
end

local SINCE = 1700000000
local function clip(n, overrides)
    local c = { text = "passage " .. n, time = SINCE + n, pn_xp = "/body/DocFragment[" .. n .. "]" }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

print("== eligibility ==")
check("new highlight eligible", RH.isEligible(clip(1), SINCE), true)
check("made at cutoff eligible", RH.isEligible(clip(0), SINCE), true)
check("older highlight stays on v2", RH.isEligible(clip(1, { time = SINCE - 5 }), SINCE), false)
check("undated highlight stays on v2", RH.isEligible(clip(1, { time = false }), SINCE), false)
check("empty text not eligible", RH.isEligible(clip(1, { text = "" }), SINCE), false)

print("\n== placement ==")
local api, log = fakeApi()
local records = {}
local booknotes = { { clip(1, { note = "my note" }), clip(2), clip(3, { time = SINCE - 1 }) } }
local report = api:exportBook("doc1", "On Agency", booknotes, records, SINCE)
check("two eligible placed", report.placed, 2)
check("one request per eligible highlight", #log, 2)
check("POST to save", log[1].method .. " " .. log[1].endpoint, "POST /save/")
check("parent_id is the Reader document", log[1].body.parent_id, "doc1")
check("content is the passage", log[1].body.content, "passage 1")
check("note sent as notes", log[1].body.notes, "my note")
check("no notes key without a note", log[2].body.notes, nil)
check("saved_using", log[1].body.saved_using, "koreader")
check("record stores Reader id", records[H.annotationKey(clip(1))].id, "hl1")
check("old highlight left unrecorded", records[H.annotationKey(clip(3, { time = SINCE - 1 }))], nil)

print("\n== v2 routing ==")
check("placed highlight not sent to v2", RH.sendsToV2(clip(1), records, SINCE), false)
check("old highlight still sent to v2", RH.sendsToV2(clip(3, { time = SINCE - 1 }), records, SINCE), true)

print("\n== re-sync is idempotent ==")
local before = #log
local again = api:exportBook("doc1", "On Agency", booknotes, records, SINCE)
check("nothing re-created", #log, before)
check("nothing placed twice", again.placed, 0)

print("\n== note edits follow the highlight ==")
local edited = { { clip(1, { note = "revised" }), clip(2) } }
local r2 = api:exportBook("doc1", "On Agency", edited, records, SINCE)
check("one note update", r2.updated, 1)
check("PATCH to the placed highlight", log[#log].method .. " " .. log[#log].endpoint, "PATCH /update/hl1/")
check("only notes sent", log[#log].body.notes, "revised")
check("record keeps new note", records[H.annotationKey(clip(1))].note, "revised")
local cleared = { { clip(1) } }
api:exportBook("doc1", "On Agency", cleared, records, SINCE)
check("removing a note clears it in Reader", log[#log].body.notes, "")

print("\n== text edits are not sent ==")
before = #log
api:exportBook("doc1", "On Agency", { { clip(2, { text = "edited passage" }) } }, records, SINCE)
check("no request for a text-only edit", #log, before)

print("\n== passage not found falls back to v2 ==")
local api3, log3 = fakeApi{ status = function(method) return method == "POST" and 400 or nil end }
local rec3 = {}
local r3 = api3:exportBook("doc1", "On Agency", { { clip(1) } }, rec3, SINCE)
check("counted as unplaced", r3.unplaced, 1)
check("not a failure", #r3.failures, 0)
check("now sent to v2", RH.sendsToV2(clip(1), rec3, SINCE), true)
api3:exportBook("doc1", "On Agency", { { clip(1) } }, rec3, SINCE)
check("not retried in Reader", #log3, 1)

print("\n== other errors retry next sync ==")
local api4, log4 = fakeApi{ status = function() return "network" end }
local rec4 = {}
local r4 = api4:exportBook("doc1", "On Agency", { { clip(1) } }, rec4, SINCE)
check("reported as failure", #r4.failures, 1)
check("failure names its book", r4.failures[1].book, "On Agency")
check("no record kept", rec4[H.annotationKey(clip(1))], nil)
check("held back from v2 until placed", RH.sendsToV2(clip(1), rec4, SINCE), false)
api4:exportBook("doc1", "On Agency", { { clip(1) } }, rec4, SINCE)
check("retried on the next sync", #log4, 2)

print("\n== deleted in Reader ==")
local api5, log5 = fakeApi{ status = function(method) return method == "PATCH" and 404 or nil end }
local rec5 = {}
api5:exportBook("doc1", "On Agency", { { clip(1) } }, rec5, SINCE)
api5:exportBook("doc1", "On Agency", { { clip(1, { note = "n" }) } }, rec5, SINCE)
check("404 marks gone", rec5[H.annotationKey(clip(1))].gone, true)
api5:exportBook("doc1", "On Agency", { { clip(1, { note = "other" }) } }, rec5, SINCE)
check("gone highlight left alone", #log5, 2)
check("gone highlight not sent to v2", RH.sendsToV2(clip(1), rec5, SINCE), false)

print("\n== HTML-significant characters ==")
local api6, log6 = fakeApi()
api6:exportBook("doc1", "T", { { clip(1, { text = "Q&A <b>" }) } }, {}, SINCE)
check("escaped for Reader's HTML match", log6[1].body.content, "Q&amp;A &lt;b&gt;")

print("\n== v2 exporter honours include ==")
local v2log = {}
local v2 = H:new{ request = function(_, _, body)
    for _, h in ipairs(body.highlights) do table.insert(v2log, h) end
    return { { modified_highlights = {} } }
end }
v2:export({ {
    booknotes = { { clip(1), clip(2, { time = SINCE - 1 }) } },
    context = {
        title = "T",
        include = function(c) return RH.sendsToV2(c, records, SINCE) end,
    },
} })
check("only the v2-owned highlight sent", #v2log, 1)
check("it keeps its original order", v2log[1].location, 2)

if failures > 0 then
    print(string.format("\n%d FAILED", failures))
    os.exit(1)
end
print("\nALL PASS")
