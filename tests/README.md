# Tests

Pure-Lua unit tests for the parts of the plugin that do not need a running
KOReader: highlight payload construction/batching/error handling, explicit
local-file-to-Reader link persistence, Library search/views, and read-only
highlights listing/search/Daily Review, placing highlights in Reader
documents, and original EPUB downloads (validation, the download itself, and
`main.lua`'s EPUB/HTML decisions, driven with KOReader stubbed out). They stub the HTTP transport, so they
never touch a real Readwise account.

Run them from the repository root with the same runtime KOReader ships:

    luajit tests/test_book_notes.lua
    luajit tests/test_books.lua
    luajit tests/test_books_sync.lua
    luajit tests/test_browser.lua
    luajit tests/test_downloadprogress.lua
    luajit tests/test_epub.lua
    luajit tests/test_epub_download.lua
    luajit tests/test_highlights.lua
    luajit tests/test_highlight_ledger.lua
    luajit tests/test_highlights_read.lua
    luajit tests/test_local_links.lua
    luajit tests/test_progress.lua
    luajit tests/test_progress_note.lua
    luajit tests/test_reader.lua
    luajit tests/test_reader_highlight_ids.lua
    luajit tests/test_reader_highlights.lua
    luajit tests/test_reader_note.lua
    luajit tests/test_tag_filter.lua

or all of them at once:

    for f in tests/test_*.lua; do luajit "$f" || break; done

Anything that requires KOReader's own modules (`clip`, `docsettings`,
`readhistory`, ...) or a live API token is out of scope here and still has to be
verified on device.
