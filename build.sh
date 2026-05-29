#!/usr/bin/env bash
#
# ClaudeCodexUsageBar を .app バンドルとしてビルドし、build/ClaudeCodexUsageBar.app を作る。
# 使い方: ./build.sh   （Xcode Command Line Tools が必要）
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeCodexUsageBar"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build (release)"
swift build -c release

# ビルド成果物の場所を解決（.build/release もしくは Xcode toolchain 経由のディレクトリ）
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "実行ファイルが見つかりません: $BIN_PATH" >&2
  exit 1
fi

echo "==> assembling .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [[ -f ".env" ]]; then
  cp .env "$APP_DIR/Contents/Resources/.env"
fi

# ad-hoc 署名（Gatekeeper の警告を緩和。Developer ID があるなら -s に置き換える）
codesign --force --deep --sign - "$APP_DIR" || true

echo ""
echo "✅ Done."
echo "   $APP_DIR を Applications にコピーするか、そのまま open してください:"
echo "       open \"$APP_DIR\""
