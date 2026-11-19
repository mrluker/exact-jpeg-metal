# Sourced by the other scripts: finds Homebrew's libjpeg-turbo (the reference for the tests and benchmarks, linked
# by the ejm tool in Tools/Package.swift). The library itself (Package.swift) needs nothing but SwiftPM and the
# Command Line Tools (shaders compile at run time).
JT="$(brew --prefix jpeg-turbo 2>/dev/null || true)"
if [ -z "$JT" ] || [ ! -f "$JT/lib/pkgconfig/libjpeg.pc" ]; then
  echo "libjpeg-turbo not found: brew install jpeg-turbo pkg-config" >&2; exit 1
fi
export PKG_CONFIG_PATH="$JT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
