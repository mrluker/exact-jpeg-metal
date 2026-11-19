#!/bin/bash
# Builds the Swift example (Examples/swift, a separate package that depends on this one by path), runs it on a
# synthetic JPEG and checks its re-encode is byte-identical to libjpeg-turbo (via ejm check-reencode).
set -euo pipefail
source "$(dirname "$0")/env.sh"
swift build -c release --package-path Tools --product ejm >/dev/null
swift build -c release --package-path Examples/swift >/dev/null
mkdir -p work/swift
Tools/.build/release/ejm write-synth-small work/swift/in.jpg
rm -f work/swift/out.jpg  # a stale out.jpg from an earlier run must not pass the check
Examples/swift/.build/release/swift-example work/swift/in.jpg work/swift/out.jpg
Tools/.build/release/ejm check-reencode work/swift/in.jpg work/swift/out.jpg
