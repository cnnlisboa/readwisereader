package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local TagFilter = require("library/tag_filter")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-50s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-50s %s", name, tostring(got)))
    end
end

local listed = { id = "1", category = "article", tags = { k1 = { name = "Work" }, k2 = { name = "later-maybe" } } }

print("== tag names ==")
check("type comes first", TagFilter.names(listed)[1], "article")
check("LIST tag objects are read", #TagFilter.names(listed), 3)
check("plain name lists are read", #TagFilter.names({ tags = { "a", "b" } }), 2)
check("empty names are ignored", #TagFilter.names({ tags = { "", { name = "" } } }), 0)
check("nil document", #TagFilter.names(nil), 0)

print("\n== exclusions ==")
check("nothing excluded", TagFilter.excludedBy(listed, {}), nil)
check("excluded tag matches", TagFilter.excludedBy(listed, { "Work" }), "Work")
check("matching ignores case", TagFilter.excludedBy(listed, { "work" }), "work")
check("excluded type matches", TagFilter.excludedBy(listed, { "Article" }), "Article")
check("other tags don't match", TagFilter.excludedBy(listed, { "email", "home" }), nil)
-- The bug this replaces: the document's own (new) tags must win over the
-- tags saved at the previous sync.
check("fresh tags beat saved ones",
    TagFilter.excludedBy(listed, { "Work" }, { "article" }), "Work")
check("saved tags don't re-exclude a retagged document",
    TagFilter.excludedBy({ id = "2", tags = { k = { name = "home" } } }, { "work" }, { "work" }), nil)
check("saved tags are used when the document has no tag field",
    TagFilter.excludedBy({ id = "3" }, { "work" }, { "Work" }), "work")

print(failures == 0 and "\nALL PASS" or string.format("\n%d FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
