# A KOReader plugin for Readwise and Readwise Reader
A plugin for KOReader integration with the highlight saving and read later services Readwise and Readwise Reader. A Readwise subscription is required. 

> This is a fork of [tomtom800/readwisereader](https://github.com/tomtom800/readwisereader) (by way of [Endle/readwisereader](https://github.com/Endle/readwisereader)). It adds library browsing and search, Quick/Long Reads and In Progress views, an on-device highlights browser, Save to Readwise Later, and more. See the [CHANGELOG](CHANGELOG.md) for everything that changed. Fork versions start at 3.0.0 so they never clash with upstream releases. Please report bugs with this fork [here](https://github.com/cnnlisboa/readwisereader/issues), not upstream.

## Key features:
- **Three syncs**, at the top of the menu. **Sync reading data** handles only what's already on the device, books first: reading positions, highlights and notes (to Readwise and, with Device Sync, to your other readers), highlight tags, book notes, and Readwise Books status and rating. Nothing is downloaded or deleted, and highlights are read only from books changed since the last sync. **Sync books** adds books from your Readwise Books shelves, uploads and finished books. **Sync all** does everything, books before articles.
- **Automatic sync.** Opening a book fetches its Reader position; sleep sends it. While reading, the position is sent every 10 pages (at most once a minute). A few seconds after closing a book, that book alone is synced: its highlights and notes, tags, book note, and Readwise Books status. All of this only when Wi-Fi is already on. **Automatic sync** in the menu can switch the closing step to Reading data, Sync all or Off, and turn the every-10-pages position off.
- **Browse Reader** lists your Inbox, Later and Shortlist, so you can pick individual articles to download instead of syncing everything.
- **Search Library** searches titles, authors, sites, summaries and tags across Inbox, Later, Shortlist, Archive and Feed.
- **Views** gives you Quick Reads (5 minutes or less), Long Reads (20 minutes or more) and In Progress, modelled on Reader's own smart views.
- **Readwise Books shelves** lists the Reader books on each shelf (Currently reading, Want to read, Finished, Did not finish) so you can pick which to download.
- **Highlights** lets you read your Readwise highlights on the device: browse by Books, Articles, Tweets or Podcasts, search them, or go through today's Daily Review. Highlights open full-screen with Previous/Next paging.
- Downloaded articles get Reader's cover image as their KOReader cover (can be turned off).
- Articles in Readwise Reader saved to “Inbox”, “Later” or “Shortlist” are downloaded to KOReader as HTML files.
- Books you uploaded to Readwise Reader download as the **original EPUB file** ("Download books as EPUB", on by default), with the book's own layout, images, cover and table of contents, into the Book download directory. If Reader has no original file for a book, its HTML version is used instead. An HTML copy of a book already on the device is replaced by the EPUB at the next sync, as long as it was never read (no progress, highlights or bookmarks). If the same EPUB is already on the device as a book you copied over yourself (identical file contents, not just the same title), no second copy is downloaded: your copy is linked to Reader, so its reading position and highlights sync like a downloaded book.
- Images are downloaded where this is possible.
- **Finished documents** chooses what happens when you finish something: **When I finish** applies to articles only (the default), books only, all documents, or nothing; **Archive in Reader** and **Delete from this device** switch the two halves separately. Documents archived or removed in Reader follow the same choice. **Keep this document on device** (or **Keep on device** when holding a file) keeps any book or article from being deleted automatically. An article you finish in Readwise Reader stays on the device until it is archived.
- Downloads are named `Title [rw-<id>].html` (or `.epub`), so the title comes first. Files downloaded earlier keep their `[rw-id_<id>] Title` names and still work.
- **Book notes.** With Writer Deck installed, a book's Writer Deck note is kept the same as its Reader document note, both ways, at each sync. readwise-sync then puts it in your Obsidian book note. If both sides changed, both versions are kept under a ⚠ line.
- Particular types of article, locations and document tags can be excluded from syncing in the settings menu. Exclusions ignore case and apply to an article in the same sync that brings it in.
- Optionally, the plugin will only sync articles tagged as 'koreader' in Readwise (off by default).
- The number of articles downloaded per sync can be limited in the settings menu (default: unlimited).
- Highlights and notes that are saved in KOReader are exported to Readwise in the same sync process (disabled by default - enable in the settings menu). 
- Highlights you make in a downloaded Reader article, or in a local book linked to Reader, are placed on the matching passage in Readwise Reader itself, so they show inline there and tapping one in Readwise jumps to it. Editing a highlight's note in KOReader updates it in Reader at the next sync. See Limitations below for what is and isn't carried over.
- A local book can be explicitly linked to one Reader book without downloading Reader HTML. Its highlights then export with that Reader book's saved metadata; the plugin never links books from a filename or title alone.
- Tapping a link while reading adds a **Save to Readwise Later** option to KOReader's own external-link dialog (alongside Copy, Show QR code, and Open in browser), which saves the link to Reader's Later list. If there is no network connection, the link is queued and sent automatically the next time the network reconnects or a sync runs; queued links can also be sent manually from Advanced sync.
- Downloads show a progress bar with how many articles are done, how many are left, how much has been downloaded so far, and a Cancel button. Cancelling keeps everything already downloaded and takes effect at the next article, so a large article with many images finishes fetching first.
- Optionally, your reading position is kept in step with Readwise Reader for downloaded articles and linked books ("Sync reading position with Readwise Reader", off by default). A couple of seconds after opening one, it jumps to your Reader position if you read further there (if you've already turned a page, it asks first). Closing it, or putting the device to sleep, sends your KOReader position to Reader if you read further in KOReader. Each sync does both for downloaded articles. Marking an article finished in KOReader sends it as 100% read, and an article finished in Readwise Reader is marked finished in KOReader at the next sync. The furthest position always wins, so neither side is ever moved backwards. This needs Wi-Fi to already be on; the plugin never turns it on, and the next sync catches up.
- Very image heavy articles will download, but may cause KOReader to crash if the file is very large and your ereader can’t cope with this. Due to the way images are saved and the limitations of HTML files, this is more of an issue than with EPUBs. To mitigate this, there is a setting to allow the user to cap the size of a file, after which further images are not downloaded. This is set to 10MB by default, but may be changed according to the limits of the user’s setup. There is also a toggle to turn off image downloads completely if required.

## Limitations and Known Issues:
- Highlights travel from KOReader to Readwise. Highlights made in Readwise Reader are not brought into KOReader. Between your own readers they travel through the Device Sync plugin (see below).
- **Placing highlights in Reader** works for downloaded Reader articles and explicitly linked local books, and only for highlights made after you installed the version that added it (see the [CHANGELOG](CHANGELOG.md)). Older highlights may already be in Readwise from earlier exports, so they keep exporting the old way rather than appearing twice. Reader places a highlight by finding its exact passage; if it can't (for example, the text differs slightly between KOReader and Reader), the highlight is exported the old way, without a position, and the sync tells you how many. After a highlight is placed, only note changes are sent: Reader's API can't change a highlight's text, and deleting a highlight in KOReader does not delete it in Reader.
- Highlights in books with no Reader link are not anchored inside any Reader document. Readwise groups them by title, author, and source URL.
- Highlights exported the old way (not placed in Reader) carry a stable `highlight_url` derived from the annotation's creation time, so editing a highlight in KOReader updates it in Readwise on the next sync instead of adding a second copy. Readwise documents this update path for a highlight's *text*; whether it also revises an already-uploaded note is unverified.
- Reading positions are approximate, because Readwise Reader and KOReader lay the same article or book out differently; differences under 2% are ignored. PDFs only receive Readwise Reader's position: Reader can't store one sent from KOReader for a PDF. Checking Reader on open and sending on close or sleep can pause KOReader for a moment, a few seconds at most on a bad connection.
- A downloaded EPUB is retried at the next sync if the transfer fails (for example, Wi-Fi drops); after three failed syncs the HTML version is used. A book is checked to be a complete EPUB before it is kept, so a broken transfer never leaves a file KOReader can't open.
- Books and PDFs already on your ereader cannot be uploaded to Readwise Reader from KOReader. The Readwise Reader API accepts a URL or a block of HTML, but has no file upload; EPUBs and PDFs can only be added by dragging them into the Readwise Reader web app or sharing to it from a phone. Highlights you make in those books are still exported to Readwise as normal.
- A local-book link is keyed to that file's exact device path. If you move, rename, or replace the file, link it again. A highlight record without a local file path (for example, an unmatched Kindle My Clippings entry) cannot use a local-book link.
- Older versions wrote a `KOReader progress: N%` line into linked books' Reader notes. The first sync after upgrading removes those lines and leaves the rest of each note alone.
- I am not planning to add any options to style the documents. However there are lots of tweaks you can apply as a user - see [here](https://koreader.rocks/user_guide/#L1-customizingappearance). 

## Browse, search, and views

Everything here works on metadata only, so it is quick and light on memory. Nothing downloads until you ask for it.

- **Readwise Reader → Browse Reader** lists Inbox, Later or Shortlist. Tap an article to select it, open its details if you want the summary, then choose **Download selected**. Use **Load more** for the next page and **Refresh list** to fetch it again.
- Hold any document in the Reader browser and choose **Edit tags** to change its tags in Readwise Reader with a tag picker, or **Edit note** to edit its Reader note. If you are offline, the change is kept and sent at the next sync. In the Highlights viewer, **Edit tags** changes a highlight's tags (online only).
- **Readwise Reader → Search Library** searches titles, authors, sites, summaries and tags across Inbox, Later, Shortlist, Archive and Feed. Reader's API has no search, so the plugin scans one page at a time; choose **Search next page** to keep going.
- **Readwise Reader → Views** offers Quick Reads (5 minutes or less), Long Reads (20 minutes or more) and In Progress. These scan Inbox, Later, Shortlist and Archive, not Feed.
- **Readwise Reader → Readwise Books shelves** shows each Readwise Books shelf with the books that are in Reader. Select books and download them; this works whatever the automatic download shelves are. Books on a shelf that aren't in Reader (paper, Kindle) are counted but can't be downloaded.
- Podcasts and audiobooks never appear, because Reader only provides their show notes. Videos (YouTube transcripts) appear unless you turn off **Settings → Show videos when browsing**.

## Tags and notes for the document you're reading

For a downloaded article or a linked book:

- **Readwise Reader → Reader tags for this document** opens the tag picker for the open document.
- **Readwise Reader → Reader note for this document** edits its Readwise Reader note.
- In KOReader's library, **hold the file** and choose **Reader tags** or **Reader note**.

The note opens in the Writer Deck plugin's editor when that plugin is installed, otherwise in KOReader's full-screen text box. Writer Deck also gets a **Reader note** item in its own menu, and **Writer Deck: add to… → Reader note** for selected text, whenever the open document is in Reader.

Reader replaces the whole note when it is saved, so the plugin starts from the note as it is in Reader:

- Online, the note is read fresh. If it changed in Reader while you were editing, you choose: add yours to the end, replace with yours, or keep Reader's.
- Offline, you edit the copy saved at the last sync, and the edit is sent at the next sync, when the network returns, or from **Advanced sync → Send queued note changes**. If Reader's note changed in the meantime, both are kept, with yours added under a "From KOReader:" line.
- Offline with no saved copy (a linked book that was never synced), what you write is added to the end of the Reader note.

## Read your highlights

**Readwise Reader → Highlights** is read-only. It shows what is already in Readwise; it does not change anything there.

- Pick **Books**, **Articles**, **Tweets** or **Podcasts**, then a title, to see its highlights.
- **Search Highlights** searches highlight text and notes.
- **Daily Review** shows today's review as Readwise sends it.
- A highlight opens full-screen. Use **◀ Previous** / **Next ▶** to page through, or **View all highlights in this book** to jump to the rest.

## Link a local book to Reader

1. Open the sideloaded book in KOReader.
2. Choose **Readwise Reader → Link current book to Reader…**.
3. Search the Reader library, inspect the candidates if necessary, and select the exact book.
4. Choose **Readwise Reader → Advanced sync → Export highlights to Readwise** whenever you want to send highlights. This path exports highlights only; it does not download Reader HTML.

The filename is prefilled solely as a search suggestion. You always choose the target manually, and **Remove Reader link for current book** reverses the association.

For a linked, open local book, choose **Readwise Reader → Linked book progress** to:

- Send the current KOReader position to Readwise Reader, even if Reader is further ahead (not for PDFs).
- Apply the Reader position to the current KOReader book after confirmation.

With **Sync reading position with Readwise Reader** on, this happens automatically.

## Readwise Books

**Readwise Reader → Readwise Books → Sync with Readwise Books** connects the books you read here to [Readwise Books](https://readwise.io/books_api). It works for EPUBs downloaded from Reader and for sideloaded books linked to Reader. The plugin matches them to Readwise Books entries by title and author.

- **Opening a book** marks it *Currently reading* and sets its start date, if it has none.
- **Finishing it**, putting it **On hold**, or **rating** it sends *Finished* (with the finish date), *Did not finish*, or the rating. A date or rating already in Readwise Books is never overwritten.
- **Readwise Books changes reach this device at sync.** A book set to *Finished* is marked finished here. *Did not finish* puts it on hold. With **Add Want to read books to To Be Read** on, *Want to read* adds it to the *To Be Read* collection.
- **Finished is final.** Opening a finished book asks whether to start a re-read. Only a re-read moves it back to *Currently reading*.
- **Download books on these shelves** chooses which Reader books are downloaded at sync. The default is *Currently reading* only, so a book uploaded for later stays off the device. Books already here are kept.
- Deleting finished books is set under **Finished documents** (books are kept unless you choose *Books only* or *All documents*).
- **Reading sessions** come from KOReader's reading statistics and are posted to Readwise Books. If several devices share statistics, use **Post reading sessions from this device** on only one of them.
- **Sideloaded EPUBs** added to the book folder are offered for upload to Readwise. Books already in the folder when this is first switched on are not offered. Use **Upload current book to Readwise** for those, or **Never upload this book** to stop being asked.
- **Readwise tags…** in the highlight menu tags a highlight. The tags are applied in Readwise at the next sync.

The first sync after switching this on only records where each book stands. It doesn't act on old shelves, so books already *Finished* in Readwise aren't deleted all at once.

## Automation

Under **Readwise Reader → Automation**, each automatic action has its own mode:

- **Automatic**: the action runs on its own.
- **Ask**: you're asked each time.
- **Manual**: the action only runs from **Automation → Run now**.

Use Ask or Manual for anything that slows down opening a book. This covers reading position on open and on close, Readwise Books updates, downloading books, sending highlights, highlight tags, chapter headings, reading sessions, archiving finished documents, and EPUB uploads. The old "Archive finished articles" and "Export highlights at each sync" switches became the *Archive* and *Send highlights* modes, and your previous choice is kept.

Highlights are sent once. They are sent again only if you edit them on the device, and never after they were deleted in Readwise. On first use the plugin reads your Readwise export to learn what is already there. For books not linked to Reader, a heading highlight (`.h2`) is added for each chapter that has highlights.

## Working with Device Sync

[Device Sync](https://github.com/cnnlisboa/koreader-bridge/tree/main/device_sync.koplugin) keeps several readers in step through Google Drive and Todoist. With both installed, each plugin syncs what the other doesn't:

- **Reading position and status** of documents downloaded from Reader or linked to it come from Readwise (when *Sync reading position with Readwise Reader* is on). Device Sync asks this plugin and leaves those documents alone. Every other book's position goes through Device Sync.
- **Highlights, notes and bookmarks** go between readers through Device Sync, for every document. **Sync reading data** runs Device Sync's pass before sending highlights. A highlight placed in Reader carries its Reader id on the KOReader highlight, so the other reader recognises it and doesn't place it a second time.
- **Files** downloaded from Reader never go through Drive; each reader downloads them itself. Books you copy on yourself go through Drive as before.
- **Writer Deck notes** go through Device Sync. Book notes of Reader documents also go to Readwise (see Book notes above), so KOReader Bridge doesn't export them to Obsidian a second time.

## Installation:
- Download `readwisereader-vX.Y.Z.zip` from the [latest release](https://github.com/cnnlisboa/readwisereader/releases/latest). Extract it.
- Attach your ereader to your computer. Copy the `readwisereader.koplugin` folder containing _meta.lua and main.lua from the extracted folder to the `koreader/plugins` folder. If you had the upstream plugin installed, replace its folder; your settings are kept. Restart KOReader.
- The plugin requires a Readwise access token, which subscribers can obtain [here](https://readwise.io/access_token).
- The token can be typed in manually in the **Readwise Reader → Settings → Configure Readwise Reader** menu, but this is difficult to do correctly. It's easy to be confused by the letter O and the number 0, or the lowercase letter l, the uppercase letter I and the numeral 1. If the plugin is not working, check this first.
- Set where articles are saved in **Readwise Reader → Settings → Article download directory**.
- You may prefer to paste the access token from your computer instead. The plugin creates `koreader/settings/readwisereader.lua` the first time KOReader starts with it installed. With KOReader closed, open that file and set `access_token` (and `directory`, if you haven't chosen a folder yet). Leave any other keys as they are; the plugin fills them in itself. A minimal file looks like this:

```
-- ./settings/readwisereader.lua
return {
    ["readwisereader"] = {
        ["access_token"] = "{access token}",
        ["directory"] = "{download location}",
    },
}
```
- Then choose **Readwise Reader → Sync all**.
- By default, the extension will be added to the file menu with the prefix NEW:. The plugin will work in this format, but to remove the NEW: prefix and to move it to a different menu, add a line for  `"readwisereader",` in the appropriate place in koreader/frontend/ui/elements/filemanager_menu_order.lua

## Bug reporting
Report bugs on [this fork's issue tracker](https://github.com/cnnlisboa/readwisereader/issues), and include the plugin version shown at the bottom of the Readwise Reader menu. If reporting a bug, especially one that causes KOReader to crash, please share logging from your device in koreader/crash.log. Errors and crashes are clearly marked. To ensure that you just capture the relevant logs, delete the file, let KOReader regenerate it for you, then save the file after the issue has occurred.

## Development
Notes for devs and power-users. Don't proceed unless you know the meaning of each step.

### Tests
Unit tests cover the modules that run without KOReader and stub all network calls. Run them with LuaJIT from the repository root; see [tests/README.md](tests/README.md) for details.

```
for f in tests/test_*.lua; do luajit "$f" || break; done
```

CI runs luacheck, a LuaJIT syntax check and these tests on every push and pull request.

### Releasing
1. Bump `version` in `readwisereader.koplugin/_meta.lua`. The plugin menu reads the version from there.
2. Add a `## [x.y.z] - YYYY-MM-DD` section to [CHANGELOG.md](CHANGELOG.md).
3. Commit, then tag and push: `git tag vx.y.z && git push origin main vx.y.z`.

The Release workflow checks that the tag matches `_meta.lua`, runs the tests, zips only `readwisereader.koplugin/`, and publishes a GitHub release with that version's changelog section as its notes.

### Project planning

- [Architecture and API capability matrix](docs/ARCHITECTURE.md)
- [Phased roadmap](docs/ROADMAP.md)
- [Phase 1 build and Kindle verification plan](docs/PHASE-1.md)

### Test KOReader on Linux PC
KOReader has [Linux release](https://github.com/koreader/koreader/wiki/Installation-on-desktop-linux), so it's a breeze to test this plugin on Linux.

1. Install KOReader [via Flatpak](https://flathub.org/en/apps/rocks.koreader.KOReader)
2. `git clone git@github.com:cnnlisboa/readwisereader.git`
3. Check plugin directory `$HOME/.var/app/rocks.koreader.KOReader/config/koreader/plugins` - Thanks to [MountainToppish](https://www.reddit.com/r/koreader/comments/1mt7g9x/how_to_add_plugins_to_koreader_installed_from/)
4. Install the plugin by `cd  $HOME/.var/app/rocks.koreader.KOReader/config/koreader/plugins && ln -s $HOME/<source_path>/readwisereader.koplugin`
5. Restart KOReader
