package.path = (os.getenv("PLUGIN_PATH") or "readwisereader.koplugin") .. "/?.lua;" .. package.path
local Epub = require("library/epub")
local Paths = require("library/paths")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-52s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-52s %s", name, tostring(got)))
    end
end

-- Minimal ZIP writer: stored entries, real local headers, central directory
-- and end record. CRCs are zero; validation does not read them.
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256)
end
local function zip(entries, options)
    options = options or {}
    local parts, central, offset = {}, {}, 0
    for _, entry in ipairs(entries) do
        local name, data = entry[1], entry[2]
        local header = "PK\3\4" .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0)
            .. le32(0) .. le32(#data) .. le32(#data) .. le16(#name) .. le16(0) .. name
        table.insert(parts, header .. data)
        table.insert(central, "PK\1\2" .. le16(20) .. le16(20) .. le16(0) .. le16(0) .. le16(0)
            .. le16(0) .. le32(0) .. le32(#data) .. le32(#data) .. le16(#name) .. le16(0) .. le16(0)
            .. le16(0) .. le16(0) .. le32(0) .. le32(offset) .. name)
        offset = offset + #header + #data
    end
    local cd = table.concat(central)
    local comment = options.comment or ""
    local eocd = "PK\5\6" .. le16(0) .. le16(0) .. le16(#entries) .. le16(#entries)
        .. le32(#cd) .. le32(offset) .. le16(#comment) .. comment
    return table.concat(parts) .. cd .. eocd
end

local CONTAINER = [[<?xml version="1.0"?><container version="1.0"
 xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
 <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
 </rootfiles></container>]]
local SPEC_EPUB = zip({
    { "mimetype", "application/epub+zip" },
    { "META-INF/container.xml", CONTAINER },
    { "OEBPS/content.opf", "<package/>" },
})
local LOOSE_EPUB = zip({
    { "OEBPS/content.opf", "<package/>" },
    { "META-INF/container.xml", CONTAINER },
})
local PLAIN_ZIP = zip({ { "readme.txt", string.rep("hello ", 40) } })

local temporary = {}
local function tempPath(suffix)
    local path = os.tmpname() .. (suffix or "")
    table.insert(temporary, path)
    return path
end
local function writeFile(data)
    local path = tempPath(".bin")
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
    return path
end
local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() return true end
    return false
end

print("== EPUB validation ==")
check("spec EPUB (mimetype first) is valid", Epub.validate(writeFile(SPEC_EPUB)), true)
check("EPUB without leading mimetype is valid", Epub.validate(writeFile(LOOSE_EPUB)), true)
check("EPUB with archive comment is valid",
    Epub.validate(writeFile(zip({ { "META-INF/container.xml", CONTAINER } }, { comment = "PK\5\6 fake" }))), true)
local _, reason = Epub.validate(writeFile(PLAIN_ZIP))
check("plain zip is not an epub", reason, "not an epub")
_, reason = Epub.validate(writeFile(SPEC_EPUB:sub(1, #SPEC_EPUB - 30)))
check("truncated download is incomplete", reason, "incomplete archive")
_, reason = Epub.validate(writeFile("<html><body>AccessDenied</body></html>" .. string.rep(" ", 80)))
check("S3 error page is not a zip", reason, "not a zip archive")
_, reason = Epub.validate(writeFile("PK\3\4"))
check("tiny file is too small", reason, "too small")
_, reason = Epub.validate(tempPath(".missing"))
check("missing file is unreadable", reason, "unreadable")

print("\n== Link handling ==")
check("presigned https link is accepted",
    Epub.isDownloadableUrl("https://readwise-assets.s3.amazonaws.com/x.epub?X-Amz-Signature=abc"), true)
check("http link is refused", Epub.isDownloadableUrl("http://example.com/x.epub"), false)
check("file link is refused", Epub.isDownloadableUrl("file:///etc/passwd"), false)
check("non-string is refused", Epub.isDownloadableUrl(nil), false)
check("logs show the host only",
    Epub.describeUrl("https://bucket.s3.amazonaws.com/key.epub?X-Amz-Signature=secret"), "bucket.s3.amazonaws.com")
check("403 means an expired link", Epub.isExpiredLinkStatus(403), true)
check("404 is not an expired link", Epub.isExpiredLinkStatus(404), false)

print("\n== Download ==")
-- Fake transport: feeds `body` to the sink in chunks like LuaSocket does.
local function transport(code, body, headers)
    return function(request)
        if body then
            local chunk_size = 7
            for i = 1, #body, chunk_size do
                local ok, err = request.sink(body:sub(i, i + chunk_size - 1))
                if not ok then
                    request.sink(nil, err)
                    return nil, nil, err
                end
            end
        end
        request.sink(nil)
        return code, headers or { ["content-length"] = body and tostring(#body) or "0" }, "status"
    end
end

local URL = "https://readwise-assets.s3.amazonaws.com/book.epub?sig=1"
local destination = tempPath(".epub")
local reported = 0
local seen_request
local ok, size = Epub.download(URL, destination, {
    request = function(request)
        seen_request = request
        return transport(200, SPEC_EPUB)(request)
    end,
    on_bytes = function(count) reported = reported + count end,
})
check("valid EPUB downloads", ok, true)
check("returns bytes received", size, #SPEC_EPUB)
check("progress sees every byte", reported, #SPEC_EPUB)
check("file is in place", exists(destination), true)
check("temporary file is gone", exists(destination:gsub("([^/]+)$", ".%1.part")), false)
check("no Readwise token is sent to S3", seen_request.headers.Authorization, nil)
check("redirects are followed", seen_request.redirect, true)

local http_dest = tempPath(".epub")
local http_code
ok, reason, http_code = Epub.download(URL, http_dest, { request = transport(403, "<Error>AccessDenied</Error>") })
check("HTTP 403 fails", ok, nil)
check("HTTP 403 reason", reason, "HTTP 403")
check("HTTP 403 code is returned", http_code, 403)
check("HTTP 403 leaves no file", exists(http_dest), false)
check("HTTP 403 is retryable (fresh link)", Epub.isRetryable(reason), true)

local short_dest = tempPath(".epub")
ok, reason = Epub.download(URL, short_dest, {
    request = transport(200, SPEC_EPUB, { ["content-length"] = tostring(#SPEC_EPUB + 100) }),
})
check("short transfer fails", ok, nil)
check("short transfer is retryable", Epub.isRetryable(reason), true)
check("short transfer leaves no file", exists(short_dest), false)

local invalid_dest = tempPath(".epub")
ok, reason = Epub.download(URL, invalid_dest, { request = transport(200, PLAIN_ZIP) })
check("non-EPUB download fails", ok, nil)
check("non-EPUB reason", reason, "invalid epub: not an epub")
check("non-EPUB is not retryable (use HTML)", Epub.isRetryable(reason), false)
check("non-EPUB leaves no file", exists(invalid_dest), false)

local big_dest = tempPath(".epub")
ok, reason = Epub.download(URL, big_dest, { request = transport(200, SPEC_EPUB), max_bytes = 100 })
check("oversized download fails", reason, "file exceeds size limit")
check("oversized is not retryable", Epub.isRetryable(reason), false)
check("oversized leaves no file", exists(big_dest), false)

local net_dest = tempPath(".epub")
ok, reason = Epub.download(URL, net_dest, { request = function() return nil, nil, "timeout" end })
check("network failure fails", ok, nil)
check("network failure is retryable", Epub.isRetryable(reason), true)

ok, reason = Epub.download("http://insecure/book.epub", tempPath(".epub"), { request = transport(200, SPEC_EPUB) })
check("insecure link is never fetched", reason, "unsupported url")

-- Replacing an existing file (an earlier, interrupted copy) works.
local again = tempPath(".epub")
writeFile("stale")
local stale = assert(io.open(again, "wb")); stale:write("stale"); stale:close()
ok = Epub.download(URL, again, { request = transport(200, LOOSE_EPUB) })
check("overwrites an existing destination", ok, true)
check("overwritten file is valid", Epub.validate(again), true)

print("\n== Local document files ==")
check("html is a document file", Paths.isDocumentFile("[rw-id_1] A.html"), true)
check("epub is a document file", Paths.isDocumentFile("[rw-id_1] A.epub"), true)
check("upper-case EPUB is a document file", Paths.isDocumentFile("[rw-id_1] A.EPUB"), true)
check("partial download is not a document", Paths.isDocumentFile(".[rw-id_1] A.epub.part"), false)
check("pdf is not a document file", Paths.isDocumentFile("[rw-id_1] A.pdf"), false)
check("EPUB beats HTML for one id", Paths.preferredDocumentPath("/a/x.html", "/a/x.epub"), "/a/x.epub")
check("EPUB is kept over a later HTML", Paths.preferredDocumentPath("/a/x.epub", "/a/x.html"), "/a/x.epub")
check("first path wins otherwise", Paths.preferredDocumentPath(nil, "/a/x.html"), "/a/x.html")

for _, path in ipairs(temporary) do
    os.remove(path)
    os.remove((path:gsub("([^/]+)$", ".%1.part")))
end

print(failures == 0 and "\nAll EPUB tests passed." or string.format("\n%d EPUB test(s) failed.", failures))
os.exit(failures == 0 and 0 or 1)
