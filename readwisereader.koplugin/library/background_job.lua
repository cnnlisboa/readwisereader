-- Runs one long network task (the highlight export) a step at a time, so
-- KOReader stays usable while it works.
--
-- KOReader runs plugins on one thread and LuaSocket blocks, so a request
-- still holds the screen for as long as it takes. The task runs in a
-- coroutine that hands control back after every request, and waits (rate
-- limits, Retry-After) become timers instead of sleeps.
--
-- Module state is shared by every plugin instance: the reader's and the file
-- browser's instances come and go as books open and close, and the task
-- outlives the one that started it.
--
-- The scheduler is injected (UIManager on device, a fake in tests).
local Job = {
    co = nil,
    paused = false,
    name = nil,
}

local scheduler, log

function Job.setup(options)
    scheduler = options.scheduler
    log = options.logger
end

function Job.running()
    return Job.co ~= nil
end

-- Whether the caller is the task itself.
function Job.inside()
    return Job.co ~= nil and coroutine.running() == Job.co
end

local function finish(ok, err)
    local done = Job.on_done
    Job.co, Job.on_done, Job.name, Job.paused = nil, nil, nil, false
    if not ok and log then log.warn("ReadwiseReader: background task failed:", err) end
    if done then
        local cb_ok, cb_err = pcall(done, ok, err)
        if not cb_ok and log then log.warn("ReadwiseReader: background task callback failed:", cb_err) end
    end
end

function Job.step()
    if not Job.co or Job.paused then return end
    local ok, delay = coroutine.resume(Job.co)
    if not ok then
        finish(false, delay)
    elseif coroutine.status(Job.co) == "dead" then
        finish(true)
    else
        Job.schedule(tonumber(delay) or 0)
    end
end

function Job.schedule(delay)
    scheduler.unschedule(Job.step)
    if delay > 0 then
        scheduler.scheduleIn(delay, Job.step)
    else
        scheduler.nextTick(Job.step)
    end
end

-- Starts fn as the task. on_done(ok, err) runs when it ends. Returns false
-- when a task is already running.
function Job.start(name, fn, on_done)
    if Job.co then return false end
    Job.co = coroutine.create(fn)
    Job.name = name
    Job.on_done = on_done
    Job.paused = false
    Job.schedule(0)
    return true
end

-- Inside the task: give KOReader a turn, after `seconds` (default: at once).
-- Outside it: sleep, which is what callers did before.
function Job.wait(seconds, sleep)
    seconds = tonumber(seconds) or 0
    if Job.inside() then
        coroutine.yield(seconds)
    elseif seconds > 0 and sleep then
        sleep(seconds)
    end
end

-- Device going to sleep: stop between steps. A request already in flight
-- has finished by now (the task only stops at a yield).
function Job.pause()
    if not Job.co then return end
    Job.paused = true
    scheduler.unschedule(Job.step)
end

-- Woken up: carry on once `ready()` (network up) or after `max_wait` s.
function Job.resume(ready, max_wait)
    if not Job.co or not Job.paused then return end
    Job.paused = false
    local waited = 0
    local function check()
        if not Job.co or Job.paused then return end
        if not ready or ready() or waited >= (max_wait or 30) then
            Job.schedule(0)
        else
            waited = waited + 2
            scheduler.unschedule(check)
            scheduler.scheduleIn(2, check)
        end
    end
    check()
end

return Job
