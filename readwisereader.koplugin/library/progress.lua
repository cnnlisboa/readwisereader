-- Reading-progress reconciliation policy, both directions.
--
-- Reader exposes reading_progress (0-1) on LIST and accepts it on UPDATE, so
-- the furthest position wins: decide() moves the device forward to Reader,
-- decidePush() moves Reader forward to the device. Neither ever moves a side
-- backwards, so the two cannot keep overwriting each other. Reader does not
-- store a position for PDFs, so those stay Reader-to-device only.
-- The mapping is approximate. Reader measures progress over its own rendering
-- while KOReader paginates the regenerated HTML this plugin writes, so the two
-- agree on "fraction of the document" and on nothing finer.
--
-- This module is deliberately pure: no KOReader requires, no filesystem, no
-- transport. Sidecar reads and writes stay in main.lua where DocSettings is
-- already loaded, matching the paths.lua/covers.lua split.
local Progress = {}

-- Ignore a remote reading position this small; Reader records a fraction of a
-- percent as soon as a document is opened at all.
local MIN_PROGRESS = 0.01
-- Reader must be ahead by more than this before the device is moved, otherwise
-- normal rounding differences between the two renderings cause a seed on every
-- single sync.
local DEAD_BAND = 0.02

-- Seconds to add to os.time() of a broken-down time that actually denotes UTC.
-- Measured at the target instant so a date inside a DST period is handled with
-- that period's offset rather than today's.
local function utcOffsetAt(naive)
    local utc = os.date("!*t", naive)
    if type(utc) ~= "table" then
        return 0
    end
    utc.isdst = false
    local utc_epoch = os.time(utc)
    if type(utc_epoch) ~= "number" then
        return 0
    end
    return os.difftime(naive, utc_epoch)
end

-- Parse the ISO 8601 timestamps Reader returns (last_opened_at, saved_at, ...)
-- into epoch seconds. Reader is not contractually stable about fractional
-- seconds or whether the zone is written as "Z" or "+00:00", and these values
-- are compared against filesystem mtimes, so parse rather than compare strings.
function Progress.toEpoch(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end

    local year, month, day, hour, minute, second =
        value:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)")
    if not year then
        return nil
    end

    local naive = os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second),
        isdst = false,
    })
    if type(naive) ~= "number" then
        return nil
    end

    local epoch = naive + utcOffsetAt(naive)

    -- Trailing zone: "Z"/absent means UTC; "+HH:MM" or "-HH:MM" shifts it.
    local sign, offset_hour, offset_minute =
        value:match("([%+%-])(%d%d):?(%d%d)%s*$")
    if sign then
        local offset = tonumber(offset_hour) * 3600 + tonumber(offset_minute) * 60
        if sign == "-" then
            offset = -offset
        end
        epoch = epoch - offset
    end

    return epoch
end

-- Decide whether the device should be moved to Reader's position.
--
-- remote: { reading_progress = <0-1>, last_opened_at = <iso string|nil> }
-- state:  { seen_last_opened_at = <iso string|nil>,  -- from the previous check
--           local_percent       = <0-1|nil>,         -- sidecar percent_finished
--           sidecar_mtime       = <epoch|nil> }      -- when the device last read
--
-- Returns a seed table, or nil plus a reason string suitable for logging.
function Progress.decide(remote, state)
    if type(remote) ~= "table" then
        return nil, "no remote document"
    end
    state = type(state) == "table" and state or {}

    local progress = tonumber(remote.reading_progress)
    if progress == nil then
        return nil, "no remote progress"
    end
    if progress <= MIN_PROGRESS then
        return nil, "remote progress is negligible"
    end
    if progress >= 1 then
        -- Finished in Reader. The completion path owns this document, not us.
        return nil, "remote document is finished"
    end

    local remote_opened = Progress.toEpoch(remote.last_opened_at)
    if remote_opened == nil then
        return nil, "never opened in Reader"
    end

    -- Only act on a document that was actually opened in Reader since the last
    -- time we looked, so a stale position is not replayed on every sync.
    local seen_opened = Progress.toEpoch(state.seen_last_opened_at)
    if seen_opened and remote_opened <= seen_opened then
        return nil, "no new Reader activity"
    end

    local local_percent = tonumber(state.local_percent)
    if local_percent and progress <= local_percent + DEAD_BAND then
        return nil, "within the dead band"
    end

    -- The device wins a tie: if this file was read on the device more recently
    -- than it was opened in Reader, the local position is the better one.
    local sidecar_mtime = tonumber(state.sidecar_mtime)
    if sidecar_mtime and sidecar_mtime >= remote_opened then
        return nil, "device read more recently"
    end

    return {
        percent = progress,
        last_opened_at = remote.last_opened_at,
    }
end

-- Decide whether Reader should be moved to the device's position.
--
-- local_percent: the device's percent_finished (0-1).
-- state: { remote_percent = <0-1|nil>,  -- Reader's position, fresh when known
--          pushed_percent = <0-1|nil>,  -- what this device last sent
--          finished       = <bool|nil>, -- marked finished in KOReader
--          category       = <string|nil> } -- Reader category, when known
--
-- A document marked finished (or at the very end) is sent as 1, so Reader
-- shows it as read too. Archiving it stays a separate step.
--
-- Call it once without remote_percent to skip the network when nothing has
-- moved since the last push, then again with Reader's fresh position.
-- Returns the percent to send, or nil plus a reason suitable for logging.
function Progress.decidePush(local_percent, state)
    state = type(state) == "table" and state or {}
    if state.category == "pdf" then
        return nil, "Reader keeps no position for PDFs"
    end

    local percent = tonumber(local_percent)
    if state.finished then
        percent = 1
    end
    if percent == nil or percent < 0 or percent > 1 then
        return nil, "no local progress"
    end
    if percent <= MIN_PROGRESS then
        return nil, "local progress is negligible"
    end

    local pushed = tonumber(state.pushed_percent)
    if pushed and math.abs(percent - pushed) <= DEAD_BAND then
        return nil, "already sent"
    end

    local remote = tonumber(state.remote_percent)
    if remote and percent <= remote + DEAD_BAND then
        return nil, "Reader is not behind"
    end

    return percent
end

-- Decide whether a document Reader reports as finished (reading_progress 1)
-- should be marked finished on the device, so KOReader shows it as read and
-- the finished-articles archive action picks it up.
--
-- remote: { reading_progress, last_opened_at }
-- state:  { local_finished = <bool>,        -- already finished here
--           marked_finished = <bool>,       -- this was already done once
--           sidecar_mtime = <epoch|nil> }   -- when the device last read
--
-- Done once per document, so un-finishing it on the device sticks. The device
-- wins a tie, as in decide(): reading here after Reader's last open means the
-- local state is the fresher one. Returns true, or false plus a reason.
function Progress.shouldMarkFinished(remote, state)
    if type(remote) ~= "table" then
        return false, "no remote document"
    end
    state = type(state) == "table" and state or {}
    local progress = tonumber(remote.reading_progress)
    if progress == nil or progress < 1 then
        return false, "not finished in Reader"
    end
    if state.local_finished then
        return false, "already finished here"
    end
    if state.marked_finished then
        return false, "already marked once"
    end
    local remote_opened = Progress.toEpoch(remote.last_opened_at)
    local sidecar_mtime = tonumber(state.sidecar_mtime)
    if remote_opened and sidecar_mtime and sidecar_mtime >= remote_opened then
        return false, "device read more recently"
    end
    return true
end

Progress.MIN_PROGRESS = MIN_PROGRESS
Progress.DEAD_BAND = DEAD_BAND

return Progress
