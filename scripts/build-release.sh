#!/bin/bash
# build-release.sh — Build Ghost OS v2 release tarball
#
# Produces: ghost-os-{VERSION}-macos-arm64.tar.gz
# Contents:
#   ghost                                    — MCP server binary (Swift, arm64)
#   ghost-vision                             — Vision sidecar launcher (shell script)
#   GHOST-MCP.md                             — Agent instructions
#   recipes/*.json                           — Bundled recipes
#   vision-sidecar/server.py                 — Vision sidecar Python server
#   vision-sidecar/requirements.txt          — Python dependencies
#
# Usage:
#   ./scripts/build-release.sh               # Build release tarball
#   ./scripts/build-release.sh --debug       # Build debug tarball (faster)
#
# The Homebrew formula downloads this tarball and installs:
#   /opt/homebrew/bin/ghost
#   /opt/homebrew/bin/ghost-vision
#   /opt/homebrew/share/ghost-os/GHOST-MCP.md
#   /opt/homebrew/share/ghost-os/recipes/*.json
#   /opt/homebrew/share/ghost-os/vision-sidecar/server.py
#   /opt/homebrew/share/ghost-os/vision-sidecar/requirements.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read version from Types.swift
VERSION=$(grep -o 'version = "[^"]*"' "$PROJECT_ROOT/Sources/GhostOS/Common/Types.swift" | head -1 | cut -d'"' -f2)
if [[ -z "$VERSION" ]]; then
    echo "ERROR: Could not read version from Types.swift" >&2
    exit 1
fi

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

TARBALL_NAME="ghost-os-${VERSION}-macos-arm64.tar.gz"
STAGE_DIR="$PROJECT_ROOT/.build/release-stage"

echo "Building Ghost OS v${VERSION} ($CONFIG)"
echo "========================================"

# Step 1: Build Swift binary
echo ""
echo "Step 1: Building Swift binary..."
cd "$PROJECT_ROOT"
swift build -c "$CONFIG" 2>&1

BINARY="$PROJECT_ROOT/.build/$CONFIG/ghost"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Binary not found at $BINARY" >&2
    exit 1
fi

# Verify it runs
"$BINARY" version
echo "  Binary: $BINARY ($(du -h "$BINARY" | awk '{print $1}'))"

# Step 2: Stage release files
echo ""
echo "Step 2: Staging release files..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/recipes"
mkdir -p "$STAGE_DIR/vision-sidecar"

# Binary
cp "$BINARY" "$STAGE_DIR/ghost"

# ghost-vision launcher
cp "$PROJECT_ROOT/vision-sidecar/ghost-vision" "$STAGE_DIR/ghost-vision"
chmod +x "$STAGE_DIR/ghost-vision"

# Agent instructions
cp "$PROJECT_ROOT/GHOST-MCP.md" "$STAGE_DIR/"

# Recipes
cp "$PROJECT_ROOT/recipes/"*.json "$STAGE_DIR/recipes/" 2>/dev/null || true

# Vision sidecar
cp "$PROJECT_ROOT/vision-sidecar/server.py" "$STAGE_DIR/vision-sidecar/"
cp "$PROJECT_ROOT/vision-sidecar/requirements.txt" "$STAGE_DIR/vision-sidecar/"

echo "  Staged files:"
ls -la "$STAGE_DIR/"
echo ""
echo "  Staged recipes:"
ls "$STAGE_DIR/recipes/" 2>/dev/null || echo "    (none)"
echo ""
echo "  Staged vision-sidecar:"
ls "$STAGE_DIR/vision-sidecar/"

# Step 3: Create tarball
echo ""
echo "Step 3: Creating tarball..."
cd "$STAGE_DIR"
tar czf "$PROJECT_ROOT/$TARBALL_NAME" ./*
echo "  Tarball: $PROJECT_ROOT/$TARBALL_NAME"
echo "  Size: $(du -h "$PROJECT_ROOT/$TARBALL_NAME" | awk '{print $1}')"

# Step 4: Compute SHA256
echo ""
echo "Step 4: SHA256..."
SHA256=$(shasum -a 256 "$PROJECT_ROOT/$TARBALL_NAME" | awk '{print $1}')
echo "  sha256 \"$SHA256\""

# Step 5: Summary
echo ""
echo "========================================"
echo "Release: Ghost OS v${VERSION}"
echo "Tarball: $TARBALL_NAME"
echo "SHA256:  $SHA256"
echo ""
echo "To install locally:"
echo "  tar xzf $TARBALL_NAME -C /tmp/ghost-os-install"
echo "  cp /tmp/ghost-os-install/ghost /opt/homebrew/bin/"
echo "  cp /tmp/ghost-os-install/ghost-vision /opt/homebrew/bin/"
echo ""
echo "To update Homebrew formula:"
echo "  url \"https://github.com/ghostwright/ghost-os/releases/download/v${VERSION}/${TARBALL_NAME}\""
echo "  sha256 \"${SHA256}\""
echo ""
echo "To create GitHub release:"
echo "  gh release create v${VERSION} $TARBALL_NAME --title \"Ghost OS v${VERSION}\""
echo "========================================"

# Cleanup
rm -rf "$STAGE_DIR"
