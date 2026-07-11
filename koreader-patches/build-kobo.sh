#!/usr/bin/env bash
#
# Build a Kobo (arm-kobo-linux-gnueabihf) libwrap-mupdf.so with pencil's
# ink-annotation support, using KOReader's official cross-build image.
#
# This reproduces the binary shipped in prebuilt/libwrap-mupdf.so. Run it if you
# want to build against a *specific* koreader-base revision (recommended: check
# out the same one your installed KOReader ships, so the .so matches your device
# — see README.md "Matching your KOReader version").
#
# Requirements: Docker. On Apple Silicon the amd64 image runs under emulation,
# so the MuPDF compile takes a while (~10 min on an M-series Mac).
#
# Usage:
#   ./build-kobo.sh                 # clones koreader-base master into ./_build
#   KOBASE=/path/to/koreader-base ./build-kobo.sh   # use an existing checkout
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch="$here/koreader-base/ink-annotation.patch"
image="koreader/kokobo:latest"
tc="/usr/local/x-tools/arm-kobo-linux-gnueabihf/bin"

KOBASE="${KOBASE:-$here/_build/koreader-base}"
if [ ! -d "$KOBASE" ]; then
    echo ">> cloning koreader-base into $KOBASE"
    mkdir -p "$(dirname "$KOBASE")"
    git clone --depth 1 https://github.com/koreader/koreader-base.git "$KOBASE"
fi

echo ">> applying ink-annotation.patch (idempotent)"
if git -C "$KOBASE" apply --check "$patch" 2>/dev/null; then
    git -C "$KOBASE" apply "$patch"
elif git -C "$KOBASE" apply --reverse --check "$patch" 2>/dev/null; then
    echo "   already applied, skipping"
else
    echo "   WARNING: patch does not apply cleanly to this koreader-base revision."
    echo "   Apply the two MUPDF_WRAP entries / cdecls / ffi methods by hand"
    echo "   (see the patch), then re-run with the apply step removed."
    exit 1
fi

echo ">> pulling $image"
docker pull --platform linux/amd64 "$image"

echo ">> building mupdf + wrap-mupdf for TARGET=kobo (under emulation, be patient)"
docker run --rm --platform linux/amd64 \
    -v "$KOBASE":/kb -w /kb \
    -e CCACHE_DIR=/kb/.ccache -e PARALLEL_JOBS="${PARALLEL_JOBS:-4}" \
    -e PATH="$tc:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$image" \
    bash -c 'set -e; make TARGET=kobo fetchthirdparty; make TARGET=kobo mupdf; make TARGET=kobo wrap-mupdf'

so="$KOBASE/build/arm-kobo-linux-gnueabihf/libs/libwrap-mupdf.so"
echo ">> built: $so"
file "$so"
cp "$so" "$here/prebuilt/libwrap-mupdf.so"
echo ">> copied to $here/prebuilt/libwrap-mupdf.so"
