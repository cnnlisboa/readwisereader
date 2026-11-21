-- Central Reader document-directory routing. Keep the legacy single directory
-- as the fallback so upgrading never moves or hides existing downloads.
local Paths = {}

local function normalize(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:gsub("/+$", "") .. "/"
end

function Paths.getArticleDirectory(settings)
    return normalize(settings.article_directory) or normalize(settings.directory)
end

function Paths.getBookDirectory(settings)
    -- Deliberately fall back to articles: an upgrade keeps every document in the
    -- old folder until the user explicitly selects a separate book directory.
    return normalize(settings.book_directory) or Paths.getArticleDirectory(settings)
end

function Paths.getDocumentDirectory(document, settings)
    if document and document.category == "epub" then
        return Paths.getBookDirectory(settings)
    end
    return Paths.getArticleDirectory(settings)
end

-- File types this plugin writes for Reader documents: generated HTML for
-- articles (and books whose original is unavailable), and original EPUBs.
local DOCUMENT_EXTENSIONS = { html = true, epub = true }

function Paths.isDocumentFile(name)
    local extension = type(name) == "string" and name:match("%.([%w]+)$")
    return extension ~= nil and DOCUMENT_EXTENSIONS[extension:lower()] == true
end

function Paths.isEpubFile(name)
    return type(name) == "string" and name:lower():match("%.epub$") ~= nil
end

-- When one Reader document has both an HTML copy and an EPUB on the device
-- (only briefly, while an HTML copy is being replaced), the EPUB is the copy
-- that represents it.
function Paths.preferredDocumentPath(current, candidate)
    if not current then
        return candidate
    end
    if Paths.isEpubFile(candidate) and not Paths.isEpubFile(current) then
        return candidate
    end
    return current
end

function Paths.getAllDocumentDirectories(settings)
    local directories, seen = {}, {}
    for _, directory in ipairs({ Paths.getArticleDirectory(settings), Paths.getBookDirectory(settings) }) do
        if directory and not seen[directory] then
            seen[directory] = true
            table.insert(directories, directory)
        end
    end
    return directories
end

return Paths
