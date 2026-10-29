#!/usr/bin/env bash
# Run the plugin inside a local KOReader emulator build.
#
#   integration/run.sh test   # run integration specs in KOReader's test harness
#   integration/run.sh emu    # launch the emulator with the test book open
#
# KOREADER_DIR points at a KOReader checkout built with `./kodev build`
# (default: ../koreader-2026.07 next to this repo).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KOREADER_DIR="${KOREADER_DIR:-$(cd "$REPO_DIR/.." && pwd)/koreader-2026.07}"

if [[ ! -x "$KOREADER_DIR/kodev" ]]; then
    echo "No KOReader checkout at $KOREADER_DIR (set KOREADER_DIR)." >&2
    exit 1
fi

# KOReader's build needs Homebrew's GNU tools ahead of the macOS ones.
if command -v brew >/dev/null; then
    BREW="$(brew --prefix)"
    export PATH="$BREW/opt/findutils/libexec/gnubin:$BREW/opt/gnu-getopt/bin:$BREW/opt/make/libexec/gnubin:$BREW/opt/util-linux/bin:$PATH"
fi

# Link the plugin and the integration specs into the KOReader checkout.
ln -sfn "$REPO_DIR/pencil.koplugin" "$KOREADER_DIR/plugins/pencil.koplugin"
for spec in "$REPO_DIR"/integration/*_spec.lua; do
    ln -sf "$spec" "$KOREADER_DIR/spec/unit/$(basename "$spec")"
done

cd "$KOREADER_DIR"
case "${1:-test}" in
    test)
        names=()
        for spec in "$REPO_DIR"/integration/*_spec.lua; do
            names+=("$(basename "$spec" _spec.lua)")
        done
        ./kodev test front "${names[@]}"
        ;;
    emu)
        emu_dir="$(ls -d koreader-emulator-*/koreader | head -1)"
        # Emulator-only patches, e.g. making the mouse act as the stylus.
        mkdir -p "$emu_dir/patches"
        for patch in "$REPO_DIR"/integration/patches/*.lua; do
            ln -sf "$patch" "$emu_dir/patches/$(basename "$patch")"
        done
        # A test book: KOReader's own sample unless you've added your own.
        books="$PWD/$emu_dir/test-books"
        mkdir -p "$books"
        if ! ls "$books"/*.epub >/dev/null 2>&1 && [[ -f test/juliet.epub ]]; then
            cp test/juliet.epub "$books/"
        fi
        book="$(ls "$books"/*.epub 2>/dev/null | head -1)"
        # First launch only: turn Pencil and the features worth testing on.
        # KOReader rewrites this file on exit, so later changes made in the
        # emulator's menus are kept.
        settings="$emu_dir/settings.reader.lua"
        if [[ ! -f "$settings" ]]; then
            cat >"$settings" <<EOF
return {
    ["home_dir"] = "$books",
    ["pencil_annotation_enabled"] = true,
    ["pencil_annotation_settings"] = {
        ["experimental_bookmark_sync"] = true,
        ["experimental_text_highlight"] = true,
    },
    ["quickstart_shown_version"] = 999999999,
}
EOF
        fi
        # Half the Kobo Libra Colour's resolution, so the window fits a laptop.
        ./kodev run -W 632 -H 840 -D 150 ${book:+"$book"}
        ;;
    *)
        echo "usage: $0 [test|emu]" >&2
        exit 1
        ;;
esac
