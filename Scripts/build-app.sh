#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"

# SwiftPM/XCTest needs the full Xcode toolchain. Honor DEVELOPER_DIR for this
# process only; do not change the machine-wide xcode-select setting.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if ! DEVELOPER_DIR="$(/usr/bin/xcode-select -p 2>/dev/null)"; then
    printf 'エラー: 完全版Xcodeが見つかりません。Xcodeをインストールし、DEVELOPER_DIRにXcode.app/Contents/Developerを指定してください。\n' >&2
    exit 1
  fi
fi
export DEVELOPER_DIR
if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ] || [ ! -d "$DEVELOPER_DIR/Platforms/MacOSX.platform" ]; then
  printf 'エラー: Command Line Toolsではなく完全版Xcodeが必要です。DEVELOPER_DIRにXcode.app/Contents/Developerを指定してください。\n' >&2
  exit 1
fi
if ! "$DEVELOPER_DIR/usr/bin/xcodebuild" -version >/dev/null 2>&1; then
  printf 'エラー: DEVELOPER_DIRで指定したXcodeを利用できません: %s\n' "$DEVELOPER_DIR" >&2
  exit 1
fi

# Keep app-bundle and SwiftPM version metadata synchronized.
for VERSION_KEY in version build; do
  if [ "$VERSION_KEY" = version ]; then PLIST_KEY=CFBundleShortVersionString; else PLIST_KEY=CFBundleVersion; fi
  RESOURCE_VERSION="$(/usr/bin/plutil -extract "$VERSION_KEY" raw -o - Sources/OurNotesApp/Resources/app-version.json)"
  PLIST_VERSION="$(/usr/bin/plutil -extract "$PLIST_KEY" raw -o - Config/Info.plist)"
  if [ "$RESOURCE_VERSION" != "$PLIST_VERSION" ]; then
    printf 'エラー: アプリ版情報が一致しません: %s\n' "$VERSION_KEY" >&2
    exit 1
  fi
done
SWIFT_BUILD_OPTIONS=(--disable-sandbox)
if [ -n "${OUR_NOTES_BUILD_ROOT:-}" ]; then
  SWIFT_BUILD_OPTIONS+=(--scratch-path "$OUR_NOTES_BUILD_ROOT/build" --cache-path "$OUR_NOTES_BUILD_ROOT/cache" --config-path "$OUR_NOTES_BUILD_ROOT/config" --security-path "$OUR_NOTES_BUILD_ROOT/security")
fi
swift build -c release "${SWIFT_BUILD_OPTIONS[@]}" --product OurNotesAnalyzer
BIN_DIR="$(swift build -c release "${SWIFT_BUILD_OPTIONS[@]}" --show-bin-path)"
mkdir -p "$TASK_ROOT/dist"
STAGE_DIR="$(mktemp -d "$TASK_ROOT/dist/.stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP_PATH="$STAGE_DIR/Our Notes Analyzer.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/OurNotesAnalyzer" "$APP_PATH/Contents/MacOS/OurNotesAnalyzer"
cp "$TASK_ROOT/Config/Info.plist" "$APP_PATH/Contents/Info.plist"
for RESOURCE_BUNDLE in "$BIN_DIR"/*.bundle; do
  if [ -d "$RESOURCE_BUNDLE" ]; then cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"; fi
done
codesign --force --sign - --entitlements "$TASK_ROOT/Config/OurNotes.entitlements" "$APP_PATH"
codesign --verify --strict "$APP_PATH"
FINAL_APP="$TASK_ROOT/dist/Our Notes Analyzer.app"
if [ -e "$FINAL_APP" ]; then rm -rf "$FINAL_APP"; fi
mv "$APP_PATH" "$FINAL_APP"
printf 'Created: %s\n' "$FINAL_APP"
