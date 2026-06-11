#!/bin/sh
# Assemble ZiggyZag.app — a proper macOS application bundle around the
# all-Zig launcher/desktop binaries.
#
# Why this exists: the native window otherwise runs as a bare ASN-registered
# executable with a NULL CFBundleIdentifier. macOS screen-recording and
# automation tools (and computer-use request_access) resolve apps by bundle
# identity, so without a bundle they cannot target the window by name — which
# blocked the visual-QA screenshot pass. A bundle also gives us a Dock icon,
# a stable identity for TCC permission grants, and a foundation for future
# notarization.
#
# Output: zig-out/ZiggyZag.app
# Layout:
#   ZiggyZag.app/Contents/
#     Info.plist
#     MacOS/ZiggyZag            (launcher shim: sets native-window mode, execs)
#     MacOS/ziggyzag-launcher   (the real GUI entry)
#     MacOS/ziggyzag-desktop    (window host, spawned by the launcher)
#     MacOS/ziggyzag-agentd     (AI sidecar, spawned on demand)
#     MacOS/ziggyzag            (interactive shell)
#     Resources/ZiggyZag.icns
#
# Usage: sh scripts/make-macos-bundle.sh
# Safe to re-run; it rebuilds the bundle from scratch each time.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.ziggyzag.desktop"
APP_NAME="ZiggyZag"
OUT="zig-out/${APP_NAME}.app"
CONTENTS="${OUT}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

# Resolve the project version from build.zig.zon (fallback to 0.0.0).
VERSION="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon 2>/dev/null | head -n1)"
[ -n "${VERSION:-}" ] || VERSION="0.0.0"

ZIG="${ZIG:-zig}"
command -v "$ZIG" >/dev/null 2>&1 || { echo "error: zig not found on PATH" >&2; exit 1; }

echo "Building release binaries..."
"$ZIG" build -Doptimize=ReleaseSafe

for bin in ziggyzag-launcher ziggyzag-desktop ziggyzag-agentd ziggyzag; do
    [ -f "zig-out/bin/$bin" ] || { echo "error: missing zig-out/bin/$bin (build failed?)" >&2; exit 1; }
done

echo "Assembling ${OUT}..."
rm -rf "$OUT"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp zig-out/bin/ziggyzag-launcher "$MACOS_DIR/ziggyzag-launcher"
cp zig-out/bin/ziggyzag-desktop  "$MACOS_DIR/ziggyzag-desktop"
cp zig-out/bin/ziggyzag-agentd   "$MACOS_DIR/ziggyzag-agentd"
cp zig-out/bin/ziggyzag          "$MACOS_DIR/ziggyzag"

# CFBundleExecutable shim. When launched from Finder there is no controlling
# TTY, so we opt into the native Cocoa window and exec the real launcher from
# the bundle's own MacOS dir (so it finds its sibling ziggyzag-desktop/agentd).
#
# The shim is named "ziggyzag-app", NOT "ZiggyZag": macOS bundles live on a
# case-INSENSITIVE filesystem, and the launcher resolves the shell as a sibling
# file named exactly "ziggyzag" (see posix_app.zig getShellPath). A "ZiggyZag"
# executable would collide with "ziggyzag" and silently overwrite the shell.
# CFBundleName below still presents the app as "ZiggyZag" in the Dock.
EXEC_NAME="ziggyzag-app"
cat > "$MACOS_DIR/${EXEC_NAME}" <<'SHIM'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
export ZIGGYZAG_NATIVE_WINDOW=1
exec "$DIR/ziggyzag-launcher" "$@"
SHIM
chmod +x "$MACOS_DIR/${EXEC_NAME}"

# Icon: convert the committed 256px PNG into a multi-resolution .icns.
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f assets/ziggyzag-256.png ]; then
    ICONSET="$(mktemp -d)/ZiggyZag.iconset"
    mkdir -p "$ICONSET"
    for sz in 16 32 64 128 256; do
        sips -z "$sz" "$sz" assets/ziggyzag-256.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
        dbl=$((sz * 2))
        sips -z "$dbl" "$dbl" assets/ziggyzag-256.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
    done
    if iconutil -c icns "$ICONSET" -o "$RES_DIR/${APP_NAME}.icns" >/dev/null 2>&1; then
        ICON_FILE="${APP_NAME}"
    else
        echo "warning: iconutil failed; bundle will use the default icon" >&2
        ICON_FILE=""
    fi
    rm -rf "$(dirname "$ICONSET")"
else
    echo "warning: sips/iconutil/PNG missing; bundle will use the default icon" >&2
    ICON_FILE=""
fi

# Info.plist. LSUIElement is false so the app shows in the Dock and can be
# targeted by name for screenshots/automation.
{
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '\t%s\n\t%s\n' '<key>CFBundleName</key>' "<string>${APP_NAME}</string>"
    printf '\t%s\n\t%s\n' '<key>CFBundleDisplayName</key>' "<string>${APP_NAME}</string>"
    printf '\t%s\n\t%s\n' '<key>CFBundleIdentifier</key>' "<string>${BUNDLE_ID}</string>"
    printf '\t%s\n\t%s\n' '<key>CFBundleExecutable</key>' "<string>${EXEC_NAME}</string>"
    printf '\t%s\n\t%s\n' '<key>CFBundleVersion</key>' "<string>${VERSION}</string>"
    printf '\t%s\n\t%s\n' '<key>CFBundleShortVersionString</key>' "<string>${VERSION}</string>"
    printf '\t%s\n\t%s\n' '<key>CFBundlePackageType</key>' '<string>APPL</string>'
    printf '\t%s\n\t%s\n' '<key>CFBundleInfoDictionaryVersion</key>' '<string>6.0</string>'
    printf '\t%s\n\t%s\n' '<key>LSMinimumSystemVersion</key>' '<string>11.0</string>'
    printf '\t%s\n\t%s\n' '<key>NSHighResolutionCapable</key>' '<true/>'
    printf '\t%s\n\t%s\n' '<key>LSUIElement</key>' '<false/>'
    if [ -n "$ICON_FILE" ]; then
        printf '\t%s\n\t%s\n' '<key>CFBundleIconFile</key>' "<string>${ICON_FILE}</string>"
    fi
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
} > "${CONTENTS}/Info.plist"

echo "Done: ${OUT}"
echo "  bundle id : ${BUNDLE_ID}"
echo "  version   : ${VERSION}"
echo "Run with:   open ${OUT}"
