#!/bin/bash
# Builds libExactJPEGC.dylib and the C example against include/exact_jpeg.h, runs it on a synthetic JPEG and
# checks the decode is byte-identical to libjpeg-turbo (via ejm check-reencode).
set -euo pipefail
source "$(dirname "$0")/env.sh"
swift build -c release --product ExactJPEGC >/dev/null
swift build -c release --package-path Tools --product ejm >/dev/null
mkdir -p work/c
# a matched compiler + SDK pair from the selected developer directory (Xcode or Command Line Tools only)
DEV="$(xcode-select -p)"
SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"; [ -d "$SDK" ] || SDK="$DEV/SDKs/MacOSX.sdk"
CC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"; [ -x "$CC" ] || CC="$DEV/usr/bin/clang"
"$CC" -isysroot "$SDK" -O2 -Iinclude Examples/c/example.c -L.build/release -lExactJPEGC -Wl,-rpath,"$PWD/.build/release" -o work/c/example
Tools/.build/release/ejm write-synth-small work/c/in.jpg
rm -f work/c/out.jpg      # a stale out.jpg from an earlier run must not pass the check
work/c/example work/c/in.jpg work/c/out.jpg
Tools/.build/release/ejm check-reencode work/c/in.jpg work/c/out.jpg
