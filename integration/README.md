# Integration tests and emulator

The specs in `spec/` stub out KOReader and run with plain `busted`. The specs here run inside KOReader's own test harness, against a real reader and EPUB. They need a local KOReader emulator build, so CI doesn't run them.

## One-time setup (macOS)

1. Install KOReader's build tools, following its [build guide](https://github.com/koreader/koreader/blob/master/doc/Building.md):

   ```
   brew install autoconf automake bash binutils cmake coreutils findutils \
       gettext gnu-getopt libtool make meson nasm ninja pkgconf sdl3 util-linux
   ```

2. Clone KOReader next to this repo and build the emulator:

   ```
   git clone --depth 1 --branch v2026.07.1 https://github.com/koreader/koreader.git ../koreader-2026.07
   cd ../koreader-2026.07 && ./kodev build
   ```

   Run `./kodev build` with Homebrew's GNU tools first on your `PATH`, as the build guide describes. `run.sh` sets this up for later runs.

## Running

```
integration/run.sh test   # run the integration specs
integration/run.sh emu    # open the emulator with the test book
```

Both commands link this repo's plugin into the KOReader checkout, so they always use your working copy. Set `KOREADER_DIR` if your checkout lives somewhere else.

On its first launch, `run.sh emu` turns on Pencil, bookmark sync and text highlight in the emulator's settings. It also opens KOReader's sample book, unless you've put your own EPUB in the emulator's `test-books` folder. Settings you change in the emulator's menus are kept between launches.

In the emulator the mouse acts as the pen, so dragging draws ink. `run.sh emu` installs a small emulator-only patch from `integration/patches/` that sends mouse input through KOReader's stylus path, the same low-latency path the pen uses on a Kobo. Without it, mouse ink only appears after you let go.

Clicks that start in the top or bottom eighth of the screen still act as a finger, so they open KOReader's top menu and settings menu as on a device. Everywhere else the mouse draws. Turn pages with the arrow keys.

Two keys stand in for the stylus buttons:

| Key | Kobo stylus | Use |
|---|---|---|
| E | Eraser end | Hold while dragging to erase |
| H | Side button | Hold while dragging to highlight, or tap to toggle pencil and eraser |

They go through the same button handling as on a Kobo, including the swap eraser and highlighter setting. In the emulator those keys no longer type the letters E and H. The emulator's settings and `test-books` folder live in its `koreader` folder inside the build directory.
