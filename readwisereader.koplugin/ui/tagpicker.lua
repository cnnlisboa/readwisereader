-- Full-screen tag picker shared by Reader documents and Readwise highlights.
-- Every known tag is a row; tap toggles it. "+ New tag" adds names that do not
-- exist yet. Nothing is sent from here: Save hands the chosen list back to the
-- caller, which decides how (and whether to queue) the change.
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local TagPicker = {}

local function sortedUnion(...)
    local seen, names = {}, {}
    for index = 1, select("#", ...) do
        for _, name in ipairs(select(index, ...) or {}) do
            if type(name) == "string" and name ~= "" and not seen[name:lower()] then
                seen[name:lower()] = true
                table.insert(names, name)
            end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- options: title, all_tags (names), selected (names), parse (text -> names),
-- on_save(names). Returns the menu widget.
function TagPicker.show(options)
    local chosen = {}
    for _, name in ipairs(options.selected or {}) do
        chosen[name:lower()] = name
    end
    local known = sortedUnion(options.all_tags, options.selected)
    local menu

    local function chosenList()
        local names = {}
        for _, name in ipairs(known) do
            if chosen[name:lower()] then table.insert(names, name) end
        end
        return names
    end

    local items
    local function rebuild(focus_index)
        items = {}
        table.insert(items, {
            text = string.format("Save (%d selected)", #chosenList()),
            bold = true,
            callback = function()
                local names = chosenList()
                UIManager:close(menu)
                options.on_save(names)
            end,
        })
        table.insert(items, {
            text = "+ New tag…",
            callback = function()
                local dialog
                dialog = InputDialog:new{
                    title = "New tag (comma-separated for several)",
                    input_hint = "tag name",
                    buttons = {{
                        { text = "Cancel", callback = function() UIManager:close(dialog) end },
                        {
                            text = "Add",
                            is_enter_default = true,
                            callback = function()
                                local names = options.parse(dialog:getInputText())
                                UIManager:close(dialog)
                                if #names == 0 then return end
                                for _, name in ipairs(names) do
                                    chosen[name:lower()] = chosen[name:lower()] or name
                                end
                                known = sortedUnion(known, names)
                                rebuild(1)
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
                if dialog.onShowKeyboard then dialog:onShowKeyboard() end
            end,
        })
        for index, name in ipairs(known) do
            local row_name = name
            table.insert(items, {
                text = (chosen[row_name:lower()] and "[x] " or "[ ] ") .. row_name,
                callback = function()
                    if chosen[row_name:lower()] then
                        chosen[row_name:lower()] = nil
                    else
                        chosen[row_name:lower()] = row_name
                    end
                    -- +2 for the Save and New tag rows above the tag list.
                    rebuild(index + 2)
                end,
            })
        end
        if menu then
            menu:switchItemTable(options.title, items, focus_index)
        end
    end

    rebuild()
    menu = Menu:new{
        title = options.title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
    return menu
end

return TagPicker
