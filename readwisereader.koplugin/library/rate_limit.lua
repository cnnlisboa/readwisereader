-- Per-endpoint request budgets, so a call waits only when its own limit is
-- actually close.
--
-- The old limiter switched on after any five quick calls and then slept 3 s
-- before every request, whichever API it was for. Placing 12 highlights in
-- Reader took 75 s on a Boox that way (2026-11-25), most of it sleeping.
--
-- Readwise's documented limits, per minute: Reader 20 in general and 50 for
-- creating and updating documents; v2 240 in general and 20 for listing. The
-- budgets below stay a little under them. A 429 is still handled by callAPI,
-- since other devices share the same account limits.
--
-- Module state is shared by every plugin instance, which is right: the limit
-- belongs to the account, not to whichever screen is open.
local RateLimit = {}

local WINDOW = 60

RateLimit.BUDGETS = {
    reader_write = 45,
    reader_read = 18,
    v2_write = 200,
    v2_read = 18,
    other = 50,
}

local calls = {}

local function clock()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then return socket.gettime() end
    return os.time()
end
RateLimit.clock = clock

function RateLimit.bucket(method, url)
    local write = method ~= nil and method ~= "GET"
    if type(url) ~= "string" then return "other" end
    if url:find("/api/v3", 1, true) then
        return write and "reader_write" or "reader_read"
    end
    if url:find("/api/v2", 1, true) then
        return write and "v2_write" or "v2_read"
    end
    return "other"
end

local function prune(list, now)
    local first = 1
    while list[first] and list[first] <= now - WINDOW do first = first + 1 end
    if first > 1 then
        local kept = {}
        for index = first, #list do kept[#kept + 1] = list[index] end
        return kept
    end
    return list
end

-- Seconds to wait before a call in `bucket` may go out (0: now).
function RateLimit.delay(bucket, now)
    now = now or RateLimit.clock()
    local list = prune(calls[bucket] or {}, now)
    calls[bucket] = list
    local budget = RateLimit.BUDGETS[bucket] or RateLimit.BUDGETS.other
    if #list < budget then return 0 end
    return math.max(0, list[#list - budget + 1] + WINDOW - now)
end

function RateLimit.record(bucket, now)
    now = now or RateLimit.clock()
    local list = calls[bucket] or {}
    list[#list + 1] = now
    calls[bucket] = list
end

-- After a 429: treat the bucket as full for `seconds`.
function RateLimit.block(bucket, seconds, now)
    now = now or RateLimit.clock()
    local budget = RateLimit.BUDGETS[bucket] or RateLimit.BUDGETS.other
    local list = {}
    for _ = 1, budget do list[#list + 1] = now + seconds - WINDOW end
    calls[bucket] = list
end

function RateLimit.reset()
    calls = {}
end

return RateLimit
