# A KOReader plugin for Readwise and Readwise Reader
A plugin for KOReader integration with the highlight saving and read later services Readwise and Readwise Reader. A Readwise subscription is required. 

> This is a fork of [tomtom800/readwisereader](https://github.com/tomtom800/readwisereader) (by way of [Endle/readwisereader](https://github.com/Endle/readwisereader)). It adds library browsing and search, Quick/Long Reads and In Progress views, an on-device highlights browser, Save to Readwise Later, and more. See the [CHANGELOG](CHANGELOG.md) for everything that changed. Fork versions start at 3.0.0 so they never clash with upstream releases. Please report bugs with this fork [here](https://github.com/cnnlisboa/readwisereader/issues), not upstream.

## Key features:
- **Browse Reader** lists your Inbox, Later and Shortlist, so you can pick individual articles to download instead of syncing everything.
- **Search Library** searches titles, authors, sites, summaries and tags across Inbox, Later, Shortlist, Archive and Feed.
- **Views** gives you Quick Reads (5 minutes or less), Long Reads (20 minutes or more) and In Progress, modelled on Reader's own smart views.
- **Highlights** lets you read your Readwise highlights on the device: browse by Books, Articles, Tweets or Podcasts, search them, or go through today's Daily Review. Highlights open full-screen with Previous/Next paging.
- Downloaded articles get Reader's cover image as their KOReader cover (can be turned off).
- Articles in Readwise Reader saved to “Inbox”, “Later” or “Shortlist” are downloaded to KOReader as HTML files.
- Images are downloaded where this is possible.
- Articles which have been read in KOReader and marked as “finished” will be moved to the Readwise Reader Archive at the next sync, and deleted from KOReader.
- At sync, articles which have been archived in Readwise Reader will be deleted from KOReader.
- Particular types of article, locations and document tags can be excluded from syncing in the settings menu.
- Optionally, the plugin will only sync articles tagged as 'koreader' in Readwise (off by default).
- The number of articles downloaded per sync can be limited in the settings menu (default: unlimited).
- Highlights and notes that are saved in KOReader are exported to Readwise in the same sync process (disabled by default - enable in the settings menu). 
- Highlights you make in a downloaded Reader article, or in a local book linked to Reader, are placed on the matching passage in Readwise Reader itself, so they show inline there and tapping one in Readwise jumps to it. Editing a highlight's note in KOReader updates it in Reader at the next sync. See Limitations below for what is and isn't carried over.
- A local book can be explicitly linked to one Reader book without downloading Reader HTML. Its highlights then export with that Reader book's saved metadata; the plugin never links books from a filename or title alone.
- Tapping a link while reading adds a **Save to Readwise Later** option to KOReader's own external-link dialog (alongside Copy, Show QR code, and Open in browser), which saves the link to Reader's Later list. If there is no network connection, the link is queued and sent automatically the next time the network reconnects or a sync runs; queued links can also be sent manually from Advanced sync.
- Downloads show a progress bar with how many articles are done, how many are left, how much has been downloaded so far, and a Cancel button. Cancelling keeps everything already downloaded and takes effect at the next article, so a large article with many images finishes fetching first.
- Optionally, an article you have read further in Readwise Reader on another device will open at roughly that place in KOReader ("Start at Readwise Reader position", off by default). The position is approximate, and it only travels from Readwise Reader to KOReader - see Limitations below.
- Very image heavy files will download, but may cause KOReader to crash if the file is very large and your ereader can’t cope with this. Due to the way images are saved and the limitations of HTML files, this is more of an issue than with EPUBs. To mitigate this, there is a setting to allow the user to cap the size of a file, after which further images are not downloaded. This is set to 10MB by default, but may be changed according to the limits of the user’s setup. There is also a toggle to turn off image downloads completely if required.

## Limitations and Known Issues:
- Highlights only travel from KOReader to Readwise. Highlights made in Readwise Reader are not brought into KOReader.
- **Placing highlights in Reader** works for downloaded Reader articles and explicitly linked local books, and only for highlights made after you installed the version that added it (see the [CHANGELOG](CHANGELOG.md)). Older highlights may already be in Readwise from earlier exports, so they keep exporting the old way rather than appearing twice. Reader places a highlight by finding its exact passage; if it can't (for example, the text differs slightly between KOReader and Reader), the highlight is exported the old way, without a position, and the sync tells you how many. After a highlight is placed, only note changes are sent: Reader's API can't change a highlight's text, and deleting a highlight in KOReader does not delete it in Reader.
- Highlights in books with no Reader link are not anchored inside any Reader document. Readwise groups them by title, author, and source URL.
- Highlights exported the old way (not placed in Reader) carry a stable `highlight_url` derived from the annotation's creation time, so editing a highlight in KOReader updates it in Readwise on the next sync instead of adding a second copy. Readwise documents this update path for a highlight's *text*; whether it also revises an already-uploaded note is unverified.
- Native reading position only travels one way, from Readwise Reader to KOReader. Readwise Reader publishes how far through a document you are, but its API has no field for storing a position, so the manual KOReader-progress note is only a visible percentage mirror, not a native Reader position update (rechecked 2026-09-09; details in [ROADMAP.md](docs/ROADMAP.md)). Marking an article "finished" in KOReader still archives it in Readwise Reader. The position that is carried across is approximate, because Readwise Reader and KOReader lay the same article out differently.
- Books and PDFs already on your ereader cannot be uploaded to Readwise Reader from KOReader. The Readwise Reader API accepts a URL or a block of HTML, but has no file upload; EPUBs and PDFs can only be added by dragging them into the Readwise Reader web app or sharing to it from a phone. Highlights you make in those books are still exported to Readwise as normal.
- A local-book link is keyed to that file's exact device path. If you move, rename, or replace the file, link it again. A highlight record without a local file path (for example, an unmatched Kindle My Clippings entry) cannot use a local-book link.
- **Linked book progress** is manual and one book at a time. Sending progress writes only a marked `KOReader progress: N%` line to the Reader document note, preserving other note text. Applying Reader progress moves the open KOReader book to Reader's percentage approximately; it does not create a continuous progress sync.
- I am not planning to add any options to style the documents. However there are lots of tweaks you can apply as a user - see [here](https://koreader.rocks/user_guide/#L1-customizingappearance). 

## Browse, search, and views

Everything here works on metadata only, so it is quick and light on memory. Nothing downloads until you ask for it.

- **Readwise Reader → Browse Reader** lists Inbox, Later or Shortlist. Tap an article to select it, open its details if you want the summary, then choose **Download selected**. Use **Load more** for the next page and **Refresh list** to fetch it again.
- Hold any document in the Reader browser and choose **Edit tags** to change its tags in Readwise Reader with a tag picker. If you are offline, the change is kept and sent at the next sync. In the Highlights viewer, **Edit tags** changes a highlight's tags (online only).
- **Readwise Reader → Search Library** searches titles, authors, sites, summaries and tags across Inbox, Later, Shortlist, Archive and Feed. Reader's API has no search, so the plugin scans one page at a time; choose **Search next page** to keep going.
- **Readwise Reader → Views** offers Quick Reads (5 minutes or less), Long Reads (20 minutes or more) and In Progress. These scan Inbox, Later, Shortlist and Archive, not Feed.
- Podcasts and audiobooks never appear, because Reader only provides their show notes. Videos (YouTube transcripts) appear unless you turn off **Settings → Show videos when browsing**.

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

- Send the current KOReader percentage to the Reader document note.
- Apply the Reader percentage to the current KOReader book after confirmation.
- Remove only the marked KOReader-progress line from the Reader note after confirmation.

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
- Then choose **Readwise Reader → Sync now**.
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
