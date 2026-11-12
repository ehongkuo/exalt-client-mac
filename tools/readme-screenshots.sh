#!/bin/zsh -f
# Regenerates the README screenshots in docs/ from real app windows fed by synthetic data
# (tests/ui_fixture.c); never touches the game. Needs Screen Recording permission for the
# terminal. Leave the Mac alone while it runs: a window that leaves the screen is retried.
# Usage: tools/readme-screenshots.sh
set -eu
src="${0:A:h:h}"
work="$(mktemp -d)"
app="$work/UITest.app/Contents/MacOS/UITest"
mkdir -p "${app:h}"
clang -O2 "$src/tests/ui_fixture.c" -o "$work/ui-fixture"
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path "$src/module-cache" -D GUARD_UI_TEST \
    -import-objc-header "$src/app/GuardBridge.h" "$src/app/GuardModel.swift" "$src/app/GuardLaunch.swift" \
    "$src/app/GuardExport.swift" "$src/app/GuardDrops.swift" "$src/app/GuardApp.swift" -o "$app"
# Lists a process's on-screen windows as "id width height".
cat > "$work/winid.swift" <<'EOF'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, b["Width"]!, b["Height"]!)
}
EOF
xcrun swiftc -O -module-cache-path "$src/module-cache" "$work/winid.swift" -o "$work/winid"
# The test app keeps its window frames in the UITest defaults; restore them afterwards.
defaults export UITest "$work/defaults.plist" 2>/dev/null || true
trap 'defaults import UITest "$work/defaults.plist" 2>/dev/null || defaults delete UITest 2>/dev/null; rm -rf "$work"' EXIT

# capture NAME HEIGHT SETTLE WIDTH FIXTURE [ENV...]: window HEIGHT points tall; captures the
# window WIDTH points wide SETTLE seconds after it appears; FIXTURE=1 feeds a live game.
capture() {
    local name=$1 height=$2 settle=$3 width=$4 fixture=$5 writer= id= i; shift 5
    defaults write UITest "NSWindow Frame ExaltClientMacMain" "526 40 460 $height 0 0 1512 949 "
    rm -f "$work/live.bin"
    if (( fixture )); then GUARD_UI_DEATH=1 "$work/ui-fixture" "$work/live.bin" 30 & writer=$!; sleep 0.3; fi
    env GUARD_LIVE_FILE="$work/live.bin" GUARD_SETTINGS_FILE="$work/settings.conf" GUARD_DATA_DIR="$work" "$@" \
        "$app" >/dev/null 2>&1 &
    local pid=$! ok=0
    for i in {1..100}; do
        id=$("$work/winid" $pid | awk -v w=$width '$2==w{print $1; exit}'); [[ -n $id ]] && break; sleep 0.1
    done
    sleep $settle
    [[ -n $id ]] && screencapture -x -l$id "$src/docs/$name.png" 2>/dev/null && ok=1
    kill $pid 2>/dev/null; [[ -n $writer ]] && kill $writer 2>/dev/null; wait 2>/dev/null || true
    (( ok ))
}
shot() { local k; for k in {1..8}; do capture "$@" && { print "docs/$1.png"; return; }; sleep 1; done; print "FAILED: $1"; return 1; }
shot full-view 528 1.0 460 1
shot full-view-more 900 1.0 460 1 GUARD_OPEN_MORE=1
shot start-view 492 1.0 460 0
shot compact-strip 528 1.0 340 1 GUARD_AUTO_COMPACT=1
shot join-popup 528 0.6 380 1
