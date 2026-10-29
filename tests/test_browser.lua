package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path

-- Stub the KOReader widgets browser.lua requires; these tests only exercise
-- the menu builders and their in-memory state.
local function widget()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/buttondialog"] = widget
package.preload["ui/widget/confirmbox"] = widget
package.preload["ui/widget/infomessage"] = widget
package.preload["ui/widget/inputdialog"] = widget
package.preload["ui/widget/menu"] = function()
    return {
        new = function(_, o)
            o.switchItemTable = function(self, _, items) self.item_table = items end
            return o
        end,
    }
end
package.preload["ui/trapper"] = function() return {} end
local shown = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) table.insert(shown, w) end,
        close = function() end,
    }
end

local Browser = require("ui/browser")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-46s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-46s %s", name, tostring(got)))
    end
end

local function newBrowser()
    local calls = { list = 0, view = 0 }
    local doc = { id = "doc1", title = "Doc", location = "new" }
    local browser = Browser:new{
        reader_api = {
            listMetadata = function()
                calls.list = calls.list + 1
                return { documents = { doc } }
            end,
            viewMetadata = function()
                calls.view = calls.view + 1
                return { documents = { doc }, scanned = 1 }
            end,
        },
        downloaded_ids = function() return {} end,
        download_documents = function() end,
        show_progress = function() end,
        hide_progress = function() end,
    }
    return browser, calls
end

local function findRow(items, prefix)
    for _, item in ipairs(items) do
        local text = item.text_func and item.text_func() or item.text
        if text and text:sub(1, #prefix) == prefix then return item end
    end
end

-- Launchers such as ZenOS re-run every parent builder after a row tap. That
-- must not clear the selection or refetch the list.
do
    local browser, calls = newBrowser()
    local inbox = browser:getLocationItems()[1]
    local items = inbox.sub_item_table_func()
    findRow(items, "[ ] Doc").callback(nil)
    check("location tap selects", browser:selectionCount(), 1)

    browser:getLocationItems()
    items = browser:getLocationItems()[1].sub_item_table_func()
    check("location rebuild keeps selection", browser:selectionCount(), 1)
    check("location rebuild uses cached page", calls.list, 1)
    check("location row still checked", findRow(items, "[x] Doc") ~= nil, true)

    findRow(items, "Refresh list").callback(nil)
    check("refresh list refetches", calls.list, 2)
    check("refresh list keeps selection", browser:selectionCount(), 1)
end

do
    local browser, calls = newBrowser()
    local items = browser:getViewsMenuItems()[1].sub_item_table_func()
    findRow(items, "[ ] Doc").callback(nil)
    browser:getViewsMenuItems()
    browser:getViewsMenuItems()[1].sub_item_table_func()
    check("view rebuild keeps selection", browser:selectionCount(), 1)
    check("view rebuild uses cached page", calls.view, 1)
end

-- Podcasts and audiobooks never list; videos list unless show_videos is off.
do
    local show_videos = true
    local browser = Browser:new{
        reader_api = {
            listMetadata = function()
                return { documents = {
                    { id = "a", title = "Article", category = "article" },
                    { id = "v", title = "Video", category = "video" },
                    { id = "p", title = "Podcast", category = "podcast" },
                    { id = "b", title = "Audiobook", category = "audiobook" },
                } }
            end,
        },
        downloaded_ids = function() return {} end,
        download_documents = function() end,
        show_videos = function() return show_videos end,
        show_progress = function() end,
        hide_progress = function() end,
    }
    local function rows()
        local items = browser:getLocationItems()[1].sub_item_table_func()
        return findRow(items, "[ ] Article") ~= nil, findRow(items, "[ ] Video") ~= nil,
            findRow(items, "[ ] Podcast") ~= nil, findRow(items, "[ ] Audiobook") ~= nil
    end
    local article, video, podcast, audiobook = rows()
    check("article listed", article, true)
    check("video listed by default", video, true)
    check("podcast hidden", podcast, false)
    check("audiobook hidden", audiobook, false)

    show_videos = false
    article, video = rows()
    check("video hidden when setting off", video, false)
    check("article still listed", article, true)

    browser:getLocationItems()[1].sub_item_table_func()[1].callback(nil)
    check("select all skips hidden", browser:selectionCount(), 1)
end

-- Edit tags: fetch fresh, pick, save; queue when the save cannot reach Reader.
do
    local Reader = require("api/reader")
    local function tagBrowser(overrides)
        local state = { saved = nil, queued = nil, changed = nil, fetched = 0 }
        local api = {
            parseTags = Reader.parseTags,
            diffTags = Reader.diffTags,
            isRetryable = Reader.isRetryable,
            getDocument = overrides.getDocument or function()
                state.fetched = state.fetched + 1
                return { id = "d1", tags = { "fresh", "web-added" } }
            end,
            listTags = overrides.listTags or function() return { "fresh", "web-added", "other" } end,
            updateTags = overrides.updateTags or function(_, id, tags)
                state.saved = { id = id, tags = tags }
                return tags
            end,
        }
        local browser = Browser:new{
            reader_api = api,
            downloaded_ids = function() return {} end,
            download_documents = function() end,
            known_tags = function() return { "cached-known" } end,
            queue_tag_update = function(id, add, remove) state.queued = { id = id, add = add, remove = remove } end,
            on_tags_changed = function(document, tags) state.changed = { id = document.id, tags = tags } end,
        }
        return browser, state
    end
    local function rowTexts(menu)
        local texts = {}
        for _, item in ipairs(menu.item_table) do table.insert(texts, item.text) end
        return table.concat(texts, "|")
    end
    local function tap(menu, prefix)
        for _, item in ipairs(menu.item_table) do
            if item.text:sub(1, #prefix) == prefix then return item.callback() end
        end
        error("no row " .. prefix)
    end

    -- Online: picker shows every account tag with current ones ticked.
    local doc = { id = "d1", title = "Doc", tags = { "stale" } }
    local browser, state = tagBrowser{}
    shown = {}
    browser:showDocumentInfo(doc, nil)
    local details = shown[#shown]
    check("details offer Download", details.buttons[1][1].text, "Download")
    check("details offer Edit tags", details.buttons[2][1].text, "Edit tags")
    details.buttons[2][1].callback()
    local picker = shown[#shown]
    check("fetched fresh tags first", state.fetched, 1)
    check("picker lists all tags, fresh ones ticked",
        rowTexts(picker), "Save (2 selected)|+ New tag…|[x] fresh|[ ] other|[x] web-added")
    tap(picker, "[ ] other")
    tap(picker, "[x] web-added")
    tap(picker, "Save")
    check("save sends the picked list", table.concat(state.saved.tags, "|"), "fresh|other")
    check("local sync hook told the new tags", table.concat(state.changed.tags, "|"), "fresh|other")
    check("document tags updated in memory", table.concat(doc.tags, "|"), "fresh|other")

    -- Saving without changes sends nothing.
    local noop_browser, noop_state = tagBrowser{}
    shown = {}
    noop_browser:editTags({ id = "d1", title = "Doc" }, nil)
    tap(shown[#shown], "Save")
    check("unchanged save sends nothing", noop_state.saved, nil)

    -- Offline from the start: cached tags, change queued as a diff.
    local offline_doc = { id = "d1", title = "Doc", tags = { "keep", "drop" } }
    local offline, offline_state = tagBrowser{
        getDocument = function() return nil, "network_error" end,
        listTags = function() return nil, "network_error" end,
        updateTags = function() return nil, "network_error" end,
    }
    shown = {}
    offline:editTags(offline_doc, nil)
    local offline_picker = shown[#shown]
    check("offline picker opens on cached tags", rowTexts(offline_picker),
        "Save (2 selected)|+ New tag…|[ ] cached-known|[x] drop|[x] keep")
    tap(offline_picker, "[x] drop")
    tap(offline_picker, "[ ] cached-known")
    tap(offline_picker, "Save")
    check("offline change queued for document", offline_state.queued.id, "d1")
    check("queued diff adds", table.concat(offline_state.queued.add, "|"), "cached-known")
    check("queued diff removes", table.concat(offline_state.queued.remove, "|"), "drop")
    check("document shows the pending tags", table.concat(offline_doc.tags, "|"), "cached-known|keep")

    -- A permanent failure is reported, not queued.
    local denied, denied_state = tagBrowser{
        updateTags = function() return nil, "http_error", 401 end,
    }
    shown = {}
    denied:editTags({ id = "d1", title = "Doc" }, nil)
    tap(shown[#shown], "[ ] other")
    tap(shown[#shown], "Save")
    check("auth failure is not queued", denied_state.queued, nil)

    local downloaded = Browser:new{
        reader_api = {},
        downloaded_ids = function() return { d1 = true } end,
        download_documents = function() end,
    }
    shown = {}
    downloaded:showDocumentInfo(doc, nil)
    check("downloaded details skip Download", shown[#shown].buttons[1][1].text, "Edit tags")
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all browser tests passed")
