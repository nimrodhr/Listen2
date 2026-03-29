#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# build_dmg.sh — Build LSTN2.app (Release) and package as DMG
# Usage: ./build_dmg.sh
# Output: ../LSTN2.dmg
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
APP_NAME="LSTN2"
DMG_NAME="$APP_NAME.dmg"
DMG_PATH="$REPO_ROOT/$DMG_NAME"
SCHEME="$APP_NAME"
XCODEPROJ="$PROJECT_DIR/$APP_NAME.xcodeproj"

echo "══════════════════════════════════════════"
echo "  LSTN2 DMG Builder"
echo "══════════════════════════════════════════"

# ── Step 1: Clean previous build artifacts ──────────────────
echo ""
echo "[1/5] Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Step 2: Build Release archive ───────────────────────────
echo "[2/5] Building $APP_NAME (Release)..."
xcodebuild \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination "generic/platform=macOS" \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE="Manual" \
    DEVELOPMENT_TEAM="" \
    2>&1 | tail -20

ARCHIVE_APP="$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
if [[ ! -d "$ARCHIVE_APP" ]]; then
    echo "ERROR: Archive failed — $APP_NAME.app not found in archive"
    exit 1
fi
echo "  Archive: $BUILD_DIR/$APP_NAME.xcarchive"

# ── Step 3: Export the .app from the archive ────────────────
echo "[3/5] Exporting $APP_NAME.app..."
EXPORT_DIR="$BUILD_DIR/export"
mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE_APP" "$EXPORT_DIR/$APP_NAME.app"

# Ad-hoc re-sign for self-distribution (no Developer ID)
codesign --force --deep --sign - "$EXPORT_DIR/$APP_NAME.app"
echo "  Signed: ad-hoc (self-distribution)"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Export failed — $APP_NAME.app not found"
    exit 1
fi

APP_SIZE=$(du -sh "$APP_PATH" | cut -f1)
echo "  App: $APP_PATH ($APP_SIZE)"

# ── Step 4: Create DMG with drag-to-Applications layout ────
echo "[4/5] Creating DMG..."

# Remove old DMG if present
rm -f "$DMG_PATH"

# Create a temporary directory for DMG contents
DMG_STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy app into staging
cp -R "$APP_PATH" "$DMG_STAGING/$APP_NAME.app"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "$DMG_STAGING/Applications"

# Create the DMG
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" \
    2>&1

# ── Step 5: Verify ──────────────────────────────────────────
echo "[5/5] Verifying DMG..."
if [[ -f "$DMG_PATH" ]]; then
    DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
    echo ""
    echo "══════════════════════════════════════════"
    echo "  Build successful!"
    echo "  DMG: $DMG_PATH ($DMG_SIZE)"
    echo "══════════════════════════════════════════"
    echo ""
    echo "To install:"
    echo "  1. Open $DMG_NAME"
    echo "  2. Drag $APP_NAME.app to Applications"
    echo "  3. Approve in System Settings > Privacy & Security"
else
    echo "ERROR: DMG creation failed"
    exit 1
fi
