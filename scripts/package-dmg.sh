#!/usr/bin/env bash
# package-dmg.sh — Build MeetingAlert (Release, universal), assemble the .app, ad-hoc codesign
# it, and produce a distributable DMG with an /Applications shortcut. Prints the DMG SHA256.
#
# This is the SAME script CI (release.yml) runs, so a local DMG and a released DMG are built
# identically. It embeds the Google OAuth credentials via scripts/gen-secrets.sh, reading them
# from the environment (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET). With no env vars the app still
# builds and shows a "configure OAuth" instruction (F-065).
#
# Usage:
#   scripts/package-dmg.sh [VERSION]
#     VERSION   e.g. 1.0.0 (default: 0.0.0-dev). Sets CFBundleShortVersionString.
#   Env:
#     GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET   embedded into the build (never printed).
#     SKIP_UNIVERSAL=1                          build only the host arch (faster local smoke test).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-0.0.0-dev}"
VERSION="${VERSION#v}"   # tolerate a leading 'v' from a git tag (v1.0.0 → 1.0.0)
BUNDLE_ID="com.disco-tec.MeetingAlert"
APP_NAME="MeetingAlert"

DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
DMG_STAGE="$DIST_DIR/dmg-stage"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

die() { echo "ERROR: $*" >&2; exit 1; }
echo "==> Packaging $APP_NAME $VERSION (bundle id $BUNDLE_ID)"

# ── 0. Embed OAuth credentials (from env; never printed) ──────────────────────────────
echo "==> Generating Secrets.swift from environment…"
"$SCRIPT_DIR/gen-secrets.sh"

# ── 1. Build Release, universal (arm64 + x86_64) via lipo when feasible ────────────────
rm -rf "$DIST_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

FINAL_BIN="$APP_MACOS/$APP_NAME"
# Prefer a universal (arm64 + x86_64) binary in ONE invocation — SwiftPM emits a fat binary and
# lands it in `swift build --show-bin-path` (path layout varies by toolchain, so we ask for it).
# Fall back to the host arch only if the dual-arch build fails.
BUILD_ARGS=(build -c release)
if [[ "${SKIP_UNIVERSAL:-0}" != "1" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
echo "==> swift ${BUILD_ARGS[*]}"
if ! swift "${BUILD_ARGS[@]}"; then
    echo "WARNING: dual-arch build failed — retrying host arch only." >&2
    BUILD_ARGS=(build -c release)
    swift "${BUILD_ARGS[@]}"
fi
BIN_DIR="$(swift "${BUILD_ARGS[@]}" --show-bin-path)"
SRC_BIN="$BIN_DIR/$APP_NAME"
[[ -x "$SRC_BIN" ]] || die "No executable produced at $SRC_BIN."
cp "$SRC_BIN" "$FINAL_BIN"
echo "==> Architectures: $(lipo -archs "$FINAL_BIN" 2>/dev/null || echo unknown)"

# ── 2. Info.plist (stable bundle id, version from arg, LSUIElement, icon) ──────────────
cp "$REPO_ROOT/Info.plist" "$APP_CONTENTS/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleShortVersionString $VERSION" "$APP_CONTENTS/Info.plist"
"$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_CONTENTS/Info.plist"
# CFBundleVersion must be a monotonic integer-ish string; derive from the version digits + date.
BUILD_NUM="$(date +%Y%m%d%H%M)"
"$PB" -c "Set :CFBundleVersion $BUILD_NUM" "$APP_CONTENTS/Info.plist"
"$PB" -c "Add :CFBundleIconFile string AppIcon" "$APP_CONTENTS/Info.plist" 2>/dev/null \
    || "$PB" -c "Set :CFBundleIconFile AppIcon" "$APP_CONTENTS/Info.plist"

# ── 3. Icon ────────────────────────────────────────────────────────────────────────────
if "$SCRIPT_DIR/make-icns.sh" "$APP_RESOURCES/AppIcon.icns" >/dev/null 2>&1; then
    echo "==> Icon embedded (AppIcon.icns)"
else
    echo "WARNING: icon generation failed — continuing without a custom icon." >&2
    "$PB" -c "Delete :CFBundleIconFile" "$APP_CONTENTS/Info.plist" 2>/dev/null || true
fi

# ── 4. Ad-hoc codesign (no Apple Developer account) ────────────────────────────────────
# Ad-hoc "-" identity + a STABLE --identifier so credentials keyed by bundle id survive rebuilds
# (F-059). --deep signs the whole bundle; hardened runtime + entitlements match the dev build.
echo "==> Ad-hoc codesigning…"
codesign --force --deep --options runtime \
    --identifier "$BUNDLE_ID" \
    --entitlements "$REPO_ROOT/MeetingAlert.entitlements" \
    --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'
echo "==> Signature: $(codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E 'Signature|Identifier' | sed 's/^/    /' | tr '\n' ' ')"

# ── 5. DMG (staging folder + /Applications shortcut) ───────────────────────────────────
echo "==> Building DMG…"
rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
# A short readme inside the DMG doubles as the "simple background" instruction for first launch.
cat > "$DMG_STAGE/LEIA-ME.txt" <<TXT
Meeting Alert $VERSION

Instalação:
  1. Arraste "MeetingAlert.app" para a pasta "Applications".
  2. PRIMEIRA vez: clique com o botão direito no app → Abrir → Abrir.
     (O app não é notarizado — sem conta Apple Developer — então o macOS
      pede essa confirmação apenas na primeira abertura.)

Procure o ícone ⏰ na barra de menu do topo da tela.
TXT

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_STAGE" \
    -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGE"

# ── 6. SHA256 ────────────────────────────────────────────────────────────────────────────
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"
echo ""
echo "┌──────────────────────────────────────────────────────────────"
echo "│  DMG:    $DMG_PATH"
echo "│  Size:   $SIZE"
echo "│  SHA256: $SHA256"
echo "└──────────────────────────────────────────────────────────────"
# Machine-readable line for CI to capture.
echo "DMG_PATH=$DMG_PATH"
echo "DMG_SHA256=$SHA256"
