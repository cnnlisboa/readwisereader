-- Reading sessions from KOReader's statistics (page_stat_data rows) for the
-- Readwise Books sessions API (PLAN D.5). Pure: main.lua reads the database.
--
-- A row is one page view: { page, start_time, duration, total_pages }.
-- Rows closer together than `gap` seconds belong to one session; the time
-- between them counts as paused.
local Sessions = {}

Sessions.DEFAULT_GAP = 300        -- 5 minutes
Sessions.DEFAULT_MIN_SECONDS = 120 -- shorter sessions are dropped

local function iso(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end
Sessions.iso = iso

local function clamp01(x)
    if x < 0 then return 0 end
    if x > 1 then return 1 end
    return x
end

-- rows sorted or not; returns sessions sorted by start:
-- { started = epoch, ended = epoch, paused = seconds, percent_start, percent_end, key }
function Sessions.build(rows, options)
    options = options or {}
    local gap = options.gap or Sessions.DEFAULT_GAP
    local min_seconds = options.min_seconds or Sessions.DEFAULT_MIN_SECONDS
    local list = {}
    for _, row in ipairs(rows or {}) do
        local start = tonumber(row.start_time)
        local duration = tonumber(row.duration)
        local page = tonumber(row.page)
        local total = tonumber(row.total_pages)
        if start and duration and duration > 0 and page and total and total > 0 then
            table.insert(list, { start = start, stop = start + duration, page = page, total = total })
        end
    end
    table.sort(list, function(a, b) return a.start < b.start end)

    local sessions, current = {}, nil
    local function close()
        if not current then return end
        local reading = current.ended - current.started - current.paused
        if reading >= min_seconds then
            current.percent_start = clamp01((current.min_page - 1) / current.min_total)
            current.percent_end = clamp01(current.max_page / current.max_total)
            if current.percent_end < current.percent_start then
                current.percent_end = current.percent_start
            end
            current.key = current.started .. "|" .. current.ended
            current.min_page, current.min_total, current.max_page, current.max_total = nil, nil, nil, nil
            table.insert(sessions, current)
        end
        current = nil
    end
    for _, row in ipairs(list) do
        if current and row.start - current.ended > gap then
            close()
        end
        if not current then
            current = { started = row.start, ended = row.stop, paused = 0,
                min_page = row.page, min_total = row.total, max_page = row.page, max_total = row.total }
        else
            if row.start > current.ended then
                current.paused = current.paused + (row.start - current.ended)
            end
            if row.stop > current.ended then current.ended = row.stop end
            if row.page / row.total < current.min_page / current.min_total then
                current.min_page, current.min_total = row.page, row.total
            end
            if row.page / row.total > current.max_page / current.max_total then
                current.max_page, current.max_total = row.page, row.total
            end
        end
    end
    close()
    return sessions
end

-- Sessions not sent yet: after the ledger's watermark, not in its sent keys,
-- and ended before `hold_after` (the open book's last session waits until
-- the book is closed or the device sleeps).
function Sessions.pending(sessions, ledger, hold_after)
    ledger = ledger or {}
    local sent = ledger.sent or {}
    local out = {}
    for _, session in ipairs(sessions) do
        if session.started > (ledger.watermark or 0) and not sent[session.key]
            and (not hold_after or session.ended <= hold_after) then
            table.insert(out, session)
        end
    end
    return out
end

-- API item for one session.
function Sessions.toItem(session, book_id, options)
    options = options or {}
    return {
        book_id = book_id,
        started_at = iso(session.started),
        ended_at = iso(session.ended),
        paused_seconds = math.floor(session.paused),
        format = "ebook",
        percent_at_start = session.percent_start,
        percent_at_end = session.percent_end,
        timezone = options.timezone,
        device = options.device,
        publish_to_feed = options.publish_to_feed and true or false,
    }
end

-- Records a sent session in the ledger: the watermark moves forward and only
-- recent keys are kept (older ones are behind the watermark anyway).
function Sessions.record(ledger, session)
    ledger.sent = ledger.sent or {}
    ledger.sent[session.key] = session.ended
    if session.started > (ledger.watermark or 0) then
        ledger.watermark = session.started
    end
    for key, ended in pairs(ledger.sent) do
        if ended < (ledger.watermark or 0) - 7 * 86400 then
            ledger.sent[key] = nil
        end
    end
    return ledger
end

-- Matches sessions already in Readwise (a response lost on the way back)
-- by start and end within a minute.
function Sessions.alreadyRemote(session, remote_sessions, to_epoch)
    for _, remote in ipairs(remote_sessions or {}) do
        local started, ended = to_epoch(remote.started_at), to_epoch(remote.ended_at)
        if started and ended and math.abs(started - session.started) <= 60
            and math.abs(ended - session.ended) <= 60 and not remote.is_deleted then
            return true
        end
    end
    return false
end

return Sessions
