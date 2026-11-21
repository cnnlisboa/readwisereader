-- Original EPUB downloads for Reader documents in the "epub" category.
--
-- Reader's LIST endpoint returns `raw_source_url` when asked with
-- `withRawSourceUrl=true`: a presigned S3 link to the file that was uploaded,
-- valid for one hour and empty for documents Reader cannot distribute. This
-- module streams that link to disk and only keeps the result if it is a
-- complete EPUB, so a truncated transfer, an S3 error page or an unexpected
-- file never replaces the HTML fallback with something KOReader cannot open.
--
-- The HTTP call is injectable (options.request) so the whole path can be
-- tested without KOReader or a network. The default transport is loaded
-- lazily for the same reason.
local Epub = {}

-- A book is far larger than an article, but a runaway response should still
-- not fill the device. Big illustrated EPUBs are rarely past 100 MB.
Epub.MAX_BYTES = 300 * 1024 * 1024

local ZIP_LOCAL_HEADER = "PK\3\4"
local ZIP_END_OF_CENTRAL_DIRECTORY = "PK\5\6"
local EPUB_MIMETYPE = "application/epub+zip"
local CONTAINER_PATH = "META-INF/container.xml"
-- End of central directory record: 22 bytes plus a comment of up to 64 KiB.
local EOCD_SEARCH_BYTES = 22 + 65535
local MAX_CENTRAL_DIRECTORY_BYTES = 16 * 1024 * 1024

local function le16(data, offset)
    local a, b = data:byte(offset, offset + 1)
    return a + b * 256
end

local function le32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- Reads a whole file region; nil when the file cannot be read.
local function readRegion(file, offset, length)
    if not file:seek("set", offset) then
        return nil
    end
    return file:read(length)
end

-- Whether `path` is a complete EPUB. Checks the ZIP local header, that the
-- end-of-central-directory record is present (a truncated download has none),
-- and that the archive is an EPUB: either the spec's uncompressed `mimetype`
-- first entry naming application/epub+zip, or a META-INF/container.xml entry
-- in the central directory for the many real-world EPUBs that get the first
-- rule wrong. Returns true, or nil and a reason.
function Epub.validate(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, "unreadable"
    end
    local ok, err = (function()
        local size = file:seek("end")
        if not size or size < 22 + 30 then
            return nil, "too small"
        end
        local head = readRegion(file, 0, 128)
        if not head or head:sub(1, 4) ~= ZIP_LOCAL_HEADER then
            return nil, "not a zip archive"
        end

        local tail_length = math.min(size, EOCD_SEARCH_BYTES)
        local tail = readRegion(file, size - tail_length, tail_length)
        if not tail then
            return nil, "unreadable"
        end
        -- The record is near the very end, so the last complete match wins
        -- over a stray signature inside an entry's data.
        local eocd
        local position = 1
        while true do
            local found = tail:find(ZIP_END_OF_CENTRAL_DIRECTORY, position, true)
            if not found or found + 21 > #tail then
                break
            end
            eocd = found
            position = found + 1
        end
        if not eocd then
            return nil, "incomplete archive"
        end

        -- Spec-conformant EPUB: first entry is the stored "mimetype" file.
        -- Local header: name length at 27, extra length at 29, name at 31.
        local name_length = le16(head, 27)
        local extra_length = le16(head, 29)
        if head:sub(31, 30 + name_length) == "mimetype" then
            local content_start = 31 + name_length + extra_length
            if head:sub(content_start, content_start + #EPUB_MIMETYPE - 1) == EPUB_MIMETYPE then
                return true
            end
        end

        -- Otherwise look for the container entry in the central directory.
        local cd_size = le32(tail, eocd + 12)
        local cd_offset = le32(tail, eocd + 16)
        local central
        if cd_offset ~= 0xFFFFFFFF and cd_size ~= 0xFFFFFFFF
            and cd_size <= MAX_CENTRAL_DIRECTORY_BYTES and cd_offset + cd_size <= size then
            central = readRegion(file, cd_offset, cd_size)
        end
        -- ZIP64 or an inconsistent record: the tail still holds the end of
        -- the central directory, which is where small archives keep it all.
        central = central or tail
        if central:find(CONTAINER_PATH, 1, true) then
            return true
        end
        return nil, "not an epub"
    end)()
    file:close()
    return ok, err
end

-- Only Reader's own presigned links are fetched: HTTPS, never a file:// or a
-- plain-HTTP URL that a malformed response could smuggle in.
function Epub.isDownloadableUrl(url)
    return type(url) == "string" and url:match("^https://[%w%.%-]+[/:?]") ~= nil
end

-- The host only, for logs: the query string of a presigned link is a
-- credential for as long as it is valid.
function Epub.describeUrl(url)
    return type(url) == "string" and (url:match("^https://([^/?#]+)") or "?") or "?"
end

local function contentLength(headers)
    local value = headers and headers["content-length"]
    return tonumber(value)
end

-- Expired presigned links answer 403 (sometimes 400); asking Reader for a
-- fresh link is the fix, not giving up on the original file.
function Epub.isExpiredLinkStatus(code)
    return code == 400 or code == 403
end

local function defaultRequest(request)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    -- A whole book over Kindle Wi-Fi: generous per-block and total limits.
    socketutil:set_timeout(30, 15 * 60)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()
    if not ok then
        return nil, nil, tostring(code)
    end
    return code, headers, status
end

-- Streams `url` to `destination`. The data goes to a hidden temporary file in
-- the same directory first and is renamed into place only once it validates,
-- so the destination either holds a complete EPUB or does not exist.
--
-- options.request(request_table) -> code, headers, status  (transport)
-- options.on_bytes(count)        progress callback for each chunk received
-- options.max_bytes              size cap (default Epub.MAX_BYTES)
--
-- Returns true, or nil, reason, http_code.
function Epub.download(url, destination, options)
    options = options or {}
    if not Epub.isDownloadableUrl(url) then
        return nil, "unsupported url"
    end
    if type(destination) ~= "string" or destination == "" then
        return nil, "no destination"
    end

    local directory, name = destination:match("^(.*/)([^/]+)$")
    if not directory then
        directory, name = "", destination
    end
    local temporary = directory .. "." .. name .. ".part"
    os.remove(temporary)

    local file, open_err = io.open(temporary, "wb")
    if not file then
        return nil, "could not write: " .. tostring(open_err)
    end

    local max_bytes = options.max_bytes or Epub.MAX_BYTES
    local received = 0
    local write_failed, too_large = false, false
    local closed = false
    local function closeFile()
        if not closed then
            closed = true
            file:close()
        end
    end
    local function sink(chunk, sink_err)
        if chunk == nil then
            closeFile()
            return 1
        end
        received = received + #chunk
        if received > max_bytes then
            too_large = true
            return nil, "file exceeds size limit"
        end
        if not file:write(chunk) then
            write_failed = true
            return nil, "write failed"
        end
        if options.on_bytes then
            pcall(options.on_bytes, #chunk)
        end
        return 1
    end

    local code, headers, status = (options.request or defaultRequest)({
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader Readwise Reader Plugin",
            ["Accept"] = "application/epub+zip,application/octet-stream;q=0.9,*/*;q=0.1",
        },
        redirect = true,
        sink = sink,
    })
    closeFile()

    local function fail(reason, http_code)
        os.remove(temporary)
        return nil, reason, http_code
    end

    if too_large then
        return fail("file exceeds size limit")
    end
    if write_failed then
        return fail("write failed (device full?)")
    end
    if code == nil or headers == nil then
        return fail("network error: " .. tostring(status or code))
    end
    if code ~= 200 then
        return fail("HTTP " .. tostring(code), code)
    end
    if received == 0 then
        return fail("empty response")
    end
    local expected = contentLength(headers)
    if expected and expected ~= received then
        return fail(string.format("incomplete transfer (%d of %d bytes)", received, expected))
    end

    local valid, invalid_reason = Epub.validate(temporary)
    if not valid then
        return fail("invalid epub: " .. tostring(invalid_reason))
    end

    os.remove(destination)
    local renamed, rename_err = os.rename(temporary, destination)
    if not renamed then
        return fail("could not move into place: " .. tostring(rename_err))
    end
    return true, received
end

-- Whether two files have identical contents, compared in chunks so a large
-- book never has to fit in memory.
function Epub.sameContents(path_a, path_b)
    local a = io.open(path_a, "rb")
    if not a then return false end
    local b = io.open(path_b, "rb")
    if not b then a:close() return false end
    local same = a:seek("end") == b:seek("end")
    if same then
        a:seek("set", 0)
        b:seek("set", 0)
        while true do
            local chunk_a, chunk_b = a:read(65536), b:read(65536)
            if chunk_a ~= chunk_b then
                same = false
                break
            end
            if chunk_a == nil then
                break
            end
        end
    end
    a:close()
    b:close()
    return same
end

-- Failures that a later sync can fix by trying again, as opposed to a file
-- that will never be a usable EPUB (where the HTML copy is the right answer).
function Epub.isRetryable(reason)
    if type(reason) ~= "string" then
        return false
    end
    return reason:find("^network error") ~= nil
        or reason:find("^HTTP 5") ~= nil
        or reason:find("^HTTP 429") ~= nil
        or reason:find("^HTTP 40[03]") ~= nil
        or reason:find("^incomplete transfer") ~= nil
        or reason:find("^write failed") ~= nil
        or reason:find("^could not") ~= nil
        or reason == "empty response"
end

return Epub
