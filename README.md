# pencil.koplugin

[![Latest release](https://img.shields.io/github/v/release/mysticknits/pencil.koplugin?style=for-the-badge&label=Latest%20release)](https://github.com/mysticknits/pencil.koplugin/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/mysticknits/pencil.koplugin/total?style=for-the-badge&label=Downloads)](https://github.com/mysticknits/pencil.koplugin/releases)
[![Support me on Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20my%20work-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/mysticknitscodes)

## Information

This has been tested on:

- Kobo Libra Colour/Kobo Stylus 2/Epub format
- Android (experimental): Boox Note Max, KOReader nightly 2026.07.2-280, Boox pen, EPUB in portrait, PDF in portrait and landscape. See [Installing on Android](#installing-on-android) for what works and what doesn't yet.

**Kobo is the supported platform. Android support is experimental; other Android e-readers and tablets with a stylus (Boox, Samsung S Pen, ...) will be listed as people report back.**

If you change the font size or margins after writing, your annotations will be WONKY. This is something I will eventually address but for now, get your book set before you start writing.

Rotating the device is handled: annotations written in the other orientation show as a small badge, and tapping the badge opens a saved picture of what you wrote.

**Interested in helping maintain Pencil?** See [Looking for maintainers](#looking-for-maintainers).

### Requires KOReader 2026.07 "Sailing Walrus" or newer

## Features

- **Pen tip**: Draw annotations on your ebooks
- **Eraser end**: Flip your stylus over to erase strokes instantly. It also removes KOReader text highlights it touches
- **Highlighter**: Hold the stylus side button and drag to draw a highlighter stroke (or a KOReader text highlight, with the experimental option below); tap the side button to toggle pencil/eraser
- **Swap Eraser/Highlighter**: Reassign which side button acts as eraser vs. highlighter from the menu
- **Undo**: Undo your last stroke or eraser action
- **Clear strokes**: Clear annotations for the current page or the entire document
- **Annotation grouping**: Strokes are automatically grouped into logical annotations based on timing and proximity
- **Enable/disable toggle**: Turn the plugin on or off via the menu or a mapped gesture
- **Per-document storage**: Annotations are saved with each book
- **Annotation previews**: A picture of each annotation is saved, so it can be shown after rotating the device or from the Bookmarks menu. The Pencil menu shows how much space they use and can clear them for the current book
- **Input debug mode**: Log raw stylus events to help diagnose detection issues

## Instructions for Installation

[![Download pencil.koplugin.zip](https://img.shields.io/badge/Download-pencil.koplugin.zip-2ea44f?style=for-the-badge&logo=github)](https://github.com/mysticknits/pencil.koplugin/releases/latest/download/pencil.koplugin.zip)

1. Make sure you are running KOReader 2026.07 or newer. The stylus input support this plugin needs is built into KOReader from that release on, so no KOReader files need to be replaced.
2. Download [`pencil.koplugin.zip`](https://github.com/mysticknits/pencil.koplugin/releases/latest/download/pencil.koplugin.zip) from the latest release.
3. Unzip it. You'll get a `pencil.koplugin` folder.
4. Copy the `pencil.koplugin` folder into KOReader's `plugins` folder:
   - Kobo: `.adds/koreader/plugins/pencil.koplugin/`
   - Android: `koreader/plugins/pencil.koplugin/` in the device's shared storage (`/sdcard/koreader/plugins/`). See [Installing on Android](#installing-on-android).
5. Restart KOReader, then turn Pencil on (see below).

What changed in each version is on the [releases page](https://github.com/mysticknits/pencil.koplugin/releases).

### Installing on Android

Android support is experimental. The plugin's own code is the same on every device; a small Android-only module (`android_fastblit.lua`) loads only there.

**KOReader version.** The stable 2026.07.1 Android build does not tell the plugin whether a touch came from the pen, a finger or the eraser, so Pencil cannot work on it. You need an Android **nightly** from 2026.07.2-280 or later ([build.koreader.rocks/download/nightly](https://build.koreader.rocks/download/nightly/)), which includes [koreader-base#2501](https://github.com/koreader/koreader-base/pull/2501). Check Help > About in KOReader.

**Plugin folder.** KOReader on Android reads user plugins from `koreader/plugins/` in shared storage, which is `/sdcard/koreader/plugins/` on most devices. Copy the `pencil.koplugin` folder there, so you end up with `/sdcard/koreader/plugins/pencil.koplugin/main.lua`.

**Over adb.** With USB or wireless debugging enabled, `./install-android.sh` from a checkout of this repository pushes the plugin folder for you and prints the installed KOReader version first. Pass an adb serial or `host:port` as the only argument if more than one device is connected.

**Boox unzip quirk.** Boox's built-in file manager flattens the zip when extracting, dropping the `lib/` folder so `geometry.lua` ends up next to `main.lua`. The plugin tolerates that layout, so extracting with the Boox file manager is fine. Any other unzip app keeps the folder structure.

**What works and what doesn't.** Tested so far on a Boox Note Max (13.3", monochrome) with the Boox pen, KOReader nightly 2026.07.2-280, an EPUB in portrait and a PDF in portrait and landscape:

- Pen tip draws and strokes are saved and restored, in both orientations on the PDF and in portrait on the EPUB. With the normal refresh the ink shows about a second behind the pen: KOReader draws it in software and every update goes through Android's window compositor and an e-ink waveform. With [Android fast refresh](#android-fast-refresh) on, the timing readout puts each screen update at about 25 ms, so the ink trails the pen by well under a tenth of a second.
- Rotating: strokes written in the other orientation collapse to a badge, as documented above. Seen on the Note Max: once you write something in the new orientation, the badges on that page are dropped and the other orientation's strokes are drawn as-is, in the wrong place, until you rotate back. That comes from the shared paint code, not the Android module, and has not been checked on a Kobo.
- The stylus side button is invisible to KOReader on the Note Max: the Android input layer passes only the pen and eraser tool types, never button events, and the Boox pen reports the button as neither. So the side-button highlighter and the pen-to-eraser toggle do not work there.
- Not tested yet: the eraser end (the Boox pen has none, so no pen with one has been tried), EPUB in landscape, colour panels, other devices.

If you try it on another Android device, please report the device, the KOReader version and what you saw in [issue #15](https://github.com/mysticknits/pencil.koplugin/issues/15).

### Trying a pre-release

Before each release, a test version comes out first, marked **Pre-release** on the [releases page](https://github.com/mysticknits/pencil.koplugin/releases), with a tag like `0.6.0-beta.1`. Install it the same way, using the `pencil.koplugin.zip` attached to that pre-release. The download button above always gets the latest stable release, never a pre-release.

Pre-releases can have bugs, so back up the `.sdr` folders of books you've written in first. If something goes wrong, please [open an issue](https://github.com/mysticknits/pencil.koplugin/issues) and mention the pre-release you're on. Testing them is one of the most helpful things you can do for Pencil!

### Upgrading from an older version of this plugin

Earlier releases of this plugin required replacing KOReader's `/frontend/device/input.lua` with a modified copy. That is no longer needed. Updating KOReader to 2026.07 or newer installs a fresh `input.lua`, which replaces the modified one.

### Older KOReader versions

If you can't update KOReader, use [release 0.5.0](https://github.com/mysticknits/pencil.koplugin/releases/tag/0.5.0) or earlier. Those releases include the `input.lua` file and installation instructions for KOReader 2026.03 "Snowflake".

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
If you're experiencing issues with the plugin, please enable input debug mode in the Pencil menu, reproduce the issue, and include the debug log file in your issue report. On a Kobo the log is at `.adds/koreader/pencil_input_debug.log`, and **Clear debug log** in the Pencil menu starts a fresh one.

## Experimental Features

Some features are still in development and are hidden behind an experimental toggle. You can find them under **Pencil menu > Experimental**.

### Color picker

When enabled, holding the pen still on the page opens a picker with 10 color options. When disabled, the pen stays on its last-saved color.

**To enable:** Pencil menu > Experimental > Color picker

### Pen width picker

When enabled, the picker also shows pen width options (3, 5, 7, 9), rendered as black bars whose height previews the stroke thickness. **Requires the color picker to also be enabled.**

**To enable:** Pencil menu > Experimental > Pen width picker

### Text highlight (side button)

When enabled, holding the stylus side button while dragging across words creates a KOReader text highlight, like long-pressing and choosing Highlight. When disabled, the side button draws a freehand highlighter stroke instead.

**To enable:** Pencil menu > Experimental > Text highlight (side button)

### Android fast refresh

Android only. While drawing, Pencil updates only the stroke's rectangle of the screen instead of copying the whole screen buffer to Android's window on every refresh, which is what makes the ink lag on large panels. It uses KOReader internals that may change between releases, so it is off by default; if it fails mid-session, Pencil retries on the next stroke; after three failures in a row it shows a notice and uses the normal refresh until you toggle the option again, and the timing readout names the reason. The same submenu lets you choose how often the e-ink controller repaints during a stroke, and has a timing readout that shows after each stroke how long input handling and screen updates took, for lag and rotation bug reports.

**To enable:** Pencil menu > Experimental > Android fast refresh

### Bookmark Sync

When enabled, the plugin automatically groups your pencil strokes into logical annotations (based on timing and proximity) and creates KOReader bookmarks for each one. This means annotated pages show up in the **Bookmarks menu**, so you can quickly navigate back to pages you've written on.

**To enable:** Pencil menu > Experimental > Bookmark sync

**What happens when you turn it on:**
- Existing pencil annotations are grouped and bookmarks are created immediately
- New strokes are grouped and bookmarked as you draw
- Bookmarks appear in KOReader's Bookmarks menu as "Pencil annotation on page X". Long-press one to see a picture of the annotation
- Annotated pages show KOReader's folded page corner
- Erasing or undoing strokes updates the bookmarks and the page corner automatically

**What happens when you turn it off:**
- All pencil bookmarks are removed from the Bookmarks menu
- Your pencil strokes and drawings are not affected — only the bookmarks are removed
- Annotation groups are still tracked internally, so you won't lose any grouping data if you turn it back on

## Features In the Pipeline

1. Export of annotations
2. Keeping annotations in place when the font size or margins change

## Contributing

Contributions are welcome. Please open a pull request against `main`. Nothing in this section affects installing the plugin: only the `pencil.koplugin` folder is copied to a device.

### Looking for maintainers

I'd love help keeping Pencil going. A lot of good work is happening in forks, and I'd rather bring it together here. If you'd like to be an active maintainer, reviewing pull requests, triaging issues, or testing on devices I don't have, please [open an issue](https://github.com/mysticknits/pencil.koplugin/issues/new?title=Maintainer%20interest) and tell me a little about yourself, your device and what you'd like to work on.

### Unit tests

The specs in `spec/` stub out KOReader and run with [busted](https://lunarmodules.github.io/busted/). CI runs them on every pull request.

```
luarocks install busted
busted spec
```

### Integration tests and the emulator

To test against real KOReader without a device, build KOReader's desktop emulator. The `integration/` folder has a script that links your working copy of the plugin into it:

```
integration/run.sh test   # run integration tests inside KOReader's test harness
integration/run.sh emu    # open the emulator with a test book
```

In the emulator, the mouse acts as the stylus. Hold E while dragging to use the eraser end, and hold H to use the side button. Clicks near the top or bottom edge open KOReader's menus.

See [integration/README.md](integration/README.md) for the one-time setup and more detail. These tests need a local emulator build, so CI doesn't run them. Please run them before opening a pull request that touches drawing, erasing or bookmarks.

### Releases and pre-releases

Every release goes out as a pre-release first, so people can try it on their devices before it reaches everyone:

1. On the [releases page](https://github.com/mysticknits/pencil.koplugin/releases), draft a new release from `main` with a tag like `0.6.0-beta.1`, tick **Set as a pre-release**, and publish it. The Release zip workflow attaches `pencil.koplugin.zip` automatically.
2. Ask for testers: comment on the issues it fixes, and mention anyone who has offered to test on their device.
3. Fix what comes up and publish `0.6.0-beta.2`, and so on.
4. When a beta has held up, publish `0.6.0` from the same commit as a normal release. Its notes should thank the contributors and testers.

Pre-releases never count as the latest release, so the README's download button keeps pointing at the last stable one.

## Support Pencil ☕

Pencil is a labour of love, made in my spare time with plenty of coffee and a good dose of stubbornness. If it's made your reading a little more joyful and you'd like to support my work, please consider [buying me a coffee on Ko-fi](https://ko-fi.com/mysticknitscodes)! 💛

Every coffee helps keep Pencil growing. And if donating isn't your thing, starring the repo, reporting a bug or telling a fellow reader about it means the world to me too! ✨

[![Support me on Ko-fi](https://img.shields.io/badge/Ko--fi-Buy%20me%20a%20coffee-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/mysticknitscodes)

## Acknowledgements

Eraser end detection based on techniques from [eraser.koplugin](https://github.com/SimonLiu423/eraser.koplugin) by SimonLiu.

xoxo
