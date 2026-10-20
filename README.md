# pencil.koplugin

Freehand pencil, highlighter, eraser, annotation, note, handwriting-recognition, and PDF-ink support for stylus-enabled Kobo devices running KOReader.

The original plugin was created by [**mysticknits**](https://github.com/mysticknits). This fork combines work from the original project, upstream pull requests, the merged development branches, and the contributors acknowledged in [Credits](#credits).

## Compatibility

- **Recommended:** KOReader 2026.07 or newer, including Snowflake and later releases.
- **Older KOReader versions:** basic drawing may work with the legacy `input.lua` replacement, but the stock stylus API and native PDF ink export require KOReader 2026.07 or newer.
- **Documents:** PDF and reflowable documents are supported. Some capabilities are format-specific and are identified below.

## Features

### Low-latency drawing

- Draw freehand annotations with the pen tip.
- Captures the touch-down point, including single-point dots, and refreshes the stroke tail immediately on pen lift.
- Uses a fast e-ink waveform for dark ink and scoped refresh regions to reduce writing latency.
- Optional **Live black preview** draws colored pen strokes in black while writing, then repaints them in their saved color after the delayed quality refresh.
- Heavy work such as serialization, bookmark synchronization, grouping, and preview capture is deferred until the pen is idle.
- Stroke points are stored in a compact packed format to reduce sidecar size and serialization cost.

### Pen, eraser, and highlighter roles

- **Pen tip:** draws with the selected color and width, or erases when the eraser tool is selected.
- **Eraser end:**
  - touch without moving to toggle between pen and eraser;
  - drag to erase strokes without changing the selected tool.
- **Side button / highlighter role:**
  - drag across text to create a native KOReader text highlight when **Text highlight** is enabled;
  - draw a translucent freehand highlighter stroke when there is no text under the pen;
  - choose independent highlighter color and opacity settings.
- **Swap Eraser and Highlighter:** exchanges the physical eraser-end and side-button roles.
- Embedded PDF ink and native text highlights can also be removed with the eraser.

### Hold-still tool menu and pickers

Hold the pen or highlighter still for about half a second to open a context menu near the stylus.

The menu can include:

- **Undo**
- **Redo**
- **Lasso**
- **Note**
- pen colors;
- pen widths: 3, 5, 7, and 9 pixels;
- highlighter colors;
- highlighter opacity levels.

The highlighter picker uses the highlighter's own color palette and opacity choices. The contact that opens the picker is consumed until pen lift, preventing an accidental stroke or text highlight behind the popup.

### Undo and redo

- Undo and redo added strokes, erased strokes, and lasso moves.
- History tracks strokes by reference so it remains correct when erasing changes the stroke indices.
- New edits clear the redo history.

### Lasso editing

- Circle strokes to select them.
- Drag a selection to move it.
- Delete the selected strokes or finish the operation from the on-page controls.
- Uses fast previews while moving and refreshes the final result immediately.

### Handwritten notes

- Create a note from the hold-still menu at the current page position.
- Notes open in a full-screen handwriting canvas.
- Add and navigate multiple note pages.
- Undo note strokes, erase inside the note, or delete the note.
- Reopen a note by tapping its page marker with the pen.
- Notes are persisted with the document's pencil data.

### Highlighting

- **Side-button text highlighting:** drag across words to create a native KOReader highlight.
- **Freehand highlighter:** draws a translucent, colored stroke where no text is detected.
- **Hold-at-line-end highlighting:** draw a roughly horizontal line under text and briefly hold at the end; the temporary ink is replaced by a native KOReader highlight using the reader's default highlight style.
- Text-selection previews are shown while dragging.
- Native highlights can be erased with the stylus eraser, including highlights written into a PDF.

### Palm rejection and stylus reliability

- Optional **Ignore touch while writing** filters finger and palm contacts that begin while the pen is near the screen or was just used.
- Swallows palm contacts that Linux reports as stylus eraser/highlighter tools.
- Restores the plugin's stylus callback if another plugin unregisters it.
- Avoids capturing stylus input while menus or visible overlays are active.
- Supports KOReader 2026.07's stock stylus latches without replacing `input.lua`.

### Annotation grouping, bookmarks, and previews

- Groups nearby strokes created within a short time window into logical annotations.
- Optional bookmark synchronization creates KOReader bookmarks for annotation groups.
- Invalid bookmark positions are rejected to protect reflowable books from bookmark-sort failures.
- Groups in EPUB/reflowable documents use XPointers so their position can survive pagination, font, spacing, and rotation changes.
- Captures JPEG previews with page context for annotation groups.
- Annotation previews can be opened from rotation badges, annotation actions, and pencil bookmarks.
- Preview images are captured after writing becomes idle, backfilled when missing, and cleaned up when orphaned.
- The Pencil menu reports preview-image disk usage and can purge all previews for the current book.

### Handwriting recognition with MyScript

- Configure MyScript language, application key, and HMAC key in the Pencil menu.
- Recognize the latest annotation group on the current page.
- Recognize all annotation groups in the document.
- View all recognized text.
- Create or edit text manually for an annotation.
- Edit all recognized annotations in one form.
- Stores recognition metadata with groups and strokes using sidecar format version 5.
- Uses recognized text as the synchronized bookmark label when bookmark sync is enabled.

MyScript recognition requires network access and valid MyScript credentials. Keep credentials private and do not include them in issue reports or debug logs.

### PDF-native annotation export

For PDF documents, pencil ink can be embedded as native `/Ink` annotations that travel with the file and are visible in other PDF readers.

Two workflows are available:

1. **Save annotations to PDF (this page)**
   - embeds non-embedded pencil/highlighter strokes from the current page;
   - embeds native KOReader text highlights from the current page;
   - keeps each stroke's color, width, and opacity.

2. **Auto-save pencil ink to PDF on close**
   - embeds all new pencil/highlighter strokes across the document;
   - skips strokes already embedded, preventing duplicates;
   - intentionally leaves automatic text-highlight export to KOReader's own highlight workflow.

Additional safeguards:

- Embedded strokes receive stable plugin-owned annotation tags.
- Erasing embedded ink removes the corresponding PDF annotation.
- Orphaned or duplicate plugin-owned ink annotations are pruned without touching foreign PDF annotations.
- Highlight appearance streams are generated so markup remains visible in desktop PDF viewers.
- All in-memory PDF changes are written once on document close, preventing corruption caused by stacked incremental saves.
- A failed final write rolls back newly embedded sidecar flags.
- The feature degrades gracefully when the document is read-only or required MuPDF symbols are unavailable.

**Requirements:** KOReader 2026.07 or newer with the MuPDF ink APIs introduced in [koreader-base#2444](https://github.com/koreader/koreader-base/pull/2444).

### Rotation, zoom, and document moves

- PDF strokes are anchored to page coordinates and follow zoom, pan, crop, continuous-page layouts, and rotation.
- Legacy screen-space annotations retain preview-badge fallback behavior when their saved rotation no longer matches.
- Pencil sidecar data follows a document when KOReader moves its metadata after a file rename.

### Storage and recovery

- Stores data per document in `pencil_strokes.lua` inside the document sidecar.
- Preserves compatibility with earlier stroke formats while writing compact format version 5.
- Refuses to overwrite unloaded data with an empty save.
- Flushes pending saves and image captures on page changes, close, and suspend.
- Provides page-level and document-level clearing commands.

### Diagnostics and gesture mapping

Available gesture actions:

- **Pencil: toggle on/off**
- **Pencil: toggle pencil/eraser**
- **Pencil: select pencil**
- **Pencil: select eraser**
- **Pencil: undo**
- **Pencil: redo**

The optional input debug mode records raw stylus, eraser, side-button, and palm-rejection decisions in KOReader's writable data directory. The Pencil menu also provides an annotation-status view and a command to clear the debug log.

## Installation

1. Download the `pencil.koplugin` directory from this repository.
2. Copy it into KOReader's `plugins` directory.
3. Restart KOReader.
4. Open a document and enable **Top menu > More tools > Pencil > Enabled**.

### KOReader older than 2026.07

Only for an older build, install the legacy `input.lua` supplied by the project into `frontend/device/input.lua` if your device needs it for stylus interception and eraser detection.

Do **not** replace `input.lua` on KOReader 2026.07 or newer. Those releases already provide the required stock stylus support, and copying the legacy file would overwrite newer core code.

## Configuration

Open **Top menu > More tools > Pencil**.

Main settings include:

- Enabled
- Swap Eraser and Highlighter
- Highlighter color and opacity
- Selected tool
- Undo / Redo
- Clear page strokes / Clear all strokes
- Annotation preview-image cleanup
- Handwriting recognition and MyScript settings
- Input debug mode

Experimental settings include:

- Bookmark sync
- Color picker
- Pen width picker
- Tool menu when holding the pen still
- Highlight by holding at line end
- Ignore touch while writing
- Text highlight with the side button
- Save annotations to PDF for the current page
- Auto-save pencil ink to PDF on close
- Live black preview

## Troubleshooting and issue reports

Before opening an issue:

1. Confirm the KOReader version and device model.
2. Enable **Pencil > Input debug mode**.
3. Clear the debug log.
4. Reproduce the problem with the pen tip, eraser end, and side button as relevant.
5. Attach the log and describe the document type, rotation, zoom mode, and enabled experimental options.

Do not include MyScript credentials or documents containing sensitive information.

## Credits

This project is the result of contributions across the original repository, upstream pull requests, development forks, reviews, tests, integrations, and supporting projects.

### Original project and maintainers

- [**mysticknits**](https://github.com/mysticknits): original author of `pencil.koplugin` and primary source of the plugin's functionality.
- [**tomas**](https://github.com/tomas): maintenance and integration work reflected across the shared development branches.
- [**andrew-lawlor**](https://github.com/andrew-lawlor): maintenance, performance, bookmark-safety, release, test, and integration work.
- **bateast**: merged-branch integration, MyScript adaptation and text-editing work, modular tool integration, highlighter/eraser evolution, and correction of the merged highlighter-picker regression.

### Feature and code contributors

- [**hanokyu**](https://github.com/hanokyu): KOReader 2026.07 stylus support, palm rejection, callback restoration, hold-still tool menu, lasso, note canvas, undo/redo improvements, PDF page anchoring, underline-to-highlight, performance fixes, tests, and fork documentation.
- [**mysticknits**](https://github.com/mysticknits): annotation previews, latency reduction, bookmark integration, side-button highlighting, width picker, color support, eraser functionality, compatibility updates, tests, and release work.
- [**tomas**](https://github.com/tomas): native PDF annotation export and associated integration work.
- [**andrew-lawlor**](https://github.com/andrew-lawlor): safe bookmark positions and extensive performance, storage, anchoring, recognition, and release work represented in the merged history.
- [**ardaklco**](https://github.com/ardaklco): smoother drawing and eraser performance work for Kobo Sage.
- [**janoschp**](https://github.com/janoschp): colorful strokes.
- [**Euphoriyy**](https://github.com/Euphoriyy): night-mode color handling.
- [**CharlieQLe**](https://github.com/CharlieQLe): stylus side-button detection and configurable eraser/highlighter roles.
- [**AndyHazz**](https://github.com/AndyHazz): correct stylus behavior when invisible overlays are present.
- [**bateast**](https://github.com/bateast): moving pencil stroke data with documents after a rename ([upstream PR #86](https://github.com/mysticknits/pencil.koplugin/pull/86)).
- [**andrew-lawlor**](https://github.com/andrew-lawlor): preventing invalid bookmark positions ([upstream PR #89](https://github.com/mysticknits/pencil.koplugin/pull/89)).
- **laurenamy**: compact v4 save-format work originating from [upstream PR #77](https://github.com/mysticknits/pencil.koplugin/pull/77).

### Techniques, dependencies, and tooling

- Eraser-end event propagation uses techniques from [eraser.koplugin](https://github.com/SimonLiu423/eraser.koplugin) by **Simon Liu** (`simonliu423`).
- Palm/stylus classification was adapted from [Ink Away](https://github.com/EmirErtorer/ink-away.koplugin) by **Emir Ertörer**, under its MIT license.
- Native annotation support relies on KOReader and koreader-base contributors, including the MuPDF ink API work delivered through [koreader-base#2444](https://github.com/koreader/koreader-base/pull/2444) and markup appearance-stream support associated with `koreader-base#2457`.
- Parts of the fork's implementation and documentation were developed with [Claude Code](https://claude.com/claude-code) and Microsoft Copilot, with human review and integration.

If a contributor or contribution is missing or misattributed, please open an issue or pull request with the relevant commit or pull-request link so the credits can be corrected.

## License

Licensed under the same license as the original plugin. See [LICENSE](LICENSE).
