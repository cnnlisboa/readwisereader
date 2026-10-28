# Changelog

This fork continues from [tomtom800/readwisereader](https://github.com/tomtom800/readwisereader)
v2.6 (via [Endle/readwisereader](https://github.com/Endle/readwisereader)). Versions start at
3.0.0 so they never collide with upstream release numbers.

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
