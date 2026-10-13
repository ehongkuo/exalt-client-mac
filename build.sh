#!/bin/zsh
# Runs the tests, then builds the guard and Exalt Client Mac.app into build/ and installs the
# app to ~/Applications.
# Usage: work/exalt-guard/build.sh            (tests + build)
#        work/exalt-guard/build.sh --test-only
set -eu
src="${0:A:h}"
out="$src/build"
cache="$src/module-cache"
app="$out/Exalt Client Mac.app"
installed="$HOME/Applications/Exalt Client Mac.app"
data="$HOME/Library/Application Support/Exalt Client Mac"
mkdir -p "$cache"

print '== Tests'
clang -Wall -Wextra -Werror "$src/core_tests.c" -o "$src/core-tests" && "$src/core-tests"
clang -O2 -Wall -Wextra -Werror "$src/live_tests.c" -o "$src/live-tests" && "$src/live-tests"
clang -arch x86_64 -O2 -Wall -Wextra -Werror "$src/live_tests.c" -o "$src/live-tests-x86" && "$src/live-tests-x86"
clang -arch x86_64 -O2 -Wall -Wextra -Werror "$src/live_cross.c" -o "$src/live-cross-x86"
clang -arch arm64 -O2 -Wall -Wextra -Werror "$src/live_cross.c" -o "$src/live-cross-arm64"
cross="$(mktemp -d)/live.bin"
"$src/live-cross-x86" write "$cross" &
until [[ -s "$cross" ]]; do :; done
"$src/live-cross-arm64" read "$cross"; wait; rm -f "$cross"
xcrun swiftc -module-cache-path "$cache" -warnings-as-errors -import-objc-header "$src/app/GuardBridge.h" \
    "$src/app/GuardModel.swift" "$src/app/GuardLaunch.swift" "$src/app/GuardModelTests.swift" \
    "$src/app/GuardSettingsTests.swift" "$src/app/GuardLaunchTests.swift" \
    -o "$src/model-tests" && "$src/model-tests"
python3 "$src/test_guard.py"
# UI regression: switching to the compact strip and back must not quit the app (it briefly
# shows its window, fed by a synthetic writer; never touches the game).
ui="$(mktemp -d)"
mkdir -p "$ui/UITest.app/Contents/MacOS"
clang -O2 -Wall -Wextra -Werror "$src/ui_fixture.c" -o "$ui/ui-fixture"
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path "$cache" -warnings-as-errors -D GUARD_UI_TEST \
    -import-objc-header "$src/app/GuardBridge.h" "$src/app/GuardModel.swift" "$src/app/GuardLaunch.swift" \
    "$src/app/GuardApp.swift" -o "$ui/UITest.app/Contents/MacOS/UITest"
"$ui/ui-fixture" "$ui/live.bin" 8 &
writer=$!   # pids get their own names: $app is the app bundle path
sleep 0.5
GUARD_LIVE_FILE="$ui/live.bin" GUARD_SETTINGS_FILE="$ui/settings.conf" GUARD_AUTO_COMPACT=1 \
    "$ui/UITest.app/Contents/MacOS/UITest" >/dev/null 2>&1 &
ui_pid=$!
sleep 6
if ! kill -0 $ui_pid 2>/dev/null; then print 'FAIL: the app quit when switching to compact'; kill $writer; exit 1; fi
kill $ui_pid; wait $ui_pid 2>/dev/null || true; kill $writer 2>/dev/null || true; wait 2>/dev/null || true
rm -rf "$ui"
print 'Compact switch UI test passed'
[[ "${1:-}" == --test-only ]] && { print 'Tests passed.'; exit 0; }

# Never overwrite a dylib the game has loaded, or a running app executable.
if pgrep -x RotMGExalt >/dev/null || pgrep -x ExaltClientMac >/dev/null || pgrep -xf '.*RotMG Exalt Launcher' >/dev/null; then
    print 'Quit the game, DECA'"'"'s launcher and Exalt Client Mac first, then run this again.'
    exit 1
fi

print '== Build guard (Intel, runs inside the game under Rosetta)'
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -arch x86_64 -O2 -Wall -Wextra -Werror -dynamiclib "$src/guard.c" -o "$out/ExaltGuard.dylib"
# The app carries its own copy of the guard and the build record, so it works from anywhere.
cp "$out/ExaltGuard.dylib" "$src/game-build.sha256" "$app/Contents/Resources/"
cp "$src/game-build.sha256" "$out/game-build.sha256"   # for Start Guard.command
cp "$src/Start Guard.command" "$out/Start Guard.command"

print '== Build Exalt Client Mac.app (Apple silicon)'
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path "$cache" -warnings-as-errors \
    -import-objc-header "$src/app/GuardBridge.h" "$src/app/GuardModel.swift" "$src/app/GuardLaunch.swift" "$src/app/GuardApp.swift" \
    -o "$app/Contents/MacOS/ExaltClientMac"
# Icon: DECA's launcher icon with the red lettering turned yellow (drawn fallback if missing).
icons="$(mktemp -d)"
launcher_icon='/Applications/RotMG Exalt Launcher/RotMG Exalt Launcher.app/Contents/Resources/PlayerIcon.icns'
if [[ -f "$launcher_icon" ]]; then
    iconutil -c iconset "$launcher_icon" -o "$icons/source.iconset"
    xcrun swiftc -O -module-cache-path "$cache" "$src/app/recolor_icon.swift" -o "$icons/recolor-icon"
    "$icons/recolor-icon" "$icons/source.iconset" "$icons/AppIcon.iconset"
else
    xcrun swiftc -module-cache-path "$cache" "$src/app/make_icon.swift" -o "$icons/make-icon"
    "$icons/make-icon" "$icons/AppIcon.iconset"
fi
iconutil -c icns "$icons/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$icons"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ExaltClientMac</string>
	<key>CFBundleIdentifier</key><string>local.exalt.clientmac</string>
	<key>CFBundleName</key><string>Exalt Client Mac</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleShortVersionString</key><string>0.2</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

print '== Sign and verify'
xattr -cr "$app"   # generated app only; Finder metadata breaks codesign
codesign --force --sign - "$out/ExaltGuard.dylib"
codesign --force --sign - "$app/Contents/Resources/ExaltGuard.dylib"   # sign the inner guard before sealing the app
codesign --force --sign - "$app"
codesign --verify --strict "$out/ExaltGuard.dylib" "$app/Contents/Resources/ExaltGuard.dylib" "$app"
/bin/zsh -n "$out/Start Guard.command"
[[ -s "$out/game-build.sha256" ]] || { print 'ERROR: game-build.sha256 is missing.'; exit 1; }
print '== Install to ~/Applications'
mkdir -p "$HOME/Applications" "$data/logs"
chmod 700 "$data" "$data/logs"
rm -rf "$installed"
ditto "$app" "$installed"
codesign --verify --strict "$installed"
print "Built and verified in $out; installed $installed"
