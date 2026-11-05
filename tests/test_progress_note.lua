package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Note = require("library/progress_note")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

print("== removing the old KOReader progress note line ==")
local existing = "My own note\nSecond paragraph"
local line = "KOReader progress: 42% " .. Note.MARKER

local removed, removed_changed = Note.remove(existing .. "\n" .. line)
check("remove preserves all non-plugin text", removed, existing .. "\n")
check("remove reports a managed line", removed_changed, true)

local middle = Note.remove("before\n" .. line .. "\nafter")
check("a line in the middle leaves no blank paragraph", middle, "before\nafter")
check("a note that was only the line becomes empty", (Note.remove(line)), "")
check("remove does nothing without the marker", (Note.remove(existing)), existing)
check("remove reports no marker", select(2, Note.remove(existing)), false)
check("nil notes are treated as empty", (Note.remove(nil)), "")
check("lookalike text without the marker is kept",
    (Note.remove("KOReader progress: 10%")), "KOReader progress: 10%")

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
