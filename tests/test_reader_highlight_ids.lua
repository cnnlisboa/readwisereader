-- Reader highlight ids carried on KOReader annotations between readers.
package.path = "readwisereader.koplugin/?.lua;" .. package.path

local Ids = require("library/reader_highlight_ids")

local failures = 0
local function check(name, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("%-4s %-50s %s", ok and "ok" or "FAIL", name, tostring(got)))
end

local function key_for(annotation) return annotation.datetime and (annotation.datetime .. "|" .. annotation.page) end

print("== a highlight placed here gets its id ==")
local mine = {
    { datetime = "2026-11-23 10:00:00", page = "/body/p[1]", text = "one", note = "" },
    { datetime = "2026-11-23 10:05:00", page = "/body/p[2]", text = "two" },
    { datetime = "2026-11-23 10:06:00", page = "/body/p[3]", text = "fell back" },
}
local records = {
    ["2026-11-23 10:00:00|/body/p[1]"] = { id = "r1", note = "" },
    ["2026-11-23 10:06:00|/body/p[3]"] = { fallback = true },
}
check("one stamped", Ids.stamp(mine, records, key_for), 1)
check("id on the annotation", mine[1].readwise_reader_id, "r1")
check("unplaced left alone", mine[2].readwise_reader_id, nil)
check("fallback left alone", mine[3].readwise_reader_id, nil)
check("stamping twice changes nothing", Ids.stamp(mine, records, key_for), 0)

print("== the other reader receives it and adopts it ==")
local theirs = { { datetime = "2026-11-23 10:00:00", page = "/body/p[1]", text = "one", note = "why",
    readwise_reader_id = "r1" } }
local their_records = {}
check("adopted", Ids.adopt(theirs, their_records, key_for), 1)
check("record has the Reader id", their_records["2026-11-23 10:00:00|/body/p[1]"].id, "r1")
check("note remembered as sent", their_records["2026-11-23 10:00:00|/body/p[1]"].note, "why")
check("existing record not replaced", Ids.adopt(theirs, { ["2026-11-23 10:00:00|/body/p[1]"] = { gone = true } },
    key_for), 0)

print(failures == 0 and "\nall passed" or string.format("\n%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
