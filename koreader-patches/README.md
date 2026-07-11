# Ink-annotation support for "Save annotations to PDF"

The Pencil plugin's **Save annotations to PDF (this page)** feature (issue #63) writes
pencil strokes into the PDF file as native ink annotations (`/Subtype /Ink`), so they travel
with the file and are visible/removable in any PDF reader.

## What the plugin needs (and what it doesn't)

The plugin is **self-contained**: it talks to koreader-base's MuPDF wrapper directly and
declares its own FFI prototypes at runtime, so it patches **no core KOReader Lua files**
(`ffi/mupdf.lua`, `ffi/mupdf_h.lua`, and `frontend/document/pdfdocument.lua` are left
untouched). See the `InkAnnot` block and `Pencil:writeInkAnnotation` in
`pencil.koplugin/main.lua`.

The one thing Lua cannot provide is a **C symbol**. KOReader's shipped `libwrap-mupdf.so`
does not export a wrapper for `pdf_set_annot_ink_list` / `pdf_set_annot_border_width`, so the
feature needs a `libwrap-mupdf.so` that exports those two. When it's absent the plugin
detects that and the menu item explains what's missing — nothing else breaks.

## What's here

| Path | What it is |
|------|------------|
| `prebuilt/libwrap-mupdf.so` | **Prebuilt** Kobo (`arm-kobo-linux-gnueabihf`) wrapper with ink support. Built against **koreader-base @ v2026.03 pin / MuPDF 1.26.12** — matches current stable KOReader for Kobo. `ELF 32-bit ARM, EABI5, stripped`. |
| `koreader-base/ink-annotation.patch` | The source change that adds ink support to koreader-base: two `MUPDF_WRAP` entries in `wrap-mupdf.h`, their `cdecl_func` entries, and (as the proper upstream API) `page_mt.__index:addInkAnnotation` + its cdecls. **The plugin only needs the two `wrap-mupdf.h` symbols**; the Lua parts are there so this doubles as a clean koreader-base PR. |
| `build-kobo.sh` | Reproduces `prebuilt/libwrap-mupdf.so` via the official `koreader/kokobo` Docker image. |

## Install (Kobo)

1. Install the plugin as usual (copy `pencil.koplugin`, `input.lua`).
2. Back up and replace the wrapper library:
   `/mnt/onboard/.adds/koreader/libs/libwrap-mupdf.so` ← `prebuilt/libwrap-mupdf.so`.
3. Restart KOReader. In a PDF: draw, then **Pencil menu > Experimental > Save annotations to
   PDF (this page)**.

That's it — no Lua files to overwrite.

## Match your KOReader version

The `.so` statically links MuPDF, so it's a self-contained superset of the stock wrapper and
is normally a safe drop-in. But it must be built against the **same MuPDF version** your
KOReader ships (struct layouts change between MuPDF releases). The prebuilt targets **v2026.03
/ MuPDF 1.26.12**. For a different release, find the koreader-base revision it pins and rebuild:

```sh
KOBASE=/path/to/that/koreader-base ./build-kobo.sh
```

On Apple Silicon the `koreader/kokobo` image runs under emulation (the MuPDF compile is
~10 min). The script applies `ink-annotation.patch`, cross-builds, and drops a fresh
`libwrap-mupdf.so` into `prebuilt/`.

## The real fix: upstream it

The clean long-term answer is to land `ink-annotation.patch` in **koreader-base**. Once
merged, every KOReader release ships a wrapper that already exports the ink symbols, and the
plugin's PDF export works with **no extra install step at all**.

## Verify on-device

- **It loads:** after swapping the `.so`, open a PDF — if KOReader starts and renders PDFs
  normally, the wrapper's existing symbols still resolve.
- **Ink writes:** draw + save, then reopen the PDF in KOReader *and* a desktop viewer
  (Xournal++, Okular, Acrobat). Strokes should be selectable/removable ink annotations at the
  right positions, colors, and widths.
- **Orientation:** the markup (quad-point) path passes KOReader page coordinates straight to
  MuPDF and renders correctly, and the ink path uses the same page space — so no Y-flip is
  expected. If ink comes out **vertically mirrored**, flip Y against the page height in
  `Pencil:writeInkAnnotation` before filling the vertex array.
