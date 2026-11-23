-- Sends a local EPUB to the presigned URL Readwise Books hands out (POST
-- /uploads -> PUT file -> POST /uploads/complete). PLAN D.8.
local EpubUpload = {}

EpubUpload.MAX_BYTES = 500 * 1024 * 1024

local function defaultRequest(request)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
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

-- A file name Readwise accepts: ends in .epub, at most 255 characters.
function EpubUpload.fileName(filepath)
    local name = tostring(filepath):match("([^/]+)$") or "book.epub"
    if not name:lower():match("%.epub$") then
        name = name .. ".epub"
    end
    if #name > 255 then
        name = name:sub(1, 250) .. ".epub"
    end
    return name
end

-- KOReader status -> shelf the upload lands on.
function EpubUpload.shelfFor(status)
    if status == "reading" then return "currently_reading" end
    if status == "complete" then return "finished" end
    if status == "abandoned" then return "did_not_finish" end
    return "want_to_read"
end

-- PUTs `filepath` (`size` bytes) with exactly the headers Readwise returned.
-- Returns true or nil, reason, http_code.
function EpubUpload.put(url, headers, filepath, size, request)
    local ltn12 = require("ltn12")
    local file = io.open(filepath, "rb")
    if not file then
        return nil, "could not read file"
    end
    local request_headers = {}
    for key, value in pairs(headers or {}) do
        request_headers[key] = tostring(value)
    end
    request_headers["Content-Length"] = request_headers["Content-Length"] or tostring(size)
    local sink = {}
    local code, _, status = (request or defaultRequest)({
        url = url,
        method = "PUT",
        headers = request_headers,
        source = ltn12.source.file(file),
        sink = ltn12.sink.table(sink),
    })
    if code == nil then
        return nil, "network error: " .. tostring(status)
    end
    if code ~= 200 and code ~= 201 and code ~= 204 then
        return nil, "HTTP " .. tostring(code), code
    end
    return true
end

return EpubUpload
