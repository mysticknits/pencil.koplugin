# pencil.koplugin

## Information

This has been tested on:

- Kobo Libra Colour/Kobo Stylus 2/Epub format

**This will currently only work on Kobo devices! I will attempt to add other device support by request and at a later date**

If you resize your book while reading it, your annotations will be WONKY. This is something I will eventually address but for now, get your book set before you start writing.

### Compatible with Koreader - Snowflake

## Features

- **Pen tip**: Draw annotations on your ebooks
- **Eraser end**: Flip your stylus over to erase strokes instantly
- **Highlighter**: Hold the stylus side button and drag to highlight; tap the side button to toggle pencil/eraser
- **Swap Eraser/Highlighter**: Reassign which side button acts as eraser vs. highlighter from the menu
- **Undo**: Undo your last stroke or eraser action
- **Clear strokes**: Clear annotations for the current page or the entire document
- **Annotation grouping**: Strokes are automatically grouped into logical annotations based on timing and proximity
- **Enable/disable toggle**: Turn the plugin on or off via the menu or a mapped gesture
- **Per-document storage**: Annotations are saved with each book
- **Input debug mode**: Log raw stylus events to help diagnose detection issues

## Instructions for Installation

1. Download both the `pencil.koplugin` directory and the `input.lua` file from this repository.
2. Replace the `/frontend/device/input.lua` with the downloaded file. This enables the plugin to intercept the stylus input, separate it from touch inputs, and detect the eraser end.
3. Copy the `pencil.koplugin` directory into the `/plugins` directory of KOReader.

## Configuring the Pencil Plugin

1. Enable the plugin from the Pencil menu (Top menu > More tools > Pencil > Enabled)
2. If your stylus's side button mapping is reversed, toggle **Swap Eraser and Highlighter** in the Pencil menu
3. Optionally map actions to gestures in Gesture Manager:
   - **Pencil: toggle on/off** — enable or disable the plugin
   - **Pencil: toggle pencil/eraser** — switch between tools
   - **Pencil: select pencil** — switch to pencil
   - **Pencil: select eraser** — switch to eraser
   - **Pencil: undo** — undo last stroke or eraser action

## Questions or Issues with the Plugin

If you have any questions or a feature request, please submit an issue in this repo.
If you're experiencing issues with the plugin, please enable input debug mode in the Pencil menu, reproduce the issue, and include the debug log file in your issue report.

## Experimental Features

Some features are still in development and are hidden behind an experimental toggle. You can find them under **Pencil menu > Experimental**.

### Color picker

When enabled, holding the pen still on the page opens a picker with 10 color options. When disabled, the pen stays on its last-saved color.

**To enable:** Pencil menu > Experimental > Color picker

### Pen width picker

When enabled, the picker also shows pen width options (3, 5, 7, 9), rendered as black bars whose height previews the stroke thickness. **Requires the color picker to also be enabled.**

**To enable:** Pencil menu > Experimental > Pen width picker

### Bookmark Sync

When enabled, the plugin automatically groups your pencil strokes into logical annotations (based on timing and proximity) and creates KOReader bookmarks for each one. This means annotated pages show up in the **Bookmarks menu**, so you can quickly navigate back to pages you've written on.

**To enable:** Pencil menu > Experimental > Bookmark sync

**What happens when you turn it on:**
- Existing pencil annotations are grouped and bookmarks are created immediately
- New strokes are grouped and bookmarked as you draw
- Bookmarks appear in KOReader's Bookmarks menu as "Pencil annotation on page X"
- Erasing or undoing strokes updates the bookmarks automatically

**What happens when you turn it off:**
- All pencil bookmarks are removed from the Bookmarks menu
- Your pencil strokes and drawings are not affected — only the bookmarks are removed
- Annotation groups are still tracked internally, so you won't lose any grouping data if you turn it back on

### Save annotations to PDF

Writes the **current page's** pencil strokes into the PDF file as native ink annotations
(`/Subtype /Ink`), so they travel with the file and are visible/removable in any PDF reader —
not just re-drawn by this plugin. **PDF documents only.**

**To use:** Pencil menu > Experimental > Save annotations to PDF (this page)

**Notes and limitations:**
- **Current page only.** Conversion uses KOReader's live on-screen page transform, which is
  exact only for the page you're viewing. As with the rest of the plugin, keep a consistent
  (fixed) zoom — resizing after drawing will misplace annotations.
- After saving, you're asked whether to remove the plugin's overlay copies for that page, so
  the embedded annotation isn't drawn twice.
- **Requires an ink-capable `libwrap-mupdf.so`.** KOReader's bundled MuPDF wrapper doesn't
  export a setter for ink-annotation geometry. The plugin itself patches **no core KOReader
  files** — it just needs a `libwrap-mupdf.so` that exports the two ink symbols. Drop in the
  prebuilt library (or rebuild for your KOReader version) from
  [`koreader-patches/`](koreader-patches/); without it the menu item explains what's missing
  and does nothing to your file.

## Features In the Pipeline

1. Handling changing canvas size

## Acknowledgements

Eraser end detection based on techniques from [eraser.koplugin](https://github.com/SimonLiu423/eraser.koplugin) by SimonLiu.

xoxo
