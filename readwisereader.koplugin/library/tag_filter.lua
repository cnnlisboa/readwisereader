-- Which documents a sync skips because of an excluded type or tag.
--
-- Matched against the document's own type and tags as the current sync
-- received them, ignoring case. Pure: no KOReader requires.
local TagFilter = {}

-- A document's type and tag names. LIST returns tags as
-- { [key] = { name = ... } }; normalized documents carry a list of names.
function TagFilter.names(document)
    local names = {}
    if type(document) ~= "table" then
        return names
    end
    if type(document.category) == "string" and document.category ~= "" then
        table.insert(names, document.category)
    end
    if type(document.tags) == "table" then
        for _, value in pairs(document.tags) do
            local name = type(value) == "table" and value.name or value
            if type(name) == "string" and name ~= "" then
                table.insert(names, name)
            end
        end
    end
    return names
end

-- Returns the excluded tag that matches, or nil. saved_names is used only
-- when the document carries no tag field at all (e.g. a bare id lookup).
function TagFilter.excludedBy(document, excluded_tags, saved_names)
    if type(excluded_tags) ~= "table" or #excluded_tags == 0 then
        return nil
    end
    local excluded = {}
    for _, tag in ipairs(excluded_tags) do
        if type(tag) == "string" then
            excluded[tag:lower()] = tag
        end
    end
    local names = TagFilter.names(document)
    if type(document) == "table" and document.tags == nil and type(saved_names) == "table" then
        for _, name in ipairs(saved_names) do
            table.insert(names, name)
        end
    end
    for _, name in ipairs(names) do
        local match = excluded[name:lower()]
        if match then
            return match
        end
    end
    return nil
end

return TagFilter
