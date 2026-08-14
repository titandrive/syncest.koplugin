# Syncest

Syncest is a KOReader plugin for syncing reading data to a WebDAV folder you control. It is based on the Readest KOReader plugin, but with a different goal: keep KOReader progress, annotations, reading stats, vocabulary, and optional book files in one self-hosted central location instead of tying that data to a single device.

The WebDAV folder becomes the source of truth, so multiple KOReader devices can push and pull from the same place. It also keeps the synced files readable enough for other tools, such as an Obsidian note generator, to inspect and reuse.

Syncest was made primarily to be used alongside [Obsidian MoonSync](https://github.com/titandrive/Obsidian-MoonSync), an Obsidian plugin for working with the synced reading data. MoonSync is optional: Syncest can also be used standalone as a KOReader-to-WebDAV sync plugin.

## Features

- Sync reading progress per book.
- Sync annotations, including deleted annotation tombstones.
- Sync KOReader reading statistics.
- Sync vocabulary builder entries.
- Maintain a Syncest book library with optional book and cover upload/download.
- Browse the authoritative cloud catalog in grid or list view, with filters for
  cloud-only books and cloud books already present on the current device.
- Refresh or securely wipe the cloud catalog from the Library actions menu.
- Push or pull all sync data except book files/catalog from one menu command.
- Mirror progress pushes to KOReader KOSync when enabled.
- Auto sync on common reading events:
  - Push progress every X page turns.
  - Push progress when a chapter is finished.
  - Push progress, stats, and annotations on book close.
  - Push annotations when they change.
  - Push vocab after word lookup.
  - Pull progress and annotations on book open, with an optional stats pull.
  - Pull stats and vocab on app open.
- Background update checks with in-plugin install prompts.

## Installation

1. Download `syncest.koplugin.zip` from the latest GitHub release.
2. Unzip it into KOReader's `plugins` folder so the path is:

   ```text
   koreader/plugins/syncest.koplugin/
   ```

3. Restart KOReader.
4. Open the KOReader top menu and go to `Tools` -> `More tools` -> `Syncest`.

After Syncest is installed, future updates can be installed from `Syncest` -> `Sync settings` -> `Updates`.

## Setup

Open `Syncest` -> `Syncest: Not configured` -> `Configure WebDAV` and choose a WebDAV target through KOReader's cloud storage picker. After configuration, the connection entry shows `Syncest: Idle` until the first sync request finishes. It then shows `Syncest: Connected` after a successful request or `Syncest: Disconnected` after a failed request. Syncest stores all data under the folder path configured there.

This works well with self-hosted storage such as Nextcloud, a WebDAV server exposed over a VPN, or any other WebDAV-compatible backend KOReader can reach.

## Notifications

Open `Syncest` -> `Notifications` to enable or disable status notifications for progress, annotations, statistics, vocabulary, books and library operations, and connection changes. All notification types are enabled by default.

These controls suppress routine status notifications. Required confirmations and actionable error dialogs remain visible.

## WebDAV Layout

Syncest writes JSON files and optional book assets under the configured WebDAV folder:

```text
library.json
stats.json
vocab.json
sync/
  <book-hash>/
    progress.json
    annotations.json
    _<Book Title>.json
books/
  <book-hash>/
    <book-hash>.<ext>
    cover.png
    _<Book Title>.json
```

The `<book-hash>` folder names are stable machine identifiers. The `_<Book Title>.json` marker files make the folders human-readable and provide a stable metadata target for external automation.

## Synced Data

`progress.json` stores the current reading location and related dynamic progress fields for a single book. When available, it also carries the book's current `readingStatus` and `readingStatusUpdatedAt` so progress-only sync workflows can see the same status that appears in `library.json`.

`annotations.json` stores notes and highlights for a single book. Deleted annotations are synced as tombstones so another device can remove the same annotation instead of resurrecting it.

`stats.json` stores reading-stat rows from KOReader's statistics database.

`vocab.json` stores vocabulary builder entries.

`library.json` stores the Syncest book catalog: hashes, titles, authors, formats, reading status, timestamps, and metadata used by the Syncest Library view.

The marker files under `sync/<book-hash>/` and `books/<book-hash>/` use the same rich metadata shape. They store static book metadata such as title, author/authors, promoted identifiers like ISBN, Google Books ID, Calibre ID, and UUID when available, format, book filename, cover filename, source title, timestamps, and a cleaned KOReader metadata payload. Normal progress/annotation sync queues sync marker maintenance as low-priority background work, so metadata never blocks the actual reading data sync.

## Auto Sync Behavior

Auto sync can be enabled or disabled from the main Syncest menu. Individual auto-sync actions live under `Syncest` -> `Sync settings`.

Book-specific pulls happen when a book opens:

- Pull reading progress on book open.
- Pull annotations on book open.
- Optionally pull stats on book open.

Optional resume pulls can also run when KOReader returns to the foreground with a book already open:

- Pull reading progress on app resume.

Resume progress pulls use short background retries while Wi-Fi, DNS, or a VPN reconnects. Syncest only reports a disconnection if the final attempt fails, and update checks wait until the progress pull finishes.

If an automatic push fails, Syncest remembers the affected progress, annotations, stats, or vocabulary as pending. Pending changes survive KOReader restarts and are pushed once a resume, network-online callback, manual sync, or other successful Syncest request confirms that the connection is available again. Syncest does not poll the server on a recurring timer.

Global pulls happen when KOReader/Syncest starts:

- Pull stats on app open.
- Pull vocab on app open.

Pushes happen when data changes or when a book closes:

- Push every X page turns.
- Optionally push reading progress when a chapter is finished.
- Push reading progress on book close.
- Optionally push reading progress on app suspend.
- Push annotations on change.
- Push annotations on book close.
- Optionally push annotations on app suspend.
- Push stats on book close.
- Optionally push stats on app suspend.
- Push vocab on word lookup.

## Manual Sync

When a book is open, Syncest shows manual commands for that book:

- Push/pull reading progress.
- Push/pull annotations.

The main Syncest menu also includes:

- Push/pull stats.
- Push/pull vocab.
- Push/pull the Syncest book library and book files.
- Push all / Pull all for progress, annotations, stats, and vocab.

`Push all` and `Pull all` do not upload or download book files or the book catalog. Book library sync is kept separate on purpose.

Selecting a cloud-only book in the Syncest Library opens download options for choosing the destination folder, changing the filename, and viewing book information. After downloading, Syncest asks whether to read the book immediately.

`Push books now` scans the complete local library, verifies the corresponding files and covers directly on WebDAV, uploads only missing objects, and then publishes the successfully backed catalog entries. It does not rely on stale local cloud flags or the incremental sync cursor. `Pull books now` shows the current missing-book count and destination folder for confirmation, then refreshes the cloud catalog and downloads every cloud book that is not already present locally. Both operations verify books by hash, so an existing copy is updated or skipped instead of duplicated. Opening the Syncest Library refreshes its cloud catalog but does not automatically download every book.

If an archive folder is configured, pushing the Syncest book library skips books inside it.

The Library view menu keeps cloud-location filters in their own section. `Cloud Books` shows catalog books that are not on the current device, while `Local Books` shows catalog books that are also present locally; enabling both shows the complete cloud catalog. `Refresh` performs an authoritative rebuild from `library.json` while preserving device-local file detection. `Wipe Cloud` requires confirmation, deletes `library.json` and the uploaded `books/` collection, and never deletes local device files.

Manual stats pushes and pulls reconcile the complete statistics history. Automatic stats sync uses an incremental cursor for efficiency.

## Changelog

### 1.2.8

- Restore compatibility with KOReader 2026.07 and newer by using the replacement Cloud storage plugin API.
- Keep compatibility with older KOReader versions through the legacy SyncService fallback.

### 1.2.7

- Push chapter-completion progress immediately instead of holding it behind the automatic page-turn cooldown.
- Keep chapter and manual progress pushes on the same complete progress-and-history operation.
- Refresh filename-derived catalog titles and authors from embedded EPUB/PDF metadata during bulk library pushes.

### 1.2.6

- Acknowledge automatic chapter progress as soon as the latest reading position is durable, without waiting for progress-history bookkeeping.
- Keep manual progress checkpoints strict: their success notification still waits until both current progress and history are saved.

### 1.2.5

- Preserve cloud-only book titles across page changes and delayed Zen UI refreshes by rendering from title-named, hash-isolated thumbnails instead of exposing hash-named cover files.
- Extract embedded title, author, and metadata from local books during background bulk pushes when KOReader sidecar metadata is missing.
- Publish the EPUB/PDF metadata to `library.json` instead of treating an `Author - Title` filename as canonical metadata.
- Keep catalog metadata intact rather than applying display-time title parsing or stripping.

### 1.2.4

- Speed up manual reading-progress pushes by reducing normal progress-history bookkeeping to one read and one write.
- Repair missing WebDAV history folders only after a direct write fails instead of probing every folder before every checkpoint.
- Persist remote device-registration confirmation so established history files skip redundant registry requests while automatically re-registering after a cloud wipe.
- Make the manual success notification immediate after both current progress and its history checkpoint are durable; report failure if the requested checkpoint could not be saved.

### 1.2.3

- Render cached cloud-book and grouped-library covers through real PNG paths so Zen UI no longer replaces valid covers with generated placeholders.
- Reuse cloud cover art when a local book has no usable extracted cover, and fetch missing covers for every visible cloud-backed row.
- Materialize group mosaics before rendering while preserving the correct book and group titles instead of cache hashes.
- Normalize local and cloud thumbnails to the same square size in list view without changing grid covers.
- Increase WebDAV transfer timeouts for books and covers on high-latency mobile connections, and show progress while verifying which books actually need uploading.
- Simplify grouping to `None`, `Authors`, and `Series`; make the flat, ungrouped library the default and remove the unused legacy `Groups` option.

### 1.2.2

- Fix Cloud Library refresh on Android mobile data by bypassing KOReader's Wi-Fi-only online gate.
- Move automatic catalog pulls and lazy cover downloads into subprocesses so slow or unavailable networking cannot freeze the UI or trigger an Android ANR.
- Show the cached library immediately and apply automatic cloud updates silently when they arrive.
- Make Manual Refresh non-blocking and authoritative; it replaces any automatic refresh already in progress and reports completion.
- Prevent overlapping automatic cloud-refresh jobs.

### 1.2.1

- Prevent Zen UI's generic cover handler from opening synthetic cloud-cover paths behind Syncest dialogs.
- Make cloud-only book taps reliably show download options without an Opening overlay, frozen input, or crash when dismissed.
- Route Syncest grid and list selections through a single owned interaction path while preserving normal local-book opening.
- Label the post-download choices `Done` and `Read now`.
- Make Refresh a literal catalog replacement while restoring only device-local file identity by hash, so stale cloud metadata cannot survive a full refresh.

### 1.2.0

#### Cloud catalog correctness

- Make the Syncest Library display only books present in the cloud catalog; local files now classify cloud entries instead of appearing as independent cloud books.
- Make Refresh an authoritative full catalog refresh, including correct handling of an empty or deleted `library.json`.
- Preserve per-device `local_present`, file paths, and downloaded state while rebuilding cloud membership.
- Correct Cloud Books and Local Books filter behavior in flat and grouped views.
- Keep archived-only device rows out of the cloud presentation.

#### Safer book operations

- Verify actual WebDAV book files and covers during Push Books instead of trusting cached upload flags.
- Upload missing book objects before publishing their catalog rows, preventing visible entries that cannot be downloaded.
- Publish deletion tombstones before deleting remote book objects, preventing live catalog rows from pointing to removed files after a partial failure.
- Keep a retained local copy uploadable after removing only its cloud copy.
- Add a confirmed `Wipe Cloud` action that removes the catalog and uploaded book collection while preserving every local device file.

#### Covers and interface

- Restore reliable cloud and archived covers in both grid and list views, including local extracted-cover fallback when a remote cover is absent.
- Version cached cover URIs so newly downloaded covers replace stale placeholders immediately.
- Improve cloud indicators for Zen UI with transparent, solid-white outline icons in both views.
- Separate Cloud Books and Local Books into a dedicated Book Location section.
- Shorten Library action labels to Refresh, Set Directory, and Wipe Cloud.

#### Reliability and maintenance

- Keep Cloud Library opening pull-only so browsing never republishes local books.
- Invalidate grouped-library caches when cloud membership is cleared.
- Make local scans operate on device-local records rather than the cloud-filtered catalog.
- Add regression coverage for remote book and cover inventory detection.

## KOSync Mirroring

If KOReader's KOSync plugin is also configured, enable `Mirror progress to KOSync` in Syncest settings. When enabled, Syncest asks KOSync to mirror progress pushes during manual progress pushes, page-turn and chapter-finish autosync, and book-close progress pushes.

## Updates

Syncest can check GitHub releases in the background. When an update is available, it can notify you, prompt to install, and then prompt to quit KOReader after installation so the new plugin code loads cleanly.

Manual update checks are available from `Syncest` -> `Sync settings` -> `Updates`.

## Notes

Syncest is designed around self-hosting. It assumes your WebDAV storage is yours, reachable from each device, and durable enough to be the central copy of your reading data.

The plugin uses short network timeouts and background jobs for sync operations where possible, so a missing VPN connection or unreachable WebDAV server should fail gracefully instead of freezing or crashing KOReader.
