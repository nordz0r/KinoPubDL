#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT"
swift Scripts/render_icon.swift "$ROOT/Assets"
/usr/bin/iconutil -c icns "$ROOT/Assets/AppIcon.iconset" -o "$ROOT/Assets/AppIcon.icns"
swift build -c release
APP="$ROOT/KinoPubDL.app"
if /usr/bin/pgrep -f "^$APP/Contents/MacOS/KinoPubDL$" >/dev/null; then
    printf 'Quit KinoPubDL before rebuilding its app bundle.\n' >&2
    exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/KinoPubDL" "$APP/Contents/MacOS/KinoPubDL"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"

if [ "${1:-}" = "--install" ]; then
    TARGET="$HOME/Applications/KinoPubDL.app"
    if [ -L "$TARGET" ]; then
        printf 'Refusing to overwrite a symlink: %s\n' "$TARGET" >&2
        exit 1
    fi
    if [ -e "$TARGET" ]; then
        IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)
        if [ "$IDENTIFIER" != 'local.nord.KinoPubDL' ]; then
            printf 'Another app already exists at %s; leaving it untouched.\n' "$TARGET" >&2
            exit 1
        fi
        if /usr/bin/pgrep -f "^$TARGET/Contents/MacOS/KinoPubDL$" >/dev/null; then
            printf 'Quit the installed KinoPubDL before updating it.\n' >&2
            exit 1
        fi
    fi
    mkdir -p "$HOME/Applications"
    /usr/bin/ditto "$APP" "$TARGET"
    /usr/bin/codesign --verify --deep --strict "$TARGET"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"
    printf 'Installed %s\n' "$TARGET"
fi
