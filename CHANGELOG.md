# Changelog

This fork continues from [tomtom800/readwisereader](https://github.com/tomtom800/readwisereader)
v2.6 (via [Endle/readwisereader](https://github.com/Endle/readwisereader)). Versions start at
3.0.0 so they never collide with upstream release numbers.

## [Unreleased]

### Added
- **Edit tags** on a Reader document: hold a document in Browse Reader, Search Library or a view,
  then choose **Edit tags**. A full-screen picker lists every tag in your account; tap to tick or
  untick, or add a new one. The current tags are fetched fresh first, because Reader replaces the
  whole tag list on save and a tag added elsewhere must not be dropped.
- Offline tag edits are kept on the device and sent at the next sync, when the network returns, or
  from **Advanced sync → Send queued tag changes**. A queued edit is stored as "added / removed"
  and re-applied on top of the tags Reader has by then.
- After a tag edit, the tags in KOReader's Book Info keywords for an already-downloaded article are
  updated too.
- **Edit tags on a highlight** from the on-device highlights viewer (online only).
- **Archive** from Browse Reader, Search Library and views (hold a document). The local copy is
  removed too, unless it is open; then the next sync removes it.
- Tag changes made in Reader now update Book Info keywords for articles already on the device at
  the next sync.
- **Reader tags and note for the open document**: **Readwise Reader → Reader tags for this
  document** and **Reader note for this document**, for a downloaded article or a linked book. In
  KOReader's library, hold the file and choose **Reader tags** or **Reader note**.
- **Edit Reader notes.** Also from **Edit note** when holding a document in Browse Reader, Search
  and views. The note opens in Writer Deck's editor when it is installed (and Writer Deck shows a
  **Reader note** item and quote target for Reader documents), otherwise in KOReader's text box.
  The note is read fresh before editing. If it changed in Reader meanwhile, you choose what to keep.
  Offline edits start from the copy saved at the last sync and are sent later (**Advanced sync →
  Send queued note changes**), keeping both versions if Reader's changed.

### Changed
- **Reading position now syncs both ways** for downloaded articles and linked books, using the
  `reading_progress` field Readwise Reader's API now accepts. The setting is renamed **Sync reading
  position with Readwise Reader** (still off by default, existing choice kept). Opening a document
  jumps to your Reader position if Reader is ahead; closing it or putting the device to sleep sends
  your KOReader position if KOReader is ahead; each sync does both. The furthest position wins, so
  neither side is moved backwards. Wi-Fi is never turned on for this. PDFs only receive Reader's
  position, because Reader can't store one for them.
- The check on opening waits until the book is on screen. If you've already turned a page by then,
  it asks before jumping. Calls made while a book is open give up after a few seconds on a bad
  connection instead of retrying.
- **Finished articles are sent as 100%** read, and an article finished in Readwise Reader is marked
  finished in KOReader at the next sync.
- **An article finished in Readwise Reader is no longer deleted from the device** at the next sync.
  It stays until it is archived. Turn off **Archive finished articles** to archive finished articles
  only when you choose, with **Advanced sync → Archive finished articles on Readwise**.
- **Linked book progress → Send KOReader progress to Reader** now sets the real Reader position
  instead of writing a `KOReader progress: N%` line into the Reader note.
- When highlights are exported at sync, an article with highlights is only removed (archived,
  finished, or no longer in Reader) after its highlights have been exported. If they can't be, the
  article stays until the next sync, and the sync summary says how many were kept.

### Removed
- **Remove KOReader progress from Reader note.** The first sync after upgrading strips those note
  lines from linked books automatically, leaving the rest of each note untouched.

### Fixed
- **Excluded tags and types** now apply in the same sync that brings an article in, and ignore case.
  A new article with an excluded tag used to be downloaded and then removed a sync later.
- **Max articles per sync** could download one article more than the limit for each location.

## [3.1.0] - 2026-10-28

### Added
- Highlights made in a downloaded Reader article or a linked local book are now placed on their
  passage in Readwise Reader itself, using Reader's highlight API, so they show inline in Reader.
  Only highlights made after this update is installed are placed; older ones keep exporting the
  old way so Readwise doesn't get duplicates. A passage Reader can't find falls back to the old
  export, and the sync reports how many. Note edits in KOReader update the Reader highlight.
  Deleting a highlight in KOReader does not delete it in Reader.

## [3.0.0] - 2026-10-28

First release of this fork.

### Added
- **Browse Reader**: list Inbox, Later, and Shortlist from Readwise Reader, view details, select
  articles, and download just those. Browsing fetches metadata only, never article HTML.
- **Search Library**: search titles, authors, sites, summaries, and tags across Inbox, Later, Shortlist,
  Archive, and Feed.
- **Views**: Quick Reads (5 minutes or less), Long Reads (20 minutes or more), and In Progress,
  modelled on Reader's own smart views. Picking one only narrows the list; nothing downloads
  automatically.
- **Highlights**: read-only browsing of your Readwise highlights by Books, Articles, Tweets,
  and Podcasts, plus Search Highlights and Daily Review. Highlights open full-screen with
  Previous/Next paging and a jump to every highlight in the same book.
- **Save to Readwise Later** in KOReader's link dialog. Links tapped while offline are queued
  and sent on reconnect or at the next sync.
- **Link a local book to Reader**, so its highlights export with that Reader document's
  metadata, plus manual **Linked book progress** (send to or apply from the Reader note).
- **Start at Readwise Reader position** (optional): downloaded articles open at roughly the
  place you reached in Reader on another device.
- **Download progress** dialog with articles done/remaining, data downloaded, and Cancel.
- **Custom covers** for downloaded articles from Reader's cover image (JPEG/PNG, up to 5 MB).
- "Show videos when browsing" setting. Podcasts and audiobooks are always hidden from browsing,
  since Reader only provides their show notes.
- Version number is now shown in the plugin menu and read from `_meta.lua`.

### Changed
- Highlight export uses the title and author from KOReader's Book Info screen, sends real page
  numbers as the highlight location when available, and sends a stable `highlight_url` so an
  edited highlight updates in Readwise instead of being duplicated.

### Fixed
- Saving to Reader now accepts HTTP 201 as success.
- Browser selection is kept when launchers such as ZenOS rebuild the menu after a tap.
