package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Note = require("library/reader_note")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-50s got=%q want=%q", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-50s", name))
    end
end

local function resolve(base, remote, edited)
    local r = Note.resolve(base, remote, edited)
    return r.action, r.text or r.merged
end

print("== appending ==")
check("append to empty", Note.append("", "new"), "new")
check("append adds a blank line", Note.append("old", "new"), "old\n\nnew")
check("append trims whitespace at the joint", Note.append("old\n\n", "\n new\n"), "old\n\nnew")
check("append nothing keeps the note", Note.append("old", "  "), "old")
check("append to nil", Note.append(nil, "new"), "new")

print("\n== saving an edit ==")
check("no change", (resolve("a", "a", "a")), "none")
check("edited back to Reader's text", (resolve("a", "b", "b")), "none")
check("Reader unchanged: send the edit", select(2, resolve("a", "a", "a b")), "a b")
check("Reader unchanged: action is send", (resolve("a", "a", "a b")), "send")
check("clearing the note is sent", select(2, resolve("a", "a", "")), "")
check("Reader changed: conflict", (resolve("a", "a+web", "a mine")), "conflict")

print("\n== merging when Reader changed ==")
check("only appended: just the addition goes on the end",
    select(2, resolve("Start", "Start\nweb line", "Start\nmy line")), "Start\nweb line\n\nmy line")
check("rewritten: the whole edit goes under the separator",
    select(2, resolve("Start", "Start\nweb line", "Rewritten")),
    "Start\nweb line\n\n" .. Note.SEPARATOR .. "\nRewritten")
check("empty base: the edit is appended",
    select(2, resolve("", "web", "mine")), "web\n\nmine")
check("a cleared note adds nothing to Reader's", Note.merge("Start", "Start+web", ""), "Start+web")
check("Reader emptied meanwhile: the edit is kept",
    select(2, resolve("Start", "", "Rewritten")), "Rewritten")

print("\n== unknown starting note (offline, no saved copy) ==")
check("Reader empty: sent as is", select(2, resolve(nil, "", "mine\n")), "mine")
check("Reader empty: action is send", (resolve(nil, "", "mine")), "send")
check("Reader has a note: added to the end",
    select(2, resolve(nil, "web", "mine")), "web\n\n" .. Note.SEPARATOR .. "\nmine")
check("nothing typed", (resolve(nil, "web", "web")), "none")
check("empty edit never clears Reader's note", (resolve(nil, "web", "  \n")), "none")

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
