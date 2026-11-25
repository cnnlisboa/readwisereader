-- Pure decisions for Readwise Books sync: matching Reader documents to Books
-- entries, mapping KOReader statuses to Books shelves, and what to do when a
-- book is opened, changed on the device, or changed in Readwise. No I/O here;
-- main.lua reads sidecars, calls the API and applies what these return.
--
-- Policy (PLAN-readwise-books.md 2.3 and 3.3, decided 2026-11-23):
--   * Obsidian is the source of truth. The device only fills empty values in
--     Books (start/finish dates, rating) and moves the shelf.
--   * `finished` in Books is sticky: nothing on the device moves a finished
--     book back except a confirmed re-read (planOpen -> "reread_prompt").
--   * A Books change is applied to the device only when it differs from the
--     shelf this device last saw, so the first sync after install records a
--     baseline instead of acting on old shelves (no mass deletes).
local BooksMap = {}

local Progress = require("library/progress")

-- Common Latin accents folded to ASCII so "Ética" matches "Etica".
local ACCENTS = {
    ["à"]="a",["á"]="a",["â"]="a",["ã"]="a",["ä"]="a",["å"]="a",
    ["ç"]="c",["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",
    ["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",["ñ"]="n",
    ["ò"]="o",["ó"]="o",["ô"]="o",["õ"]="o",["ö"]="o",
    ["ù"]="u",["ú"]="u",["û"]="u",["ü"]="u",["ý"]="y",["ÿ"]="y",
    ["À"]="a",["Á"]="a",["Â"]="a",["Ã"]="a",["Ä"]="a",["Ç"]="c",
    ["È"]="e",["É"]="e",["Ê"]="e",["Í"]="i",["Ñ"]="n",["Ó"]="o",
    ["Ô"]="o",["Õ"]="o",["Ö"]="o",["Ú"]="u",["Ü"]="u",
}

local function fold(text)
    text = tostring(text or "")
    text = text:gsub("[\195][\128-\191]", function(ch) return ACCENTS[ch] or ch end)
    return text:lower()
end

local function squash(text)
    return (text:gsub("[^%w]", ""))
end

-- Leading articles in the languages of this library (English, Portuguese,
-- Spanish, French, Italian), so "O Príncipe" matches "Príncipe".
local ARTICLES = { "the", "an", "a", "o", "os", "as", "um", "uma", "el", "la", "los", "las",
    "le", "les", "l'", "il", "lo" }

local function stripArticle(text)
    for _, article in ipairs(ARTICLES) do
        local rest = text:match("^%s*" .. article:gsub("'", "%%'") .. "%s+(.+)$")
        if rest then return rest end
    end
    return text
end

-- Title keys from strictest to loosest: full title, without subtitle (after
-- ":" or " - "), and each of those without a leading English article.
function BooksMap.titleKeys(title)
    local folded = fold(title)
    local main = folded:match("^(.-)%s*[:]") or folded:match("^(.-)%s+%-%s+") or folded
    local keys, seen = {}, {}
    for _, variant in ipairs({ folded, main, stripArticle(folded), stripArticle(main) }) do
        local key = squash(variant)
        if key ~= "" and not seen[key] then
            seen[key] = true
            table.insert(keys, key)
        end
    end
    return keys
end

function BooksMap.authorKey(author)
    local key = squash(fold(author))
    return key ~= "" and key or nil
end

local function authorTokens(author)
    local tokens = {}
    for word in fold(author):gmatch("[%w]+") do
        if #word >= 3 then tokens[word] = true end
    end
    return tokens
end

-- Compatible when either is missing or they share a name of 3+ letters, so
-- "Claude Hopkins" ~ "Claude C. Hopkins" and "Kennedy, Dan" ~ "Dan S. Kennedy".
local function authorsCompatible(a, b)
    local ta, tb = authorTokens(a), authorTokens(b)
    if next(ta) == nil or next(tb) == nil then return true end
    for word in pairs(ta) do
        if tb[word] then return true end
    end
    return false
end

-- Matches Reader documents ({id, title, author, saved_at}) to Books entries
-- ({id, title, author, created, status}). Deleted Books entries are ignored.
-- A document matching several books is narrowed by `created` within 120 s of
-- `saved_at`; a tie that can't be broken is left unmatched, never guessed.
-- Returns { [doc_id] = book_id }, { unmatched doc ids }.
local function savedNear(doc, book)
    local saved = Progress.toEpoch(doc.saved_at)
    local created = Progress.toEpoch(book.created)
    return saved ~= nil and created ~= nil and math.abs(saved - created) <= 120
end

local function sameProgress(doc, book)
    local a, b = tonumber(doc.reading_progress), tonumber(book.progress)
    return a ~= nil and b ~= nil and a > 0 and math.abs(a - b) < 1e-6
end

local function narrow(candidates, predicate, doc)
    local kept = {}
    for _, book in ipairs(candidates) do
        if predicate(doc, book) then table.insert(kept, book) end
    end
    return kept
end

function BooksMap.matchBooks(documents, books)
    local by_key = {}
    for _, book in ipairs(books or {}) do
        if book.status ~= "deleted" then
            for _, key in ipairs(BooksMap.titleKeys(book.title)) do
                by_key[key] = by_key[key] or {}
                table.insert(by_key[key], book)
            end
        end
    end
    -- Oldest saves first, so of two Reader copies of one book the original
    -- gets the Books entry.
    local ordered = {}
    for _, doc in ipairs(documents or {}) do table.insert(ordered, doc) end
    table.sort(ordered, function(x, y)
        return (Progress.toEpoch(x.saved_at) or math.huge) < (Progress.toEpoch(y.saved_at) or math.huge)
    end)
    local matches, unmatched, used = {}, {}, {}
    for _, doc in ipairs(ordered) do
        local found
        for _, key in ipairs(BooksMap.titleKeys(doc.title)) do
            local candidates = {}
            for _, book in ipairs(by_key[key] or {}) do
                if not used[book.id] and (authorsCompatible(doc.author, book.author) or savedNear(doc, book)) then
                    table.insert(candidates, book)
                end
            end
            if #candidates > 1 then
                local near = narrow(candidates, savedNear, doc)
                if #near ~= 1 then
                    near = narrow(#near > 1 and near or candidates, sameProgress, doc)
                end
                candidates = near
            end
            if #candidates == 1 then
                found = candidates[1]
                break
            elseif #candidates > 1 then
                break -- ambiguous: don't fall through to looser keys
            end
        end
        if found then
            matches[doc.id] = found.id
            used[found.id] = true
        else
            table.insert(unmatched, doc.id)
        end
    end
    return matches, unmatched
end

function BooksMap.isoNow(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t or os.time())
end

-- KOReader status (+ To Be Read membership) -> Books shelf, or nil.
function BooksMap.shelfForLocal(status, in_tbr)
    if status == "reading" then return "currently_reading" end
    if status == "complete" then return "finished" end
    if status == "abandoned" then return "did_not_finish" end
    if (status == nil or status == "new") and in_tbr then return "want_to_read" end
    return nil
end

local SHELF_RANK = { unsorted = 0, want_to_read = 1, currently_reading = 2, did_not_finish = 3, finished = 4 }

-- Book opened on the device. Returns
--   { prompt = "reread" }                     Books says finished: ask first
--   { patch = {...} }                         move to currently_reading / date
--   nil                                       nothing to do
function BooksMap.planOpen(book, now)
    if type(book) ~= "table" then return nil end
    if book.status == "finished" then
        return { prompt = "reread" }
    end
    local patch = { id = book.id }
    if book.status ~= "currently_reading" then
        patch.status = "currently_reading"
    end
    if not book.started_reading_at then
        patch.started_reading_at = BooksMap.isoNow(now)
    end
    if patch.status or patch.started_reading_at then
        return { patch = patch }
    end
    return nil
end

-- A confirmed re-read: back to currently_reading. Dates stay (first start and
-- first finish are kept, decided 2026-11-23).
function BooksMap.planReread(book)
    return { patch = { id = book.id, status = "currently_reading" } }
end

-- Device-side change since the last sync. `now_local` = { status, in_tbr,
-- rating } read from the sidecar; `state` = what this device last saw.
-- Returns a PATCH item or nil, plus a reason for the log.
function BooksMap.planLocalChange(book, now_local, state, now)
    if type(book) ~= "table" then return nil, "no book" end
    state = state or {}
    local patch = { id = book.id }

    -- First time this device looks at the book: the shelf is still sent, but
    -- no dates, since "now" isn't when the book was started or finished.
    local first_sight = state.local_status == nil and state.remote_status == nil
    local status_changed = now_local.status ~= state.local_status
        or (now_local.in_tbr and true or false) ~= (state.in_tbr and true or false)
    if status_changed then
        local target = BooksMap.shelfForLocal(now_local.status, now_local.in_tbr)
        if target and target ~= book.status then
            -- Finished is sticky (a re-read goes through planOpen's prompt),
            -- and To Be Read never pulls a started book back.
            local sticky = book.status == "finished"
            local pulls_back = target == "want_to_read"
                and (SHELF_RANK[book.status] or 0) > SHELF_RANK.want_to_read
            if not sticky and not pulls_back then
                patch.status = target
            end
        end
        local shelf = patch.status or book.status
        if not first_sight and (target == "finished" or shelf == "finished") and not book.finished_reading_at
            and now_local.status == "complete" then
            patch.finished_reading_at = BooksMap.isoNow(now)
        end
        if not first_sight and target == "currently_reading" and shelf == "currently_reading"
            and not book.started_reading_at then
            patch.started_reading_at = BooksMap.isoNow(now)
        end
    end

    local rating = tonumber(now_local.rating)
    if rating and rating > 0 and rating ~= tonumber(state.local_rating) and book.rating == nil then
        patch.rating = rating
    end

    if next(patch, nil) == "id" and next(patch, "id") == nil then
        return nil, "no change"
    end
    return patch
end

-- Books-side change since the last sync. Returns a table of device actions:
--   { status = "complete"|"abandoned", add_tbr = true, rating = n }
-- or nil and a reason. `options.tbr` (add want_to_read books to To Be Read)
-- and `options.apply_status` gate the actions.
function BooksMap.planRemoteChange(book, now_local, state, options)
    if type(book) ~= "table" then return nil, "no book" end
    state = state or {}
    options = options or {}
    if state.remote_status == nil then
        return nil, "baseline"
    end
    local actions = {}
    if book.status ~= state.remote_status and options.apply_status ~= false then
        if book.status == "finished" and now_local.status ~= "complete" then
            actions.status = "complete"
        elseif book.status == "did_not_finish" and now_local.status ~= "abandoned" then
            actions.status = "abandoned"
        elseif book.status == "want_to_read" and options.tbr
            and (now_local.status == nil or now_local.status == "new") and not now_local.in_tbr then
            actions.add_tbr = true
        end
    end
    local remote_rating = tonumber(book.rating)
    if remote_rating and not tonumber(now_local.rating) then
        local stars = math.floor(remote_rating + 0.5)
        if stars < 1 then stars = 1 end
        if stars > 5 then stars = 5 end
        actions.rating = stars
    end
    if next(actions) == nil then
        return nil, "no change"
    end
    return actions
end

return BooksMap
