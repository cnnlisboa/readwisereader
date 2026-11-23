-- Drives main.lua's real download pipeline (downloadDocument and the EPUB /
-- HTML decisions behind it) with KOReader stubbed out. Every module the plugin
-- requires from KOReader resolves to an inert stub; the HTTP layer is a fake
-- that serves the responses each scenario needs. Files are written to a
-- throwaway directory.
local plugin = os.getenv("PLUGIN_PATH") or "readwisereader.koplugin"
package.path = plugin .. "/?.lua;" .. package.path

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-56s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-56s %s", name, tostring(got)))
    end
end

-- ---------------------------------------------------------------- stubs ---
-- Indexable and callable to any depth, so module-level code such as
-- `InputContainer:extend{}` or `Device:hasEinkScreen()` loads harmlessly.
local inert
inert = function()
    return setmetatable({}, {
        __index = function() return inert() end,
        __call = function() return inert() end,
    })
end

local fake_http = { handler = nil, requests = {} }
local overrides = {
    ["socket.http"] = {
        request = function(request)
            table.insert(fake_http.requests, request.url)
            local code, headers, body = fake_http.handler(request.url)
            if body then request.sink(body) end
            request.sink(nil)
            return 1, code, headers or { ["content-length"] = body and tostring(#body) or nil }, "status"
        end,
    },
    ["socket"] = { skip = function(n, ...) return select(n + 1, ...) end, sleep = function() end },
    ["socketutil"] = { set_timeout = function() end, reset_timeout = function() end },
    ["ui/widget/container/widgetcontainer"] = {
        extend = function(_, class) return setmetatable(class, { __index = {} }) end,
    },
    ["libs/libkoreader-lfs"] = {
        attributes = function(path, field)
            local handle = io.popen('test -d "' .. path .. '" && echo directory || (test -f "' .. path
                .. '" && echo file)')
            local mode = handle:read("*l")
            handle:close()
            if not mode then return nil end
            local size
            if mode == "file" then
                local file = io.open(path, "rb")
                size = file:seek("end")
                file:close()
            end
            local attributes = { mode = mode, modification = os.time(), size = size }
            if field then return attributes[field] end
            return attributes
        end,
        dir = function(path)
            local handle = io.popen('ls -a "' .. path .. '"')
            local entries = {}
            for line in handle:lines() do table.insert(entries, line) end
            handle:close()
            local i = 0
            return function() i = i + 1 return entries[i] end
        end,
    },
    ["util"] = {
        getSafeFilename = function(name) return name end,
        splitFilePathName = function(path) return path:match("^(.*/)([^/]*)$") end,
        makePath = function() end,
    },
    ["apps/filemanager/filemanager"] = {
        deleteFile = function(_, path) return os.remove(path) ~= nil end,
    },
    ["ffi/util"] = { template = function(s) return s end },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
}
table.insert(package.loaders, function(name)
    return function() return overrides[name] or inert() end
end)
-- Real plugin modules first, KOReader stubs for everything else.
for name, module in pairs(overrides) do package.loaded[name] = module end

local ReadwiseReader = require("main")
local Epub = require("library/epub")

-- ----------------------------------------------------------- fixtures ---
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256)
end
local function zip(entries)
    local parts, central, offset = {}, {}, 0
    for _, entry in ipairs(entries) do
        local name, data = entry[1], entry[2]
        local header = "PK\3\4" .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0)
            .. le32(0) .. le32(#data) .. le32(#data) .. le16(#name) .. le16(0) .. name
        table.insert(parts, header .. data)
        table.insert(central, "PK\1\2" .. string.rep("\0", 24) .. le16(#name) .. string.rep("\0", 8)
            .. le32(0) .. le32(offset) .. name)
        offset = offset + #header + #data
    end
    local cd = table.concat(central)
    return table.concat(parts) .. cd .. "PK\5\6" .. le16(0) .. le16(0) .. le16(#entries)
        .. le16(#entries) .. le32(#cd) .. le32(offset) .. le16(0)
end
local EPUB_BYTES = zip({ { "mimetype", "application/epub+zip" }, { "META-INF/container.xml", "<container/>" } })

local root = os.tmpname()
os.remove(root)
os.execute('mkdir -p "' .. root .. '"')
local directory = root .. "/"

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() return true end
    return false
end
local function listDir()
    local handle = io.popen('ls -a "' .. root .. '"')
    local names = {}
    for line in handle:lines() do
        if line ~= "." and line ~= ".." then table.insert(names, line) end
    end
    handle:close()
    table.sort(names)
    return table.concat(names, " | ")
end
local function clearDir()
    os.execute('rm -rf "' .. root .. '"/* "' .. root .. '"/.[!.]*')
end

local LINK = "https://readwise-assets.s3.amazonaws.com/raw/book.epub?X-Amz-Signature=s"
local FRESH_LINK = "https://readwise-assets.s3.amazonaws.com/raw/book.epub?X-Amz-Signature=fresh"

-- A plugin instance with the I/O that needs KOReader replaced.
local function newPlugin(api)
    local self = setmetatable({}, { __index = ReadwiseReader })
    self.download_original_epubs = true
    self.epub_downloads = {}
    self.pending_progress_seeds = {}
    self.progress_state = {}
    self.sync_reading_progress = false
    self.download_covers = true
    self.document_cover_urls = {}
    self.excluded_tags, self.excluded_locations = {}, {}
    self.finished = {}
    self.covers_applied = 0
    self.reader_api = api
    self.getDocumentDirectory = function() return directory end
    self.getAllDocumentDirectories = function() return { directory } end
    self.shouldSkipDocument = function() return false end
    self.storeAuthorMetadata = function() end
    self.storeSourceUrlMetadata = function() end
    self.storeReaderMetadata = function() end
    self.processHtmlContent = function(_, content) return content end
    self.setDocumentMetadata = function(_, filepath) table.insert(self.finished, filepath) end
    self.updateDocumentCollections = function() end
    self.removeFromAllCollections = function() end
    self.saveCollections = function() end
    self.initCollectionTracking = function() self.modified_collections = {} end
    self.saveSettings = function() end
    self.isDocumentOpen = function() return false end
    self.hasLocalHighlights = function() return false end
    self.readLocalProgressState = function() return nil, nil, false end
    return self
end

-- Fake Reader API. links: list of results for getRawSourceUrl, in order.
local function newApi(options)
    local api = { link_calls = 0, html_calls = 0 }
    function api.getRawSourceUrl(_, _id)
        api.link_calls = api.link_calls + 1
        local result = options.links and options.links[api.link_calls] or options.links_default
        if type(result) == "string" then return result end
        return nil, result and result.err, result and result.status
    end
    function api.getDocument(_, id, with_html)
        api.html_calls = api.html_calls + 1
        if options.html_error then return nil, options.html_error end
        return { id = id, html_content = with_html and (options.html or "<p>Book text</p>") or nil }
    end
    return api
end

local function book(id)
    return { id = id or "book1", title = "A Book", category = "epub", author = "Author" }
end
local EPUB_NAME = "A Book [rw-book1].epub"
local HTML_NAME = "A Book [rw-book1].html"
-- Files downloaded before the title-first names stay recognised.
local OLD_HTML_NAME = "[rw-id_book1] A Book.html"

local function serve(map)
    fake_http.requests = {}
    fake_http.handler = function(url)
        local entry = map[url]
        if not entry then return 404, nil, "missing" end
        return entry[1], nil, entry[2]
    end
end

-- --------------------------------------------------------- scenarios ---
print("== Original EPUB downloads ==")
clearDir()
serve({ [LINK] = { 200, EPUB_BYTES } })
local api = newApi({ links = { LINK } })
local rr = newPlugin(api)
local status = rr:downloadDocument(book(), { already_checked = true })
check("book downloads", status, "downloaded")
check("as an EPUB, nothing else", listDir(), EPUB_NAME)
check("saved file is a valid EPUB", Epub.validate(directory .. EPUB_NAME), true)
check("one link request", api.link_calls, 1)
check("no HTML fetched", api.html_calls, 0)
check("metadata written for the EPUB", rr.finished[1], directory .. EPUB_NAME)
check("no attempt bookkeeping left", rr.epub_downloads.book1, nil)
check("found by id", rr:findLocalDocumentByReadwiseId("book1"), directory .. EPUB_NAME)

print("\n== Reader has no original: HTML fallback ==")
clearDir()
api = newApi({ links = { { err = "no_raw_source" } } })
rr = newPlugin(api)
status = rr:downloadDocument(book(), { already_checked = true })
check("still downloads", status, "downloaded")
check("as HTML", listDir(), HTML_NAME)
check("marked unavailable", rr.epub_downloads.book1 and rr.epub_downloads.book1.unavailable, true)
os.remove(directory .. HTML_NAME)
api.link_calls = 0
rr:downloadDocument(book(), { already_checked = true })
check("unavailable is remembered (no second link request)", api.link_calls, 0)

print("\n== Transient failures retry, then fall back ==")
clearDir()
api = newApi({ links_default = { err = "network_error" } })
rr = newPlugin(api)
check("1st network failure: retry later", rr:downloadDocument(book(), { already_checked = true }), "failed")
check("nothing written", listDir(), "")
check("attempt counted", rr.epub_downloads.book1.attempts, 1)
check("2nd network failure: retry later", rr:downloadDocument(book(), { already_checked = true }), "failed")
check("3rd failure falls back to HTML", rr:downloadDocument(book(), { already_checked = true }), "downloaded")
check("HTML copy written", listDir(), HTML_NAME)

clearDir()
serve({ [LINK] = { 200, EPUB_BYTES:sub(1, 40) } })
api = newApi({ links_default = LINK })
rr = newPlugin(api)
check("corrupt file falls back to HTML at once", rr:downloadDocument(book(), { already_checked = true }), "downloaded")
check("no partial EPUB left", listDir(), HTML_NAME)

clearDir()
serve({ [LINK] = { 503, "busy" } })
rr = newPlugin(newApi({ links_default = LINK }))
check("S3 503 is retried later", rr:downloadDocument(book(), { already_checked = true }), "failed")
check("S3 503 leaves nothing", listDir(), "")

print("\n== Expired link is refreshed once ==")
clearDir()
serve({ [LINK] = { 403, "<Error>Request has expired</Error>" }, [FRESH_LINK] = { 200, EPUB_BYTES } })
api = newApi({ links = { FRESH_LINK } })
rr = newPlugin(api)
local stale = book()
stale.raw_source_url = LINK
check("download succeeds with a fresh link", rr:downloadDocument(stale, { already_checked = true }), "downloaded")
check("asked Reader for a new link", api.link_calls, 1)
check("tried stale then fresh", table.concat(fake_http.requests, ","), LINK .. "," .. FRESH_LINK)
check("EPUB saved", listDir(), EPUB_NAME)

clearDir()
serve({ [LINK] = { 403, "denied" } })
api = newApi({ links = { LINK } })
rr = newPlugin(api)
check("a just-fetched link is not re-fetched on 403", rr:downloadDocument(book(), { already_checked = true }), "failed")
check("only one link request", api.link_calls, 1)

print("\n== Settings and categories ==")
clearDir()
api = newApi({ links = { LINK } })
rr = newPlugin(api)
rr.download_original_epubs = false
check("setting off: HTML", rr:downloadDocument(book(), { already_checked = true }), "downloaded")
check("setting off: no link request", api.link_calls, 0)
check("setting off: HTML file", listDir(), HTML_NAME)

clearDir()
api = newApi({ links = { LINK } })
rr = newPlugin(api)
local article = { id = "art1", title = "Article", category = "article" }
check("articles stay HTML", rr:downloadDocument(article, { already_checked = true }), "downloaded")
check("articles never request a link", api.link_calls, 0)
check("article covers still applied", listDir():find("%.html") ~= nil, true)

clearDir()
rr = newPlugin(newApi({ html_error = "network_error" }))
check("HTML fetch failure retries later", rr:downloadDocument(article, { already_checked = true }), "failed")
check("no stub page written on a network failure", listDir(), "")

clearDir()
rr = newPlugin(newApi({ html = nil, html_error = "not_found" }))
check("missing content writes the summary page", rr:downloadDocument(article, { already_checked = true }), "downloaded")

print("\n== Replacing an unopened HTML copy ==")
clearDir()
local html_path = directory .. OLD_HTML_NAME
local f = io.open(html_path, "w"); f:write("<p>old</p>"); f:close()
serve({ [LINK] = { 200, EPUB_BYTES } })
api = newApi({ links = { LINK } })
rr = newPlugin(api)
check("HTML copy is replaceable", rr:canReplaceHtmlWithEpub(book(), html_path), true)
check("replacement downloads", rr:downloadDocument(book(), { already_checked = true, replace_path = html_path }),
    "downloaded")
check("only the EPUB remains", listDir(), EPUB_NAME)

clearDir()
f = io.open(html_path, "w"); f:write("<p>old</p>"); f:close()
rr = newPlugin(newApi({ links = { { err = "no_raw_source" } } }))
check("no original: HTML copy kept", rr:downloadDocument(book(), { already_checked = true, replace_path = html_path }),
    "kept")
check("HTML untouched, no duplicate", listDir(), OLD_HTML_NAME)
check("not offered again", rr:canReplaceHtmlWithEpub(book(), html_path), false)

rr = newPlugin(newApi({ links_default = { err = "network_error" } }))
check("offline: HTML copy kept", rr:downloadDocument(book(), { already_checked = true, replace_path = html_path }),
    "kept")
check("offline: still only HTML", listDir(), OLD_HTML_NAME)

rr = newPlugin(newApi({}))
check("an EPUB is never replaced", rr:canReplaceHtmlWithEpub(book(), directory .. EPUB_NAME), false)
check("an article is never replaced", rr:canReplaceHtmlWithEpub(article, html_path), false)
rr.readLocalProgressState = function() return 0.25, 0, false end
check("a started book is kept", rr:canReplaceHtmlWithEpub(book(), html_path), false)
rr.pending_progress_seeds.book1 = 0.25
check("a Reader-seeded, unread book is replaceable", rr:canReplaceHtmlWithEpub(book(), html_path), true)
rr.readLocalProgressState = function() return nil, nil, true end
check("a finished book is kept", rr:canReplaceHtmlWithEpub(book(), html_path), false)
rr.readLocalProgressState = function() return nil, nil, false end
rr.hasLocalHighlights = function() return true end
check("a book with highlights is kept", rr:canReplaceHtmlWithEpub(book(), html_path), false)
rr.hasLocalHighlights = function() return false end
rr.isDocumentOpen = function() return true end
check("the open book is kept", rr:canReplaceHtmlWithEpub(book(), html_path), false)
rr.isDocumentOpen = function() return false end
rr.download_original_epubs = false
check("setting off: nothing replaced", rr:canReplaceHtmlWithEpub(book(), html_path), false)

print("\n== A sideloaded copy of the same book ==")
clearDir()
local sideloaded = directory .. "Claude Hopkins - A Book.epub"
f = io.open(sideloaded, "wb"); f:write(EPUB_BYTES); f:close()
serve({ [LINK] = { 200, EPUB_BYTES } })
rr = newPlugin(newApi({ links = { LINK } }))
rr.local_book_links = {}
rr.getLocalBookLink = function(self_, path) return self_.local_book_links[path] end
rr.linkLocalBookToReader = function(self_, path, document)
    self_.local_book_links[path] = { id = document.id, title = document.title }
    return self_.local_book_links[path]
end
check("identical book is linked, not duplicated", rr:downloadDocument(book(), { already_checked = true }), "linked")
check("only the user's file remains", listDir(), "Claude Hopkins - A Book.epub")
check("the user's file is linked to Reader", rr.local_book_links[sideloaded] and rr.local_book_links[sideloaded].id, "book1")
check("linked book counts as on this device", rr:getLinkedReaderIds().book1, true)

clearDir()
f = io.open(sideloaded, "wb"); f:write(EPUB_BYTES:sub(1, -2) .. "X"); f:close()
rr.local_book_links = {}
rr.reader_api = newApi({ links = { LINK } })
check("same size, different bytes: downloaded", rr:downloadDocument(book(), { already_checked = true }), "downloaded")
check("both files kept", listDir(), EPUB_NAME .. " | Claude Hopkins - A Book.epub")
check("nothing linked", next(rr.local_book_links), nil)

clearDir()
f = io.open(sideloaded, "wb"); f:write(EPUB_BYTES); f:close()
rr.local_book_links = { [sideloaded] = { id = "other-doc", title = "Other" } }
rr.reader_api = newApi({ links = { LINK } })
check("a book linked elsewhere is left alone", rr:downloadDocument(book(), { already_checked = true }), "downloaded")
check("its link is unchanged", rr.local_book_links[sideloaded].id, "other-doc")

print("\n== Both filename formats ==")
check("title-first name", rr:getDocumentIdFromPath("/x/A Book [rw-01jp1vwpn36ya6dgwpdqahmzg8].epub"),
    "01jp1vwpn36ya6dgwpdqahmzg8")
check("old prefix name", rr:getDocumentIdFromPath("/x/[rw-id_01kz5] Some [rw-ish] Article.html"), "01kz5")
check("brackets in a plain title", rr:getDocumentIdFromPath("/x/Notes [draft].epub"), nil)
check("partial download", rr:getDocumentIdFromPath("/x/.A Book [rw-b1].epub.part"), nil)
check("ownsReadingPosition off without progress sync", rr:ownsReadingPosition("/x/A Book [rw-b1].epub"), false)
rr.sync_reading_progress = true
check("ownsReadingPosition for a Reader file", rr:ownsReadingPosition("/x/A Book [rw-b1].epub"), true)
rr.sync_reading_progress = false

print("\n== Local lookup with both copies ==")
clearDir()
f = io.open(html_path, "w"); f:write("x"); f:close()
f = io.open(directory .. EPUB_NAME, "wb"); f:write(EPUB_BYTES); f:close()
f = io.open(directory .. ".B [rw-book2].epub.part", "wb"); f:write("partial"); f:close()
rr = newPlugin(newApi({}))
local paths = rr:getLocalDocumentPaths()
check("EPUB represents the document", paths.book1, directory .. EPUB_NAME)
check("partial downloads are invisible", paths.book2, nil)
check("lookup by id prefers the EPUB", rr:findLocalDocumentByReadwiseId("book1"), directory .. EPUB_NAME)

os.execute('rm -rf "' .. root .. '"')
print(failures == 0 and "\nAll EPUB download tests passed."
    or string.format("\n%d EPUB download test(s) failed.", failures))
os.exit(failures == 0 and 0 or 1)
