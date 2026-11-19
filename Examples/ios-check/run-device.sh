#!/bin/bash
# Build the ExactJPEG Check app, install it on one iPhone, run it, and fetch its results JSON.
#   Examples/ios-check/run-device.sh [--timing-only | --decode-profile | --decode-ab | --load-routing] <device id>
#   Examples/ios-check/run-device.sh --public <dir> [<dir> ...] <device id>
# The device id is the CoreDevice identifier from `xcrun devicectl list devices` (or set EJM_IOS_DEVICE). Needs Xcode, XcodeGen, libjpeg-turbo from Homebrew (to
# export the corpus) and Config/Signing.local.xcconfig with your DEVELOPMENT_TEAM (see Config/Signing.xcconfig).
# Output: build/run-<date>.log (the app's stdout) and build/results/<results file>.json.
# Exit status: 0 only when the app finished and reported no failure (an empty "failures" array in its results JSON
# and no MISMATCH line in the log); 5 when it reported failures; 2-4 when it could not run or finish (2 also when the
# corpus export fails or refs.json is not from libjpeg-turbo 3.2.0). --timing-only, --decode-profile, --decode-ab and
# --load-routing run no exactness checks: they end with "no exactness checks in this mode" (exit 0 unless the app reported a failure).
# --public: `ejm public-bench`'s comparison on the phone. `ejm export-public` copies the public JPEG directories
# (public-bench's layout and SHA-256 checks) and libjpeg-turbo 3.2.0's references into Public/ (gitignored; exported
# again on every --public run; files it skips are listed and the rest are run), the app runs with --public, and the
# run ends with "no corpus exactness checks in this mode", still exiting 5 on any Metal decode or encode mismatch or
# invalid case (a timed call that failed). Every argument after --public up to the device id (a CoreDevice UUID)
# must be a directory: anything else stops with exit 2.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
mode=""
public_dirs=()
case "${1:-}" in
  --timing-only|--decode-profile|--decode-ab|--load-routing) mode="$1"; shift ;;
  --public)
    mode="$1"; shift
    # directories, then the device id as the last argument (a CoreDevice id, a UDID or a device name, as devicectl
    # accepts); every argument before it must be an existing directory, so a mistyped path is an error
    while [ $# -gt 1 ]; do
      if [ -d "$1" ]; then public_dirs+=("$(cd "$1" && pwd)"); shift
      else echo "--public: not a directory: $1" >&2; exit 2; fi
    done
    if [ $# -eq 1 ] && [ -d "$1" ]; then
      if [ -n "${EJM_IOS_DEVICE:-}" ]; then public_dirs+=("$(cd "$1" && pwd)"); shift   # device from the environment
      else echo "--public: the last argument must be the device id, not a directory: $1" >&2; exit 2; fi
    fi
    if [ ${#public_dirs[@]} -eq 0 ]; then echo "--public needs at least one directory of JPEGs" >&2; exit 2; fi ;;
esac
DEVICE="${1:-${EJM_IOS_DEVICE:-}}"
if [ -z "$DEVICE" ]; then
  echo "usage: run-device.sh [--timing-only | --decode-profile | --decode-ab | --load-routing] <device id>   (ids: xcrun devicectl list devices)" >&2
  echo "       run-device.sh --public <dir> [<dir> ...] <device id>" >&2; exit 2
fi
BUNDLE=com.lukeriley.ExactJPEGCheck
cd "$here"
mkdir -p build/results

say_unreachable() {
  echo "The device $DEVICE is not reachable. Check that it is:"
  echo "  - unlocked, with the screen on (devicectl cannot launch an app on a locked phone)"
  echo "  - on the same network as this Mac (or connected by cable), and paired: xcrun devicectl list devices"
  echo "  - in Developer Mode (Settings > Privacy & Security > Developer Mode)"
  echo "If the app installed but will not launch: Settings > General > VPN & Device Management, trust the developer."
}

state="$(xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE" || true)"
if [ -z "$state" ] || ! grep -q "available" <<< "$state" || grep -q "unavailable" <<< "$state"; then
  echo "device state: ${state:-not listed}"; say_unreachable; exit 2
fi

# 1. the decoder corpus, timing inputs and libjpeg-turbo references (generated on this Mac, never committed):
# exported again when missing, when refs.json's reference is not libjpeg-turbo 3.2.0, or when the corpus or refs.json
# is older than the ejm binary (built here first) or the manifest. ejm refuses to write refs.json with another
# libjpeg-turbo than 3.2.0.
want_ref="libjpeg-turbo 3.2.0"
( source "$repo/scripts/env.sh"; swift build -c release --package-path Tools --product ejm >/dev/null )
ejm="$repo/Tools/.build/release/ejm"
manifest="$repo/testdata/manifest-libjpeg-turbo-3.2.0.json"
refs_ref() { plutil -extract reference raw -o - Corpus/refs.json 2>/dev/null || echo missing; }
why=""
if [ ! -f Corpus/bench/bench.json ] || [ ! -f Corpus/refs.json ]; then why="missing"
elif [ "$(refs_ref)" != "$want_ref" ]; then why="refs.json reference is $(refs_ref)"
elif [ "$ejm" -nt Corpus/refs.json ] || [ "$ejm" -nt Corpus/bench/bench.json ]; then why="older than the ejm binary"
elif [ "$manifest" -nt Corpus/refs.json ] || [ "$manifest" -nt Corpus/bench/bench.json ]; then why="older than the manifest"
fi
if [ -n "$why" ]; then
  echo "== exporting the corpus ($why)"
  ( source "$repo/scripts/env.sh"; "$ejm" export-corpus "$here/Corpus" ) || { echo "FAIL: ejm export-corpus failed"; exit 2; }
fi
[ "$(refs_ref)" = "$want_ref" ] || { echo "FAIL: Corpus/refs.json reference is $(refs_ref), not $want_ref"; exit 2; }
echo "corpus: $(du -sh Corpus | cut -f1), references: $(refs_ref)"

# 1b. the public JPEGs for --public (never committed): exported on every --public run (ejm export-public empties
# Public/ first and refuses to write public-refs.json with another libjpeg-turbo than 3.2.0); in the other modes
# Public/ only has to exist for the build
mkdir -p Public
if [ "$mode" = "--public" ]; then
  echo "== exporting the public JPEGs: ${public_dirs[*]}"
  st=0; ( source "$repo/scripts/env.sh"; "$ejm" export-public "$here/Public" "${public_dirs[@]}" ) || st=$?
  if [ "$st" = 3 ]; then echo "WARNING: ejm export-public skipped the files listed above; the others are bundled"
  elif [ "$st" != 0 ]; then echo "FAIL: ejm export-public failed (exit $st)"; exit 2; fi
  pub_ref="$(plutil -extract reference raw -o - Public/public-refs.json 2>/dev/null || echo missing)"
  [ "$pub_ref" = "$want_ref" ] || { echo "FAIL: Public/public-refs.json reference is $pub_ref, not $want_ref"; exit 2; }
  echo "public export: $(du -sh Public | cut -f1), references: $pub_ref"
elif [ -n "$(ls -A Public)" ]; then
  echo "note: Public/ ($(du -sh Public | cut -f1)) is bundled too; delete it for a smaller install"
fi

# xcodebuild names the device by its hardware UDID, devicectl by its CoreDevice identifier
udid="$(xcrun devicectl device info details --device "$DEVICE" 2>/dev/null | sed -nE 's/.*udid: ([0-9A-Fa-f-]+).*/\1/p' | head -1)"
[ -n "$udid" ] || { echo "cannot read the UDID of $DEVICE"; say_unreachable; exit 2; }

# 2. project, build (Release: the synthetic generators are slow unoptimised)
echo "== xcodegen"; xcodegen generate --quiet
echo "== build"
xcodebuild -project ExactJPEGCheck.xcodeproj -scheme ExactJPEGCheck -configuration Release \
  -destination "id=$udid" -derivedDataPath build/dd -allowProvisioningUpdates build -quiet
app="build/dd/Build/Products/Release-iphoneos/ExactJPEGCheck.app"
echo "app: $(du -sh "$app" | cut -f1) ($app)"

# 3. install, launch with the console attached (the app exits when done with --exit)
echo "== install"; xcrun devicectl device install app --device "$DEVICE" "$app" >/dev/null
log="build/run-$(date +%Y%m%d-%H%M%S)${mode:+-${mode#--}}.log"
echo "== run (log: $here/$log)"
if ! xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing "$BUNDLE" --exit $mode 2>&1 | tee "$log"; then
  if grep -q "Locked" "$log"; then echo "The phone is locked: unlock it, keep the screen on and run this again."
  else echo "launch failed"; say_unreachable; fi
  exit 3
fi

# 4. fetch the results JSON from the app's Documents
file="$(grep -o 'RESULTS_FILE [^ ]*json' "$log" | tail -1 | cut -d' ' -f2 || true)"
[ -n "$file" ] || { echo "no RESULTS_FILE line in $log (the app did not finish)"; exit 4; }
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source "Documents/$file" --destination "build/results/$file" >/dev/null
echo "== summary ($here/build/results/$file)"
grep -E '^(decoder|encoder|formats|api |decode |encode |timing thermal|failures|total|  MISMATCH|profile|ab |load wiring|lr |pub |public |  [a-z])' "$log" || true

# 5. the verdict: the results JSON's failures array (fail() in App/Runner.swift appends to it) and the log's MISMATCH
# lines must both be empty
nfail="$(plutil -extract failures raw -o - "build/results/$file" 2>/dev/null || echo missing)"
nmis="$(grep -c '^  MISMATCH' "$log" || true)"
if [ "$nfail" = "missing" ]; then echo "FAIL: no failures array in build/results/$file"; exit 5; fi
if [ "$nfail" != "0" ] || [ "$nmis" != "0" ]; then
  echo "FAIL: the app reported $nfail failures ($nmis MISMATCH lines in $log)"; exit 5
fi
# --public: a timed call that failed makes its case invalid (public.summary.invalid_cases): not a result
if [ "$mode" = "--public" ]; then
  ninv="$(plutil -extract public.summary.invalid_cases raw -o - "build/results/$file" 2>/dev/null || echo missing)"
  if [ "$ninv" != "0" ]; then echo "FAIL: $ninv invalid cases (failed timed calls; 'public invalid cases' in $log)"; exit 5; fi
fi
if [ "$mode" = "--public" ]; then
  echo "no corpus exactness checks in this mode (--public); Metal decode and encode of the public files: no mismatch"
elif [ -n "$mode" ]; then
  echo "no exactness checks in this mode ($mode); run without it for the device check"
else
  echo "device check passed: 0 failures"
fi
