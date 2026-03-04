#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Listen Backend Build ==="

# Ensure dev deps (includes pyinstaller) are installed
echo "[1/4] Syncing dependencies..."
uv sync --extra dev --quiet

# Clean previous builds
echo "[2/4] Cleaning previous build..."
rm -rf build dist

# Run PyInstaller
echo "[3/4] Building with PyInstaller..."
uv run pyinstaller listen.spec --noconfirm --clean 2>&1

# Verify output
BINARY="dist/listen-backend/listen-backend"
if [[ -f "$BINARY" ]]; then
    SIZE=$(du -sh "dist/listen-backend" | cut -f1)
    echo "[4/4] Build successful!"
    echo "  Binary: $BINARY"
    echo "  Bundle size: $SIZE"
    echo ""
    echo "Test with: $BINARY"
else
    echo "[4/4] ERROR: Build failed — binary not found at $BINARY"
    exit 1
fi
