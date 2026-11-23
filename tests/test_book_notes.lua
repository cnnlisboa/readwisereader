-- The Writer Deck book note kept the same as the Reader document note.
package.path = "readwisereader.koplugin/?.lua;" .. package.path

local BookNotes = require("book_notes")

local failures = 0
local function check(name, got, want)
    local ok = got == want
    if not ok then
        failures = failures + 1
        print(string.format("FAIL %-50s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-50s %s", name, tostring(got)))
    end
end

print("== strip ==")
check("separators removed", BookNotes.strip("First thought\n\n— exported 2026-11-20 10:00\n\nSecond\n"),
    "First thought\n\nSecond")
check("blank lines tidied", BookNotes.strip("\n\nA\n\n\n\nB\n\n"), "A\n\nB")

print("== decide ==")
check("same", BookNotes.decide("A", "A\n", "x").action, "same")
check("changed here", BookNotes.decide("A2", "A", "A").action, "push")
check("changed in Reader", BookNotes.decide("A", "A2", "A").text, "A2")
local both = BookNotes.decide("mine", "theirs", "base")
check("both changed: conflict", both.action, "conflict")
check("both kept", both.text, "mine\n\n" .. BookNotes.CONFLICT_LINE .. "\n\ntheirs")
check("first sync, Reader empty: push", BookNotes.decide("mine", nil, nil).action, "push")
check("first sync, note empty: pull", BookNotes.decide("", "theirs", nil).action, "pull")
check("first sync, both differ: conflict", BookNotes.decide("a", "b", nil).action, "conflict")

print("== file format ==")
local json = {
    decode = function(s) return { readwise_id = s:match('"readwise_id":"([^"]*)"'), kind = "book" } end,
    encode = function(t) return '{"kind":"book","readwise_id":"' .. t.readwise_id .. '"}' end,
}
local parsed = BookNotes.parseFile('<!-- writer-deck-meta:{"kind":"book","readwise_id":"r1"} -->\nHello\n', json.decode)
check("meta read", parsed.meta.readwise_id, "r1")
check("body read", parsed.body, "Hello\n")
check("written back", BookNotes.serialize(parsed.meta, "New\n", json.encode),
    '<!-- writer-deck-meta:{"kind":"book","readwise_id":"r1"} -->\nNew\n')
check("no meta line", BookNotes.parseFile("plain", json.decode).meta, nil)

print("== a sync pass ==")
local R = {}
BookNotes.install(R, { logger = { warn = function() end }, lfs = {}, DataStorage = {}, json = json })
local plugin = setmetatable({ saveSettings = function() end }, { __index = R })
plugin:initBookNotes({ book_notes_state = { r2 = { text = "old" } } })
local written, sent = {}, {}
plugin.listWriterDeckBookNotes = function()
    return {
        r1 = { path = "/wd/r1.md", meta = { readwise_id = "r1" }, body = "Written on the Kindle\n" },
        r2 = { path = "/wd/r2.md", meta = { readwise_id = "r2" }, body = "old\n— exported 2026-11-20 10:00\n" },
    }
end
plugin.reader_api = { getDocument = function(_, id)
    return { id = id, notes = id == "r2" and "edited in Obsidian" or nil }
end }
plugin.updateReaderDocumentNotes = function(_, id, text) sent[id] = text; return {} end
plugin.writeWriterDeckNote = function(_, note, text) written[note.meta.readwise_id] = text; return true end
local report = plugin:syncBookNotes()
check("new note sent to Reader", sent.r1, "Written on the Kindle")
check("Reader edit reaches the device", written.r2, "edited in Obsidian")
check("nothing sent back for it", sent.r2, nil)
check("counts", report.sent .. "/" .. report.received .. "/" .. report.conflicts, "1/1/0")
check("state remembered", plugin.book_notes_state.r1.text, "Written on the Kindle")

print(failures == 0 and "\nall passed" or string.format("\n%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
