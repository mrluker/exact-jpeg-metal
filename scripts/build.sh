#!/bin/bash
# Release build of the library and the C library (this package), and of the ejm tool (the Tools package,
# Tools/.build/release/ejm).
set -euo pipefail
source "$(dirname "$0")/env.sh"
swift build -c release
swift build -c release --package-path Tools
